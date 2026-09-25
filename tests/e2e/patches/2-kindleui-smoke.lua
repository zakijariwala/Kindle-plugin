-- Emulator-only KOReader user patch (never shipped): exercises every screen
-- and action of the plugin in sequence, through its own functions, and logs
--   "KINDLEUI SMOKE ok <step>" / "KINDLEUI SMOKE FAIL <step>: <error>"
-- then "KINDLEUI SMOKE DONE failures=<n>". Errors that happen later (while
-- painting) are caught by tests/e2e/smoke.sh grepping the log.
local UIManager = require("ui/uimanager")
local logger = require("logger")

local failures = 0
local function top() return UIManager:getTopmostVisibleWidget() end
local function closeTop() local w = top() if w then UIManager:close(w) end end
local function plugin()
    local FileManager = require("apps/filemanager/filemanager")
    return FileManager.instance and FileManager.instance.kindleui
end
local function setting(key, value)
    require("kindleui/config").set(key, value)
end

local steps = {
    -- KOReader's first launch opens its quickstart guide: leave it the way a
    -- user does (Home), which must bring up our Home screen.
    { "leave the book", function()
        local ReaderUI = require("apps/reader/readerui")
        if ReaderUI.instance then ReaderUI.instance:onHome() end
    end, 4 },
    { "home shown at startup", function() assert(top() and top().name == "kindleui_home", "top is " .. tostring(top() and top().name)) end },
    { "library grid", function() plugin():showLibrary() assert(top().name == "kindleui_library_grid") end },
    { "grid next page", function() top():onNextPage() end },
    { "grid prev page", function() top():onPrevPage() end },
    { "grid filter reading", function() setting("library_filter", "reading") top():reload() end },
    { "grid search", function() require("kindleui/ui/library").session.search = "book" top():reload() end },
    { "grid clear search + filter", function() require("kindleui/ui/library").session.search = nil setting("library_filter", "all") top():reload() end },
    { "grid prepare all covers", function() top():prepareAll() end, 12 },
    { "grid options dialog", function() require("kindleui/ui/library").showOptions(top(), plugin()) end },
    { "close options", closeTop },
    { "close grid", closeTop },
    { "library list", function() setting("library_view", "list") plugin():showLibrary() assert(top().name == "kindleui_library") end },
    { "list sort by title", function() setting("library_sort", "title") top():reload() end },
    { "close list", function() closeTop() setting("library_view", "covers") setting("library_sort", "recent") end },
    { "installed plugins", function() plugin():showPlugins() assert(top().name == "kindleui_plugins") end },
    { "open a plugin menu", function()
        local Plugins = require("kindleui/ui/plugins")
        local entry = Plugins.find(plugin(), "autowarmth") or Plugins.find(plugin(), "calibre")
        assert(entry, "no test plugin found")
        Plugins.open(entry)
    end },
    { "close plugin menu", closeTop },
    { "pin two plugins", function()
        local Plugins = require("kindleui/ui/plugins")
        Plugins.setPinned("calibre", true)
        Plugins.setPinned("statistics", true)
    end },
    { "close plugins", closeTop },
    { "home refresh (pinned, recent, status)", function() plugin():showHome() end },
    { "text size large", function() setting("text_size", "large") plugin():showHome() end },
    { "text size small", function() setting("text_size", "small") plugin():showHome() end },
    { "text size medium", function() setting("text_size", "medium") plugin():showHome() end },
    { "settings menu", function() plugin():showSettings() end },
    { "close settings", closeTop },
    { "send book screen", function() plugin():showTransfer() assert(top().name == "kindleui_transfer") end, 3 },
    { "send book new code", function() top():startSession() end, 2 },
    { "close send book", closeTop },
    { "unpin plugins", function()
        local Plugins = require("kindleui/ui/plugins")
        Plugins.setPinned("calibre", false)
        Plugins.setPinned("statistics", false)
        plugin():showHome()
    end },
}

local i = 0
local function nextStep()
    i = i + 1
    local step = steps[i]
    if not step then
        logger.info("KINDLEUI SMOKE DONE failures=" .. failures)
        return
    end
    local ok, err = pcall(step[2])
    if ok then
        logger.info("KINDLEUI SMOKE ok " .. step[1])
    else
        failures = failures + 1
        logger.warn("KINDLEUI SMOKE FAIL " .. step[1] .. ": " .. tostring(err))
    end
    UIManager:scheduleIn(step[3] or 1.5, nextStep)
end
UIManager:scheduleIn(6, nextStep)
