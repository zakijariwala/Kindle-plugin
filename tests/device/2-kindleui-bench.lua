-- Device-test-only KOReader user patch (never shipped): the same sequence as
-- tests/bench/run.sh in the emulator, driven through the plugin's own
-- functions instead of screen taps. Copied into koreader/patches by
-- `tools/kindle.sh bench`, which also prepends a line that makes it do
-- nothing outside the scratch profile.
--
-- Phase 1: Home → My Library (cold: no cache, sidecar reads, cover
-- extraction) → close → My Library (warm) → page 2 (extraction) → page 1
-- (cached) → close → Installed Plugins ×2 → restart into the scratch profile
-- again. Phase 2 (new process): My Library (cache file load) → done.
-- Every timing is a "KindleUI perf:" line; this patch only logs
-- "KINDLEUI BENCH <step>" markers.
local UIManager = require("ui/uimanager")
local logger = require("logger")
local DataStorage = require("datastorage")

local PHASE_FILE = DataStorage:getDataDir() .. "/bench-phase"
local function top() return UIManager:getTopmostVisibleWidget() end
local function plugin() return require("apps/filemanager/filemanager").instance.kindleui end
local function mark(s) logger.info("KINDLEUI BENCH " .. s) end
local function closeTop() local w = top() if w then UIManager:close(w) end end
local function idle(w) return w and not w.extract_job end -- no cover job running

local phase2 = io.open(PHASE_FILE, "r")
if phase2 then phase2:close() end

local steps
if not phase2 then
    steps = {
        { "leave the book", function()
            local ReaderUI = require("apps/reader/readerui")
            if ReaderUI.instance then ReaderUI.instance:onHome() end
        end, 5 },
        { "library cold", function() plugin():showLibrary() end, 3 },
        { "wait covers", function() assert(idle(top()), "extracting") end, retry = 120 },
        { "close library", closeTop, 3 },
        { "library warm", function() plugin():showLibrary() end, 3 },
        { "page 2", function() top():onNextPage() end, 3 },
        { "wait covers page 2", function() assert(idle(top()), "extracting") end, retry = 120 },
        { "page 1", function() top():onPrevPage() end, 3 },
        { "page 2 again", function() top():onNextPage() end, 3 },
        { "close library 2", closeTop, 3 },
        { "plugins", function() plugin():showPlugins() end, 3 },
        { "close plugins", closeTop, 2 },
        { "plugins again", function() plugin():showPlugins() end, 3 },
        { "close plugins 2", closeTop, 2 },
        { "restart (cache on disk)", function()
            local f = io.open(PHASE_FILE, "w") f:write("2") f:close()
            -- the scratch-profile switch is used up by each start: set it again
            local s = io.open("/tmp/kindleui-sandbox", "w") s:write(DataStorage:getDataDir(), "\n") s:close()
            UIManager:restartKOReader()
        end, 30 },
    }
else
    steps = {
        { "library after restart", function() plugin():showLibrary() end, 4 },
        { "close library 3", function() closeTop() os.remove(PHASE_FILE) end, 2 },
        { "DONE", function()
            if require("device"):isKindle() then os.execute("lipc-set-prop com.lab126.powerd preventScreenSaver 0") end
        end },
    }
end

local i = 0
local function nextStep()
    i = i + 1
    local step = steps[i]
    if not step then return end
    local ok, err = pcall(step[2])
    if not ok and step.retry and (step.tries or 0) < step.retry then
        step.tries = (step.tries or 0) + 1
        i = i - 1
        UIManager:scheduleIn(1, nextStep)
        return
    end
    mark((ok and "" or "FAIL ") .. step[1] .. (ok and "" or (": " .. tostring(err))))
    UIManager:scheduleIn(step[3] or 2, nextStep)
end
-- hold the Kindle's own sleep timer (it only sees real touches)
if require("device"):isKindle() then os.execute("lipc-set-prop com.lab126.powerd preventScreenSaver 1") end
UIManager:scheduleIn(phase2 and 4 or 6, nextStep)
