--[[--
Quick settings (like a Kindle's swipe-down panel), opened from Home by
swiping down or tapping the status line.

Every entry sends the same event as KOReader's own gesture/Dispatcher action,
to the file manager's listeners, so the behaviour is KOReader's:

    Frontlight…      ShowFlDialog      (KOReader's light dialog, warmth too)
    Light on / off   ToggleFrontlight
    Night mode       ToggleNightMode
    Wi-Fi on / off   ToggleWifi
    Sleep            RequestSuspend

Entries the device does not support are left out. Nothing runs until a
button is tapped.

@module kindleui.ui.quicksettings
]]

local ButtonDialog = require("ui/widget/buttondialog")
local Device = require("device")
local Event = require("ui/event")
local UIManager = require("ui/uimanager")
local _ = require("gettext")

local QuickSettings = {}

local function wifiOn()
    local ok, NetworkMgr = pcall(require, "ui/network/manager")
    return ok and NetworkMgr:isWifiOn()
end

--- Shows the panel. `plugin.ui` (the FileManager) receives the events;
-- `on_change` (optional) redraws the caller afterwards (e.g. Home's status).
function QuickSettings.show(plugin, on_change)
    local ui = plugin and plugin.ui
    local dialog
    local function send(name)
        UIManager:close(dialog)
        if ui and ui.handleEvent then
            ui:handleEvent(Event:new(name))
        else
            UIManager:broadcastEvent(Event:new(name))
        end
        if on_change then
            -- after KOReader has handled it (Wi-Fi state changes asynchronously)
            UIManager:scheduleIn(1, on_change)
        end
    end
    local buttons = {}
    if Device:hasFrontlight() then
        local powerd = Device:getPowerDevice()
        table.insert(buttons, {
            {
                text = _("Frontlight…"),
                callback = function() send("ShowFlDialog") end,
            },
            {
                text = powerd:isFrontlightOn() and _("Light off") or _("Light on"),
                callback = function() send("ToggleFrontlight") end,
            },
        })
    end
    local night = G_reader_settings:isTrue("night_mode")
    local row = {{
        text = night and _("Night mode: on") or _("Night mode: off"),
        callback = function() send("ToggleNightMode") end,
    }}
    if Device:hasWifiToggle() then
        table.insert(row, {
            text = wifiOn() and _("Wi-Fi: on") or _("Wi-Fi: off"),
            callback = function() send("ToggleWifi") end,
        })
    end
    table.insert(buttons, row)
    if Device:canSuspend() then
        table.insert(buttons, {{
            text = _("Sleep"),
            callback = function() send("RequestSuspend") end,
        }})
    end
    dialog = ButtonDialog:new{
        title = _("Quick settings"),
        title_align = "center",
        buttons = buttons,
    }
    UIManager:show(dialog)
    return dialog
end

return QuickSettings
