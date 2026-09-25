-- Emulator-only KOReader user patch (never shipped), used by
-- tests/e2e/plugininstall.sh: runs the commands the script drops into
-- /e2e/cmd ("open", "confirm", "undo") and logs "KINDLEUI PI <what>".
local UIManager = require("ui/uimanager")
local logger = require("logger")

local function log(...) logger.info("KINDLEUI PI", ...) end
local function top() return UIManager:getTopmostVisibleWidget() end
local function plugin()
    local FileManager = require("apps/filemanager/filemanager")
    return FileManager.instance and FileManager.instance.kindleui
end
local function oneLine(s) return (tostring(s or ""):gsub("\n+", " | ")) end

local commands = {
    open = function()
        plugin():showPluginTransfer()
        local w = top()
        assert(w.name == "kindleui_transfer" and w.session, "send plugin screen did not start a session")
        log("url " .. w.session.url)
    end,
    confirm = function()
        local box = top()
        assert(box and box.ok_callback, "no confirm box on top")
        log("confirm text: " .. oneLine(box.text))
        UIManager:close(box)
        box.ok_callback()
        -- KOReader shows its restart prompt on the next tick.
        UIManager:scheduleIn(1, function()
            local after = top()
            log("after confirm: " .. oneLine(after and after.text))
        end)
    end,
    remove = function()
        plugin():showPlugins()
        local list = top()
        local target
        for __, row in ipairs(list.item_table) do
            if row.entry and row.entry.name == "greeter" then target = row end
        end
        assert(target, "greeter not listed")
        list:onMenuHold(target)
        local hold = top()
        hold.buttons[#hold.buttons][1].callback() -- Select plugins to remove…
        assert(list.selecting and list.to_remove.greeter, "greeter not selected")
        list:onMenuChoice(list.item_table[1]) -- Remove 1 selected…
        local confirm = top()
        log("remove confirm: " .. oneLine(confirm.text))
        UIManager:close(confirm)
        confirm.ok_callback()
        UIManager:scheduleIn(1, function()
            local after = top()
            log("after remove: " .. oneLine(after and after.text))
        end)
    end,
    undo = function()
        local Installer = require("kindleui/util/plugininstaller")
        local record, err = Installer.undo()
        log("undo " .. (record and ("ok " .. record.name) or ("failed " .. tostring(err))))
        log("can undo again: " .. tostring(Installer.canUndo()))
    end,
}

local function poll()
    local f = io.open("/e2e/cmd", "r")
    if f then
        local cmd = f:read("*l")
        f:close()
        os.remove("/e2e/cmd")
        local ok, err = pcall(commands[cmd] or function() error("unknown command " .. tostring(cmd)) end)
        if not ok then log("FAIL " .. tostring(cmd) .. ": " .. tostring(err)) end
        log("done " .. tostring(cmd))
    end
    UIManager:scheduleIn(0.5, poll)
end

UIManager:scheduleIn(6, function()
    local ReaderUI = require("apps/reader/readerui")
    if ReaderUI.instance then ReaderUI.instance:onHome() end
    UIManager:scheduleIn(3, function()
        log("ready")
        poll()
    end)
end)
