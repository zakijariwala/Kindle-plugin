--[[--
Keeps the device awake while Send Book is open.

Two independent timers can put a Kindle to sleep while a phone is still
uploading, and upload traffic does not count as user activity for either:

1. KOReader's AutoSuspend plugin. It honours `PluginShare.pause_auto_suspend`
   (also used by the Keep alive and Autoturn plugins).
2. On Kindle, the system's own screensaver timer in powerd. KOReader's Keep
   alive plugin holds it with `lipc-set-prop com.lab126.powerd preventScreenSaver 1`.

We use the same two switches, remember what they were, and restore them, so
a Keep alive the user turned on themselves is never undone. KOReader's standby
(light sleep between inputs) is held with UIManager:preventStandby(), which
is reference counted.

@module kindleui.util.sleepguard
]]

local Device = require("device")
local PluginShare = require("pluginshare")
local UIManager = require("ui/uimanager")
local logger = require("logger")

local SleepGuard = {
    held = false,
}

function SleepGuard.hold()
    if SleepGuard.held then return end
    SleepGuard.held = true
    SleepGuard.prev_pause = PluginShare.pause_auto_suspend
    PluginShare.pause_auto_suspend = true
    UIManager:preventStandby()
    if Device:isKindle() then
        local rc = os.execute("lipc-set-prop com.lab126.powerd preventScreenSaver 1")
        if rc ~= 0 and rc ~= true then
            logger.warn("KindleUI: could not hold the Kindle screensaver timer, rc =", rc)
        end
    end
    logger.info("KindleUI: sleep held while Send Book is open")
end

function SleepGuard.release()
    if not SleepGuard.held then return end
    SleepGuard.held = false
    PluginShare.pause_auto_suspend = SleepGuard.prev_pause
    SleepGuard.prev_pause = nil
    UIManager:allowStandby()
    -- Leave it held if the user enabled Keep alive ("Stay alive") themselves.
    if Device:isKindle() and not PluginShare.keepalive then
        os.execute("lipc-set-prop com.lab126.powerd preventScreenSaver 0")
    end
    -- Restart the idle countdown from now, as if the user had just touched the
    -- screen; otherwise AutoSuspend could fire immediately after a long upload.
    if UIManager.event_hook then
        pcall(UIManager.event_hook.execute, UIManager.event_hook, "InputEvent")
    end
    logger.info("KindleUI: sleep released")
end

return SleepGuard
