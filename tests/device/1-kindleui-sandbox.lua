-- Device-test-only KOReader user patch (never shipped; installed by
-- `tools/kindle.sh setup`, removed by `tools/kindle.sh teardown`).
--
-- "1-" patches run before KOReader opens its settings. When
-- /tmp/kindleui-sandbox exists (it holds a folder path), KOReader uses that
-- folder as its data folder for this one start: its own settings, reading
-- history, collections, statistics and caches. The real profile is not read
-- or written. The switch is used up here, so the next start (a restart, a
-- crash, a reboot) is always the real profile again.
local f = io.open("/tmp/kindleui-sandbox", "r")
if not f then return end
local dir = f:read("*l")
f:close()
os.remove("/tmp/kindleui-sandbox")
if not dir or dir == "" then return end

local DataStorage = require("datastorage")
local userpatch = require("userpatch")
local lfs = require("libs/libkoreader-lfs")
-- What DataStorage creates for a new data folder (its initDataDir only runs
-- for the folder it found itself).
for __, sub in ipairs({ "", "/cache", "/clipboard", "/data", "/data/dict", "/data/tessdata",
                        "/ota", "/plugins", "/screenshots", "/settings", "/styletweaks" }) do
    if lfs.attributes(dir .. sub, "mode") ~= "directory" then lfs.mkdir(dir .. sub) end
end
for __, pair in ipairs({ { DataStorage.getDataDir, "data_dir" }, { DataStorage.getFullDataDir, "full_data_dir" } }) do
    local __, idx = userpatch.getUpValue(pair[1], pair[2])
    userpatch.replaceUpValue(pair[1], idx, dir)
end
require("logger").info("KINDLEUI SANDBOX data folder " .. DataStorage:getDataDir())
