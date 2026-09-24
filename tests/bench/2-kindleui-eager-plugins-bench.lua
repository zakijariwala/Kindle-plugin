-- Emulator-only KOReader user patch (never shipped in the plugin): measures
-- what the *previous* Installed Plugins screen did on every open, i.e. calling
-- addToMainMenu() of every loaded plugin, so it can be compared with the
-- current lazy version. Mounted into <data>/patches/ by tests/bench/run.sh.
local UIManager = require("ui/uimanager")
UIManager:scheduleIn(8, function()
    local PluginLoader = require("pluginloader")
    local Perf = require("kindleui/util/perf")
    local Plugins = require("kindleui/ui/plugins")
    local enabled = PluginLoader:loadPlugins()
    for run = 1, 3 do
        local t0 = Perf.start()
        local n, items = 0, 0
        for __, module in ipairs(enabled) do
            local inst = PluginLoader:getPluginInstance(module.name)
            if inst then
                n = n + 1
                items = items + #Plugins.collectMenuItems(inst)
            end
        end
        Perf.log("BENCH eager plugin menus (old behaviour) run " .. run, t0, { plugins = n, menu_items = items })
    end
end)
