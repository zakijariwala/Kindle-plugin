--[[--
The Kindle-like Home screen.

Exactly five things are offered: Continue Reading (the last book as a card,
plus up to two more books being read as short rows), My Library, Send Book,
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
local Config = require("kindleui/config")
local Device = require("device")
local FocusManager = require("ui/widget/focusmanager")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local LeftContainer = require("ui/widget/container/leftcontainer")
local OverlapGroup = require("ui/widget/overlapgroup")
local RightContainer = require("ui/widget/container/rightcontainer")
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
local T = require("ffi/util").template
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
    for __, image in ipairs(self.recent_images or {}) do
        image:free()
    end
    self.recent_images = {}
end

function Home:_continueReading(inner_w)
    local file = Books.lastFile()
    if not file then
        local open_btn = Button:new{
            text = _("Open Library"),
            width = math.floor(inner_w * 0.6),
            text_font_face = "cfont",
            text_font_size = Common.fs(20),
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
    local cover_h = self:_coverH(140)
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

-- Optional parts, dropped step by step when Home does not fit the screen
-- (small screens, large text, pinned plugins). The nav buttons always stay.
-- `compact` tightens spacing and shrinks the covers first.
Home.FIT_LEVELS = {
    { more = 2, recent = true },
    { more = 2, recent = true, compact = true },
    { more = 1, recent = true, compact = true },
    { more = 1, recent = false, compact = true },
    { more = 0, recent = false, compact = true },
}

-- A vertical gap (scaled), halved in compact mode.
function Home:_gap(n)
    return Screen:scaleBySize(self.compact and math.floor(n / 2) or n)
end

-- A cover height (scaled), 80% in compact mode.
function Home:_coverH(n)
    return Screen:scaleBySize(self.compact and math.floor(n * 0.8) or n)
end

function Home:build()
    for i, fit in ipairs(Home.FIT_LEVELS) do
        local h = self:_build(fit)
        self.fit, self.used_height = fit, h
        if h <= self.dimen.h or i == #Home.FIT_LEVELS then break end
    end
    self:moveFocusTo(1, 1, FocusManager.FOCUS_ONLY_ON_NT)
end

-- Builds Home with the given optional parts; returns its height.
function Home:_build(fit)
    self.compact = fit.compact
    self:_freeCover()
    self.pending_extract = nil
    self.extract_started = nil
    local w = self.dimen.w
    local margin = Common.SIDE_MARGIN
    local inner_w = w - 2 * margin
    local padding_top = self:_gap(30)

    local vgroup = VerticalGroup:new{ align = "left" }
    local function add(widget) table.insert(vgroup, widget) end
    local function space(n) add(VerticalSpan:new{ width = n }) end

    -- Title on the left, status (time · Wi-Fi · battery) on the right.
    local status = self:_statusText()
    local status_widget = TextWidget:new{ text = status, face = Common.face("small"), max_width = math.floor(inner_w * 0.6) }
    local title_widget = TextWidget:new{ text = _("Home"), face = Common.face("title"),
        max_width = inner_w - status_widget:getSize().w - Screen:scaleBySize(10) }
    local row_h = math.max(title_widget:getSize().h, status_widget:getSize().h)
    add(OverlapGroup:new{
        dimen = Geom:new{ w = inner_w, h = row_h },
        LeftContainer:new{ dimen = Geom:new{ w = inner_w, h = row_h }, title_widget },
        RightContainer:new{ dimen = Geom:new{ w = inner_w, h = row_h }, status_widget },
    })
    space(Size.span.vertical_large * 2)
    add(Common.line(inner_w, true))
    space(self:_gap(22))

    add(Common.label(_("Continue Reading"), inner_w))
    space(self:_gap(10))
    local continue_widget, continue_focus = self:_continueReading(inner_w)
    add(continue_widget)
    self.layout = { { continue_focus } }
    local shown = self:_moreReading(add, space, inner_w, fit.more)
    if fit.recent then self:_recentlyAdded(add, space, inner_w, shown) end
    space(self:_gap(34))

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
            padding_v = self:_gap(18) + (self.compact and Screen:scaleBySize(3) or 0),
            text_font_face = "cfont",
            text_font_size = Common.fs(24),
            text_font_bold = false,
            show_parent = self,
        }
        add(btn)
        add(Common.line(inner_w))
        table.insert(self.layout, { btn })
    end
    self:_pinnedPlugins(add, space, inner_w)

    self[1] = FrameContainer:new{
        width = w,
        height = self.dimen.h,
        bordersize = 0,
        padding = 0,
        padding_left = margin,
        padding_right = margin,
        padding_top = padding_top,
        background = Blitbuffer.COLOR_WHITE,
        vgroup,
    }
    return padding_top + vgroup:getSize().h
end


-- Other books being read (KOReader's reading history, newest first, not
-- finished), as one-line rows under the Continue Reading card: title on the
-- left, progress on the right. Returns the set of books shown on Home so far.
function Home:_moreReading(add, space, inner_w, max_rows)
    local shown = {}
    local last = Books.lastFile()
    if last then shown[last] = true end
    self.more_reading = {}
    if not last or max_rows == 0 or Config.get("home_more_reading") == false then return shown end
    -- a few extra candidates, since finished books are skipped
    for __, file in ipairs(Books.recentlyRead(max_rows + 4, shown)) do
        if #self.more_reading >= max_rows then break end
        local entry = Cache.getEntry(self.plugin.ui, file)
        if entry and entry.status ~= "complete" then
            table.insert(self.more_reading, { file = file, entry = entry })
        end
    end
    if #self.more_reading == 0 then return shown end
    space(self:_gap(6))
    local pad_v = self:_gap(14)
    -- Room for Tappable's focus border (devices with keys).
    local edge = Size.border.thick
    local row_w = inner_w - 2 * edge
    for __, it in ipairs(self.more_reading) do
        shown[it.file] = true
        local pct = it.entry.percent and string.format("%d%%", math.floor(it.entry.percent * 100 + 0.5))
        local pct_widget = pct and TextWidget:new{ text = pct, face = Common.face("small") }
        local pct_w = pct_widget and (pct_widget:getSize().w + Screen:scaleBySize(16)) or 0
        local title = TextWidget:new{
            text = it.entry.title or filemanagerutil.splitFileNameType(it.file),
            face = Common.face("body"),
            max_width = row_w - pct_w,
        }
        local row_h = title:getSize().h + 2 * pad_v
        local overlap = OverlapGroup:new{
            dimen = Geom:new{ w = row_w, h = row_h },
            LeftContainer:new{ dimen = Geom:new{ w = row_w, h = row_h }, title },
        }
        if pct_widget then
            table.insert(overlap, RightContainer:new{ dimen = Geom:new{ w = row_w, h = row_h }, pct_widget })
        end
        local file = it.file
        local row = Common.Tappable:new{
            callback = function() self.plugin:openBook(file) end,
            FrameContainer:new{ bordersize = 0, padding = edge, overlap },
        }
        add(row)
        add(Common.line(inner_w))
        table.insert(self.layout, { row })
    end
    return shown
end

-- "Recently added": the 3 newest books, as small covers. From the library
-- cache only (no folder scan), so Home stays fast. Books already shown under
-- Continue Reading (`shown`) are skipped.
function Home:_recentlyAdded(add, space, inner_w, shown)
    if Config.get("home_recent") == false then return end
    local items = Cache.recent(3, shown)
    if #items == 0 then return end
    space(self:_gap(22))
    add(Common.label(_("Recently added"), inner_w))
    space(self:_gap(10))
    local h = self:_coverH(120)
    local w = math.floor(h * 2 / 3)
    local gap = Screen:scaleBySize(16)
    local row = HorizontalGroup:new{ align = "top" }
    local layout_row = {}
    for i, it in ipairs(items) do
        if i > 1 then table.insert(row, HorizontalSpan:new{ width = gap }) end
        local cover
        local bb = Cache.loadCover(it.entry)
        if bb then
            local image = ImageWidget:new{ image = bb, image_disposable = true, width = w, height = h, scale_factor = 0 }
            table.insert(self.recent_images, image)
            cover = FrameContainer:new{ bordersize = Size.border.thin, padding = 0, image }
        else
            cover = Common.textCover(it.entry.title or filemanagerutil.splitFileNameType(it.path), nil, w, h)
        end
        local path = it.path
        local tile = Common.Tappable:new{
            callback = function() self.plugin:openBook(path) end,
            cover,
        }
        table.insert(row, tile)
        table.insert(layout_row, tile)
    end
    add(row)
    table.insert(self.layout, layout_row)
end

-- "9:42 · Wi-Fi · ▯ 83%": read once when Home is built (no clock timer).
function Home:_statusText()
    local parts = {}
    local ok_dt, datetime = pcall(require, "datetime")
    if ok_dt then
        table.insert(parts, datetime.secondsToHour(os.time(), G_reader_settings:isTrue("twelve_hour_clock")))
    end
    if Device:hasWifiToggle() then
        local ok_n, NetworkMgr = pcall(require, "ui/network/manager")
        if ok_n and NetworkMgr:isWifiOn() then
            table.insert(parts, _("Wi-Fi"))
        end
    end
    if Device:hasBattery() then
        local powerd = Device:getPowerDevice()
        local lvl = powerd:getCapacity()
        local symbol = powerd:getBatterySymbol(powerd:isCharged(), powerd:isCharging(), lvl)
        table.insert(parts, symbol .. " " .. lvl .. "%")
    end
    return table.concat(parts, "  ·  ")
end

-- Back from sleep: the time and battery shown are stale, redraw once.
function Home:onResume()
    UIManager:nextTick(function()
        if UIManager:isWidgetShown(self) then self:refresh() end
    end)
end

-- Plugins pinned from Installed Plugins (hold → Pin to Home): two per row.
function Home:_pinnedPlugins(add, space, inner_w)
    local names = Config.get("pinned_plugins")
    if not names or #names == 0 then return end
    local Plugins = require("kindleui/ui/plugins")
    local entries = {}
    for __, name in ipairs(names) do
        local entry = Plugins.find(self.plugin, name)
        if entry and not entry.disabled then table.insert(entries, entry) end
    end
    if #entries == 0 then return end -- removed or disabled since: just don't show
    space(self:_gap(26))
    add(Common.label(_("Pinned plugins"), inner_w))
    space(self:_gap(10))
    local gap = Screen:scaleBySize(14)
    local btn_w = math.floor((inner_w - gap) / 2)
    for i = 1, #entries, 2 do
        local row = HorizontalGroup:new{ align = "center" }
        local layout_row = {}
        for j = i, math.min(i + 1, #entries) do
            local entry = entries[j]
            if j > i then table.insert(row, HorizontalSpan:new{ width = gap }) end
            local btn = Button:new{
                text = entry.text,
                width = btn_w,
                text_font_face = "cfont",
                text_font_size = Common.fs(19),
                text_font_bold = false,
                radius = Size.radius.button,
                padding_v = self:_gap(12) + (self.compact and Screen:scaleBySize(2) or 0),
                show_parent = self,
                callback = function() Plugins.open(entry) end,
                hold_callback = function()
                    local ConfirmBox = require("ui/widget/confirmbox")
                    UIManager:show(ConfirmBox:new{
                        text = T(_("Unpin %1 from Home?"), entry.text),
                        ok_text = _("Unpin"),
                        ok_callback = function()
                            Plugins.setPinned(entry.name, false)
                            self:refresh()
                        end,
                    })
                end,
            }
            table.insert(row, btn)
            table.insert(layout_row, btn)
        end
        add(row)
        space(gap)
        table.insert(self.layout, layout_row)
    end
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
