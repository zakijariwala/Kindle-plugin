--[[--
The Kindle-like Home screen.

Exactly five things are offered: Continue Reading, My Library, Send Book,
Installed Plugins and Settings. It is a static, full-screen widget shown on
top of KOReader's file browser: no timers, no animation, nothing running
while it is displayed. Closing it (Back key) simply reveals the file browser.

@module kindleui.ui.home
]]

local Blitbuffer = require("ffi/blitbuffer")
local Books = require("kindleui/util/books")
local Cache = require("kindleui/util/librarycache")
local Extractor = require("kindleui/util/extractor")
local Perf = require("kindleui/util/perf")
local filemanagerutil = require("apps/filemanager/filemanagerutil")
local Button = require("ui/widget/button")
local Common = require("kindleui/ui/common")
local Device = require("device")
local FocusManager = require("ui/widget/focusmanager")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local ImageWidget = require("ui/widget/imagewidget")
local ProgressWidget = require("ui/widget/progresswidget")
local Size = require("ui/size")
local TextBoxWidget = require("ui/widget/textboxwidget")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local _ = require("gettext")
local Screen = Device.screen

local Home = FocusManager:extend{
    name = "kindleui_home",
    covers_fullscreen = true, -- hint for UIManager:_repaint()
    plugin = nil, -- the KindleUI plugin instance (navigation actions)
}

function Home:init()
    self.t_open = Perf.start()
    self.dimen = Geom:new{ x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight() }
    if Device:hasKeys() then
        -- Back leaves the shell and reveals KOReader's file browser (never a dead end).
        self.key_events.Close = { { Device.input.group.Back } }
    end
    self:build()
end

function Home:_freeCover()
    if self.cover_widget then
        self.cover_widget:free()
        self.cover_widget = nil
    end
end

function Home:_continueReading(inner_w)
    local file = Books.lastFile()
    if not file then
        local open_btn = Button:new{
            text = _("Open Library"),
            width = math.floor(inner_w * 0.6),
            text_font_face = "cfont",
            text_font_size = 20,
            radius = Size.radius.button,
            show_parent = self,
            callback = function() self.plugin:showLibrary() end,
        }
        return VerticalGroup:new{
            align = "left",
            TextWidget:new{
                text = _("No book currently being read."),
                face = Common.face("body"),
                max_width = inner_w,
            },
            VerticalSpan:new{ width = Size.span.vertical_large * 2 },
            open_btn,
        }, open_btn
    end

    local entry = Cache.getEntry(self.plugin.ui, file)
    local info = {
        title = entry and entry.title or filemanagerutil.splitFileNameType(file),
        authors = entry and entry.authors,
        percent = entry and entry.percent,
    }
    local pad = Size.padding.large
    local border = Size.border.thick
    local content_w = inner_w - 2 * (pad + border)
    local cover_h = Screen:scaleBySize(140)
    local cover_w = math.floor(cover_h * 2 / 3)
    local row = HorizontalGroup:new{ align = "top" }

    local cover_bb = Cache.loadCover(entry)
    if entry and Cache.needsExtraction(entry) then
        -- First time this book is shown: extract its cover right after Home
        -- has been painted, then rebuild the card.
        self.pending_extract = { file = file, entry = entry, w = cover_w, h = cover_h }
    end
    local text_w = content_w
    if cover_bb then
        self.cover_widget = ImageWidget:new{
            image = cover_bb,
            image_disposable = true,
            width = cover_w,
            height = cover_h,
            scale_factor = 0,
        }
        table.insert(row, self.cover_widget)
        table.insert(row, HorizontalSpan:new{ width = pad * 2 })
        text_w = content_w - cover_w - pad * 2
    end

    local texts = VerticalGroup:new{ align = "left" }
    table.insert(texts, TextBoxWidget:new{
        text = info.title,
        face = Common.face("book_title"),
        width = text_w,
        height = math.floor(Common.face("book_title").size * 2.8),
        height_adjust = true,
        height_overflow_show_ellipsis = true,
    })
    if info.authors then
        table.insert(texts, VerticalSpan:new{ width = Size.span.vertical_default })
        table.insert(texts, TextWidget:new{
            text = info.authors,
            face = Common.face("body"),
            max_width = text_w,
        })
    end
    if info.percent then
        table.insert(texts, VerticalSpan:new{ width = Size.span.vertical_large * 2 })
        table.insert(texts, TextWidget:new{
            text = string.format("%d%%", math.floor(info.percent * 100 + 0.5)),
            face = Common.face("small"),
            max_width = text_w,
        })
        table.insert(texts, VerticalSpan:new{ width = Size.span.vertical_default })
        table.insert(texts, ProgressWidget:new{
            width = math.min(text_w, Screen:scaleBySize(240)),
            height = Screen:scaleBySize(8),
            percentage = info.percent,
            margin_h = 0,
            margin_v = 0,
        })
    end
    table.insert(row, texts)

    local card = Common.Tappable:new{
        callback = function() self.plugin:openBook(file) end,
        FrameContainer:new{
            bordersize = border,
            radius = Size.radius.window,
            padding = pad,
            width = inner_w,
            background = Blitbuffer.COLOR_WHITE,
            row,
        },
    }
    return card, card
end

function Home:build()
    self:_freeCover()
    self.pending_extract = nil
    self.extract_started = nil
    local w = self.dimen.w
    local margin = Common.SIDE_MARGIN
    local inner_w = w - 2 * margin

    local vgroup = VerticalGroup:new{ align = "left" }
    local function add(widget) table.insert(vgroup, widget) end
    local function space(n) add(VerticalSpan:new{ width = n }) end

    add(TextWidget:new{ text = _("Home"), face = Common.face("title"), max_width = inner_w })
    space(Size.span.vertical_large * 2)
    add(Common.line(inner_w, true))
    space(Screen:scaleBySize(22))

    add(Common.label(_("Continue Reading"), inner_w))
    space(Screen:scaleBySize(10))
    local continue_widget, continue_focus = self:_continueReading(inner_w)
    add(continue_widget)
    space(Screen:scaleBySize(34))

    self.layout = { { continue_focus } }
    local nav = {
        { _("My Library"), function() self.plugin:showLibrary() end },
        { _("+ Send Book"), function() self.plugin:showTransfer() end },
        { _("Installed Plugins"), function() self.plugin:showPlugins() end },
        { _("Settings"), function() self.plugin:showSettings() end },
    }
    add(Common.line(inner_w))
    for __, entry in ipairs(nav) do
        local btn = Button:new{
            text = entry[1],
            callback = entry[2],
            width = inner_w,
            align = "left",
            bordersize = 0,
            padding_h = 0,
            padding_v = Screen:scaleBySize(18),
            text_font_face = "cfont",
            text_font_size = 24,
            text_font_bold = false,
            show_parent = self,
        }
        add(btn)
        add(Common.line(inner_w))
        table.insert(self.layout, { btn })
    end

    self[1] = FrameContainer:new{
        width = w,
        height = self.dimen.h,
        bordersize = 0,
        padding = 0,
        padding_left = margin,
        padding_right = margin,
        padding_top = Screen:scaleBySize(30),
        background = Blitbuffer.COLOR_WHITE,
        vgroup,
    }
    self:moveFocusTo(1, 1, FocusManager.FOCUS_ONLY_ON_NT)
end

--- Rebuilds the screen (e.g. after a book was read or received).
function Home:refresh()
    self:build()
    UIManager:setDirty(self, "ui")
end

function Home:onShow()
    UIManager:setDirty(self, "full")
    return true
end

function Home:paintTo(bb, x, y)
    FocusManager.paintTo(self, bb, x, y)
    if self.t_open then
        Perf.log("home open (to first paint)", self.t_open)
        self.t_open = nil
    end
    if self.pending_extract and not self.extract_started then
        -- Start after this paint (never fork from inside a repaint).
        self.extract_started = true
        local job = self.pending_extract
        UIManager:nextTick(function()
            if not UIManager:isWidgetShown(self) then return end
            local t0 = Perf.start()
            self.extract_job = Extractor.start({ { path = job.file, entry = job.entry, w = job.w, h = job.h } }, {
                onDone = function()
                    self.extract_job = nil
                    Perf.log("home cover extracted (child process)", t0, { has_cover = job.entry.cover ~= nil })
                    if UIManager:isWidgetShown(self) then self:refresh() end
                end,
            })
        end)
    end
end

function Home:onClose()
    UIManager:close(self)
    return true
end

-- The Home key/gesture closes widgets one by one (InputContainer:onHome
-- daisy-chain) until something handles it: we are Home, so we stop it here.
function Home:onHome()
    UIManager:setSuspendRepaints(false)
    self:refresh()
    return true
end

function Home:onCloseWidget()
    if self.extract_job then
        self.extract_job:cancel()
        self.extract_job = nil
    end
    self:_freeCover()
    if self.plugin then self.plugin:onHomeClosed(self) end
end

-- Reader about to open (e.g. from Continue Reading): get out of the way.
function Home:onShowingReader()
    UIManager:close(self)
end

return Home
