--[[--
The "Send Book" screen.

States:
  error     – no Wi-Fi / no address / server or QR failure (with Try again)
  waiting   – QR code + local address, waiting for the phone
  receiving – progress (updated in 10% steps: e-ink friendly)
  received  – "✓ Book received" + Read Now / Done
  failed    – upload rejected or interrupted; session keeps waiting

The transfer session (and its HTTP server) lives exactly as long as this
widget: closing the screen, pressing Cancel, suspending the device or
KOReader exiting always stops the server and clears the token.

@module kindleui.ui.transfer
]]

local Blitbuffer = require("ffi/blitbuffer")
local Books = require("kindleui/util/books")
local Button = require("ui/widget/button")
local CenterContainer = require("ui/widget/container/centercontainer")
local Common = require("kindleui/ui/common")
local Config = require("kindleui/config")
local Device = require("device")
local FocusManager = require("ui/widget/focusmanager")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local Providers = require("kindleui/transfer/provider")
local QR = require("kindleui/transfer/qr")
local Size = require("ui/size")
local TextBoxWidget = require("ui/widget/textboxwidget")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local logger = require("logger")
local _ = require("gettext")
local T = require("ffi/util").template
local Screen = Device.screen

local ERRORS = {
    no_wifi = _("Wi-Fi connection required.\nConnect the Kindle to your phone's hotspot and try again."),
    no_ip = _("Unable to determine local network address.\nConnect the Kindle to your phone's hotspot and try again."),
    server = _("Unable to start transfer service."),
    random = _("Unable to start transfer service."),
    dest_dir = _("Unable to start transfer service.\nThe library folder could not be found."),
    qr = _("Unable to create transfer QR code."),
}

local FAILURES = {
    unsupported = _("Unsupported file type.\nThis file was not added to your library."),
    disk_full = _("Not enough storage space to save this book."),
    cancelled = _("Upload cancelled."),
    incomplete = _("Upload cancelled."),
    corrupt = _("The uploaded file could not be added."),
    io = _("The uploaded file could not be added."),
}

local TransferScreen = FocusManager:extend{
    name = "kindleui_transfer",
    covers_fullscreen = true,
    plugin = nil,
}

function TransferScreen:init()
    self.dimen = Geom:new{ x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight() }
    if Device:hasKeys() then
        self.key_events.Close = { { Device.input.group.Back } }
    end
    self.state = "starting"
    self:startSession()
end

--- (Re)starts a transfer session and renders the result.
function TransferScreen:startSession()
    self:stopSession("restart")
    local provider = Providers.get(Config.get("transfer_method"))
    local info, err = provider:prepare()
    if not info then
        logger.info("KindleUI transfer: pre-flight failed:", err)
        self:setState("error", { message = ERRORS[err] or ERRORS.server, can_enable_wifi = err == "no_wifi" })
        return
    end
    local session
    session, err = provider:start(info, {
        onProgress = function(filename, received, total)
            self:setState("receiving", { filename = filename, received = received, total = total })
        end,
        onFailed = function(reason, filename)
            self:setState("failed", { reason = reason, filename = filename })
        end,
        onReceived = function(path, filename)
            self:onBookReceived(path, filename)
        end,
        onExpired = function()
            self:setState("error", { message = _("This transfer session has expired.") })
        end,
    })
    if not session then
        self:setState("error", { message = ERRORS[err] or ERRORS.server })
        return
    end
    self.session = session
    self.qr_size = math.floor(math.min(self.dimen.w, self.dimen.h) * 0.5)
    local qr_widget = QR.newWidget(session.url, self.qr_size)
    if not qr_widget then
        logger.warn("KindleUI transfer: QR generation failed")
        self:stopSession("qr_failed")
        self:setState("error", { message = ERRORS.qr })
        return
    end
    self.qr_widget = qr_widget
    self:setState("waiting")
end

function TransferScreen:stopSession(reason)
    if self.session then
        self.session:stop(reason or "cancelled")
        self.session = nil
    end
    if self.qr_widget then
        self.qr_widget:free()
        self.qr_widget = nil
    end
end

function TransferScreen:onBookReceived(path, filename)
    self.session = nil -- already stopped by itself
    Books.refreshLibrary(path)
    local info = Books.getInfo(self.plugin.ui, path)
    -- Books never opened have no sidecar metadata yet: ask KOReader (it
    -- extracts metadata only, without rendering) for a nicer title/author.
    if self.plugin.ui and self.plugin.ui.bookinfo then
        local ok, props = pcall(self.plugin.ui.bookinfo.getDocProps, self.plugin.ui.bookinfo, path)
        if ok and props then
            info.title = props.display_title or info.title
            info.authors = props.authors and tostring(props.authors):gsub("\n", ", ") or info.authors
        end
    end
    if self.qr_widget then
        self.qr_widget:free()
        self.qr_widget = nil
    end
    self:setState("received", { path = path, title = info.title or filename, authors = info.authors })
    if self.plugin then self.plugin:onLibraryChanged() end
end

function TransferScreen:setState(state, data)
    -- Progress: skip redundant repaints (the session already throttles to 10%).
    self.state = state
    self.data = data or {}
    self:render()
end

local function text(str, face, width, align)
    return TextBoxWidget:new{
        text = str,
        face = face,
        width = width,
        alignment = align or "center",
    }
end

function TransferScreen:_button(label, callback, width)
    local btn = Button:new{
        text = label,
        callback = callback,
        width = width,
        text_font_face = "cfont",
        text_font_size = 22,
        radius = Size.radius.button,
        padding_v = Screen:scaleBySize(12),
        show_parent = self,
    }
    table.insert(self.layout, { btn })
    return btn
end

function TransferScreen:render()
    local w = self.dimen.w
    local inner_w = w - 2 * Common.SIDE_MARGIN
    local btn_w = math.floor(inner_w * 0.7)
    local group = VerticalGroup:new{ align = "center" }
    local function add(widget) table.insert(group, widget) end
    local function space(n) add(VerticalSpan:new{ width = Screen:scaleBySize(n) }) end
    self.layout = {}

    add(TextWidget:new{ text = _("SEND BOOK"), face = Common.face("title"), max_width = inner_w })
    space(10)
    add(Common.line(inner_w, true))
    space(30)

    local d = self.data
    if self.state == "waiting" or self.state == "failed" then
        add(FrameContainer:new{
            bordersize = Size.border.thick,
            padding = Screen:scaleBySize(12),
            background = Blitbuffer.COLOR_WHITE,
            self.qr_widget,
        })
        space(24)
        if self.state == "failed" then
            add(text("⚠ " .. (FAILURES[d.reason] or FAILURES.io), Common.face("body"), inner_w))
            space(8)
            add(text(_("You can try again from your phone."), Common.face("small"), inner_w))
        else
            add(text(_("Scan with your phone."), Common.face("body"), inner_w))
            space(6)
            add(text(_("Waiting for upload…"), Common.face("body"), inner_w))
        end
        space(20)
        if self.session then
            add(text(_("Local address:") .. "\n" .. self.session.ip .. ":" .. self.session.port,
                Common.face("small"), inner_w))
        end
        space(8)
        add(text(_("Your phone must be the hotspot the Kindle is connected to (or on the same Wi-Fi)."),
            Common.face("small"), inner_w))
        space(28)
        add(self:_button(_("Cancel"), function() self:onClose() end, btn_w))
    elseif self.state == "receiving" then
        local pct = d.total and d.total > 0 and math.floor(d.received * 100 / d.total) or 0
        add(text(_("Receiving…"), Common.face("body"), inner_w))
        space(10)
        add(text(d.filename or "", Common.face("book_title"), inner_w))
        space(24)
        local ProgressWidget = require("ui/widget/progresswidget")
        add(ProgressWidget:new{
            width = btn_w,
            height = Screen:scaleBySize(16),
            percentage = pct / 100,
        })
        space(8)
        add(text(T(_("%1%"), pct), Common.face("body"), inner_w))
        space(40)
        add(self:_button(_("Cancel"), function() self:onClose() end, btn_w))
    elseif self.state == "received" then
        add(text("✓ " .. _("Book received"), Common.face("title"), inner_w))
        space(24)
        add(text(d.title or "", Common.face("book_title"), inner_w))
        if d.authors then
            space(6)
            add(text(d.authors, Common.face("body"), inner_w))
        end
        space(40)
        add(self:_button(_("Read Now"), function()
            local path = d.path
            UIManager:close(self)
            self.plugin:openBook(path)
        end, btn_w))
        space(16)
        add(self:_button(_("Send Another"), function() self:startSession() end, btn_w))
        space(16)
        add(self:_button(_("Done"), function() self:onClose() end, btn_w))
    else -- error
        add(text(d.message or ERRORS.server, Common.face("body"), inner_w))
        space(40)
        if d.can_enable_wifi then
            add(self:_button(_("Turn on Wi-Fi"), function()
                local NetworkMgr = require("ui/network/manager")
                NetworkMgr:runWhenConnected(function() self:startSession() end)
            end, btn_w))
            space(16)
        end
        add(self:_button(_("Try Again"), function() self:startSession() end, btn_w))
        space(16)
        add(self:_button(_("Close"), function() self:onClose() end, btn_w))
    end

    self[1] = FrameContainer:new{
        width = w,
        height = self.dimen.h,
        bordersize = 0,
        padding = 0,
        padding_top = Screen:scaleBySize(30),
        background = Blitbuffer.COLOR_WHITE,
        CenterContainer:new{
            dimen = Geom:new{ w = w, h = group:getSize().h },
            group,
        },
    }
    self:moveFocusTo(1, 1, FocusManager.FOCUS_ONLY_ON_NT)
    UIManager:setDirty(self, "ui")
end

function TransferScreen:onShow()
    UIManager:setDirty(self, "full")
    return true
end

function TransferScreen:onClose()
    UIManager:close(self)
    return true
end

function TransferScreen:onCloseWidget()
    -- Always tear down the server, whatever the reason we are closing.
    self:stopSession("cancelled")
    if self.plugin then
        self.plugin:onChildClosed()
    end
end

-- Device going to sleep or KOReader exiting: stop listening right away.
function TransferScreen:onSuspend()
    if self.session then
        self:stopSession("suspend")
        self:setState("error", { message = _("The transfer was stopped because the device went to sleep.") })
    end
end

function TransferScreen:onExit()
    self:stopSession("exit")
end

-- Opening a book from elsewhere tears the whole UI down: stop the server first.
function TransferScreen:onShowingReader()
    self:stopSession("reader")
    UIManager:close(self)
end

return TransferScreen
