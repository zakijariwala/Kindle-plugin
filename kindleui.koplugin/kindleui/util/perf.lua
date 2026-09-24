--[[--
Timing and memory probes, logged as single "KindleUI perf:" lines so screen
open times and memory can be measured on a device from crash.log.

    local t = Perf.start()
    ...
    Perf.log("library open", t, { books = 120 })

@module kindleui.util.perf
]]

local logger = require("logger")
local time = require("ui/time")

local Perf = {}

-- The fine-grained monotonic clock (time.now is the coarse one).
function Perf.start()
    return time.monotonic()
end

--- Milliseconds since `t0` (from Perf.start()).
function Perf.ms(t0)
    return time.to_ms(time.monotonic() - t0)
end

--- Resident memory of this process in KiB (Linux), or nil.
function Perf.rssKB()
    local f = io.open("/proc/self/status", "r")
    if not f then return nil end
    local s = f:read("*a")
    f:close()
    return tonumber(s:match("VmRSS:%s*(%d+)"))
end

--- Logs `label: N ms` plus optional fields, Lua heap and RSS.
function Perf.log(label, t0, fields)
    local parts = { string.format("%s: %d ms", label, Perf.ms(t0)) }
    for k, v in pairs(fields or {}) do
        table.insert(parts, string.format("%s=%s", k, tostring(v)))
    end
    table.insert(parts, string.format("lua_heap=%dKB", math.floor(collectgarbage("count"))))
    local rss = Perf.rssKB()
    if rss then table.insert(parts, string.format("rss=%dKB", rss)) end
    logger.info("KindleUI perf:", table.concat(parts, " "))
end

return Perf
