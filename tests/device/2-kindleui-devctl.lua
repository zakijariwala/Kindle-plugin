-- Device-test-only KOReader user patch (never shipped; installed by
-- `tools/kindle.sh setup`, removed by `tools/kindle.sh teardown`).
--
-- Lets tools/kindle.sh drive KOReader over SSH: it writes one command into
-- /tmp/kindleui-devctl.cmd, this patch runs it and logs "KINDLEUI DEVCTL ...".
--   restart         KOReader's own restart (exit code 85: koreader.sh starts
--                   it again; the Kindle framework is never involved)
--   books | plugin  open Send Book, switch with the real Send Plugin / Send
--                   Book button, and log the session URL (the plugin itself
--                   never logs tokens)
--   close           close the topmost widget
--   confirm         tap OK on the topmost confirm box
--   top             log the topmost widget's name and text
--   loaded <name>   log whether plugin <name> is loaded
--   shot <file.png> save a screenshot of what is on screen
--   home | connectivity  open that screen (for screenshots)
--   airplane on|off|state  the Connectivity screen's airplane switch (cuts
--                   Wi-Fi: only drive it from a script running on the Kindle)
local UIManager = require("ui/uimanager")
local logger = require("logger")

local CMD = "/tmp/kindleui-devctl.cmd"
local function say(msg) logger.info("KINDLEUI DEVCTL " .. msg) end
local function fm() return require("apps/filemanager/filemanager").instance end
local function oneLine(s) return (tostring(s):gsub("%s+", " ")) end

local commands = {
    restart = function()
        say("restarting")
        UIManager:restartKOReader()
    end,
    books = true, plugin = true,
    close = function(top)
        if top then UIManager:close(top) end
        say("closed")
    end,
    confirm = function(top)
        assert(top and top.ok_callback, "no confirm box on top")
        say("confirming: " .. oneLine(top.text))
        UIManager:close(top)
        top.ok_callback()
    end,
    top = function(top)
        say("top " .. tostring(top and top.name) .. " " .. oneLine(top and top.text))
    end,
}

local function transfer(kind, top)
    if not (top and top.name == "kindleui_transfer") then
        fm().kindleui:showTransfer()
        top = UIManager:getTopmostVisibleWidget()
    end
    if top.kind ~= kind then
        top.layout[#top.layout][1].callback() -- the Send Plugin / Send Book button
    end
    say("url " .. kind .. " " .. top.session.url)
end

local function poll()
    local f = io.open(CMD, "r")
    if f then
        local line = f:read("*l") or ""
        f:close()
        os.remove(CMD)
        local ok, err = pcall(function()
            local top = UIManager:getTopmostVisibleWidget()
            local name, arg = line:match("^(%S+)%s*(.*)$")
            if name == "books" or name == "plugin" then
                transfer(name, top)
            elseif name == "shot" then
                require("device").screen.bb:writePNG(arg)
                say("shot " .. arg)
            elseif name == "home" then
                fm().kindleui:showHome()
                say("home")
            elseif name == "connectivity" then
                local root = require("kindleui/ui/settings").build(fm().kindleui)
                for __, e in ipairs(root) do
                    if e.text == "Connectivity" then
                        require("kindleui/ui/common").showTouchMenu(e.sub_item_table, nil, function() end)
                    end
                end
                say("connectivity")
            elseif name == "airplane" then
                local W = require("kindleui/util/kindlewifi")
                if arg == "on" or arg == "off" then W.setAirplaneMode(arg == "on") end
                say("airplane " .. tostring(W.airplaneMode()))
            elseif name == "loaded" then
                say("loaded " .. arg .. " " .. tostring(fm() and fm()[arg] ~= nil))
            elseif commands[name] then
                commands[name](top)
            else
                say("unknown command " .. tostring(line))
            end
        end)
        if not ok then say("error " .. tostring(err)) end
    end
    UIManager:scheduleIn(2, poll)
end

UIManager:scheduleIn(2, function()
    say("ready")
    poll()
end)
