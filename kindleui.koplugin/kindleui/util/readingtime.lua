--[[--
"Time left in book" for Home's Continue Reading card, from the data KOReader's
Statistics plugin already records (settings/statistics.sqlite3). Nothing is
shown when Statistics is disabled or has too little data for the book.

Estimate (the same as Statistics' own): average time per page read so far ×
pages left. One small read-only query, cached in memory per book and
sidecar version, so rebuilding Home does not repeat it.

@module kindleui.util.readingtime
]]

local ReadingTime = {
    MIN_PAGES = 5, -- fewer pages read than this: no estimate
}

--- Seconds left, or nil when there is not enough data. Pure (unit-tested).
-- @number read_time seconds spent in the book so far
-- @number read_pages distinct pages read so far
-- @number pages page count of the book
-- @number percent progress, 0..1
function ReadingTime.estimate(read_time, read_pages, pages, percent)
    read_time, read_pages, pages = tonumber(read_time), tonumber(read_pages), tonumber(pages)
    if not (read_time and read_pages and pages and percent) then return nil end
    if read_pages < ReadingTime.MIN_PAGES or read_time <= 0 or pages <= 0 then return nil end
    if percent >= 1 then return nil end
    local left = math.max(0, pages * (1 - percent))
    return math.floor(left * read_time / read_pages + 0.5)
end

--- True if the Statistics plugin is enabled (plugin and its own switch).
function ReadingTime.statisticsEnabled()
    local disabled = G_reader_settings:readSetting("plugins_disabled") or {}
    if disabled.statistics then return false end
    local settings = G_reader_settings:readSetting("statistics") or {}
    return settings.is_enabled ~= false
end

local cache = {} -- file -> { key, seconds|false }

-- Statistics' row for the book with this partial md5: time, pages read, pages.
local function queryBook(md5)
    local DataStorage = require("datastorage")
    local lfs = require("libs/libkoreader-lfs")
    local db = DataStorage:getSettingsDir() .. "/statistics.sqlite3"
    if lfs.attributes(db, "mode") ~= "file" then return nil end
    local SQ3 = require("lua-ljsqlite3/init")
    local conn = SQ3.open(db, "ro")
    local ok, row = pcall(function()
        local stmt = conn:prepare("SELECT total_read_time, total_read_pages, pages FROM book WHERE md5 = ? ORDER BY last_open DESC LIMIT 1;")
        local r = stmt:reset():bind(md5):step()
        stmt:close()
        return r
    end)
    conn:close()
    if not ok or not row then return nil end
    return tonumber(row[1]), tonumber(row[2]), tonumber(row[3])
end

--- Seconds left in `file` (progress `percent`), or nil.
-- @param sdr_key changes whenever the book's sidecar changes (cache key)
function ReadingTime.secondsLeft(file, percent, sdr_key)
    if not percent or not ReadingTime.statisticsEnabled() then return nil end
    local key = tostring(sdr_key) .. ":" .. tostring(percent)
    local hit = cache[file]
    if hit and hit.key == key then return hit.seconds or nil end
    local seconds
    local ok, err = pcall(function()
        local BookList = require("ui/widget/booklist")
        if not BookList.hasBookBeenOpened(file) then return end
        local md5 = BookList.getDocSettings(file):readSetting("partial_md5_checksum")
        if not md5 then return end
        local read_time, read_pages, pages = queryBook(md5)
        seconds = ReadingTime.estimate(read_time, read_pages, pages, percent)
    end)
    if not ok then require("logger").warn("KindleUI: reading time estimate failed:", err) end
    cache[file] = { key = key, seconds = seconds or false }
    return seconds
end

--- "2:15 left" / "2h 15m left", in the user's KOReader duration format.
function ReadingTime.text(seconds)
    local _ = require("gettext")
    local datetime = require("datetime")
    local format = G_reader_settings:readSetting("duration_format", "classic")
    return require("ffi/util").template(_("%1 left"), datetime.secondsToClockDuration(format, seconds, true))
end

return ReadingTime
