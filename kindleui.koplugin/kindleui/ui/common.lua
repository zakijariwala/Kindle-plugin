--[[--
Shared UI helpers built only from stock KOReader widgets.

@module kindleui.ui.common
]]

local Blitbuffer = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local Font = require("ui/font")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local InputContainer = require("ui/widget/container/inputcontainer")
local LineWidget = require("ui/widget/linewidget")
local Size = require("ui/size")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local Screen = Device.screen

local Common = {}

Common.SIDE_MARGIN = Screen:scaleBySize(28)

-- Settings → Library → Text size (Home, Library, Send Book).
Common.TEXT_SIZES = {
    { id = "small", factor = 0.85 },
    { id = "medium", factor = 1.0 },
    { id = "large", factor = 1.2 },
}

--- Scales a font size by the chosen text size.
function Common.fs(size)
    local id = require("kindleui/config").get("text_size")
    for __, t in ipairs(Common.TEXT_SIZES) do
        if t.id == id then return math.floor(size * t.factor + 0.5) end
    end
    return size
end

function Common.face(kind)
    local fs = Common.fs
    if kind == "title" then return Font:getFace("tfont", fs(26)) end
    if kind == "nav" then return Font:getFace("cfont", fs(24)) end
    if kind == "book_title" then return Font:getFace("tfont", fs(21)) end
    if kind == "body" then return Font:getFace("cfont", fs(19)) end
    if kind == "small" then return Font:getFace("cfont", fs(16)) end
    if kind == "label" then return Font:getFace("cfont", fs(17)) end
    return Font:getFace("cfont", fs(20))
end

function Common.line(width, thick)
    return LineWidget:new{
        dimen = Geom:new{ w = width, h = thick and Size.line.thick or Size.line.medium },
        background = thick and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_GRAY,
    }
end

function Common.label(text, width)
    return TextWidget:new{
        text = text,
        face = Common.face("label"),
        fgcolor = Blitbuffer.COLOR_DARK_GRAY,
        max_width = width,
    }
end

--- A plain "text cover" (title + author in a frame) for books without a
-- cover image, like a Kindle shows.
function Common.textCover(title, authors, w, h)
    local FrameContainer = require("ui/widget/container/framecontainer")
    local TextBoxWidget = require("ui/widget/textboxwidget")
    local VerticalGroup = require("ui/widget/verticalgroup")
    local VerticalSpan = require("ui/widget/verticalspan")
    local pad = Screen:scaleBySize(8)
    local small = h < Screen:scaleBySize(200)
    local vg = VerticalGroup:new{ align = "center" }
    table.insert(vg, TextBoxWidget:new{
        text = title or "",
        face = Font:getFace("tfont", Common.fs(small and 13 or 17)),
        width = w - 2 * pad,
        alignment = "center",
        height = math.floor(h * (authors and 0.6 or 0.85)),
        height_adjust = true,
        height_overflow_show_ellipsis = true,
    })
    if authors then
        table.insert(vg, VerticalSpan:new{ width = pad })
        table.insert(vg, TextBoxWidget:new{
            text = authors,
            face = Font:getFace("cfont", Common.fs(small and 11 or 14)),
            width = w - 2 * pad,
            alignment = "center",
            height = math.floor(h * 0.25),
            height_adjust = true,
            height_overflow_show_ellipsis = true,
        })
    end
    return FrameContainer:new{
        width = w,
        height = h,
        bordersize = Size.border.thin,
        padding = 0,
        background = Blitbuffer.COLOR_WHITE,
        CenterContainer:new{
            dimen = Geom:new{ w = w - 2 * Size.border.thin, h = h - 2 * Size.border.thin },
            vg,
        },
    }
end

--- A container that calls `callback` when tapped anywhere inside its content.
-- Also focusable for devices with keys only (FocusManager sends Tap events).
Common.Tappable = InputContainer:extend{
    callback = nil,
    hold_callback = nil,
}

function Common.Tappable:init()
    self.ges_events.Tap = {
        GestureRange:new{
            ges = "tap",
            range = function() return self.dimen end,
        },
    }
    if self.hold_callback then
        self.ges_events.Hold = {
            GestureRange:new{
                ges = "hold",
                range = function() return self.dimen end,
            },
        }
    end
end

function Common.Tappable:onTap()
    if self.callback then self.callback() end
    return true
end

function Common.Tappable:onHold()
    if self.hold_callback then self.hold_callback() end
    return true
end

function Common.Tappable:onFocus()
    local frame = self[1]
    if frame and frame.bordersize then
        self._orig_border = self._orig_border or frame.bordersize
        frame.bordersize = self._orig_border + Size.border.thick
        frame.padding = frame.padding - Size.border.thick
    end
    return true
end

function Common.Tappable:onUnfocus()
    local frame = self[1]
    if frame and self._orig_border then
        frame.bordersize = self._orig_border
        frame.padding = frame.padding + Size.border.thick
    end
    return true
end

--- Shows KOReader's native TouchMenu with a single tab.
-- Items use the standard KOReader menu-item format (text, callback,
-- sub_item_table, checked_func, enabled_func, keep_menu_open, ...), which
-- lets us embed KOReader's *own* menu entries unchanged.
function Common.showTouchMenu(items, icon, on_close)
    local menu_container = CenterContainer:new{
        ignore = "height",
        dimen = Screen:getSize(),
    }
    local tab = { icon = icon or "appbar.settings" }
    for i, item in ipairs(items) do tab[i] = item end
    local main_menu
    if Device:isTouchDevice() or Device:hasDPad() then
        local TouchMenu = require("ui/widget/touchmenu")
        main_menu = TouchMenu:new{
            width = Screen:getWidth(),
            tab_item_table = { tab },
            show_parent = menu_container,
        }
    else
        local Menu = require("ui/widget/menu")
        main_menu = Menu:new{
            title = "",
            item_table = items,
            width = Screen:getWidth() - (Size.margin.fullscreen_popout * 2),
            show_parent = menu_container,
        }
    end
    main_menu.close_callback = function()
        UIManager:close(menu_container)
        if on_close then on_close() end
    end
    menu_container[1] = main_menu
    UIManager:show(menu_container)
    return menu_container
end

return Common
