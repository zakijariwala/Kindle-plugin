-- Unit tests for kindleui/util/format.lua
local T = require("harness")
local Format = require("kindleui/util/format")

T.section("sizes")
T.eq(Format.size(0), "1 KB", "zero shows as 1 KB")
T.eq(Format.size(850 * 1024), "850 KB", "KB")
T.eq(Format.size(3.4 * 1024 * 1024), "3.4 MB", "MB")
T.eq(Format.size(1.2 * 1024 ^ 3), "1.2 GB", "GB")

T.section("durations")
T.eq(Format.duration(8.4), "8 s", "seconds")
T.eq(Format.duration(125), "2 min", "minutes")
T.eq(Format.duration(3900), "1 h 5 min", "hours")
T.eq(Format.duration(-3), "0 s", "never negative")

T.section("transfer rate")
T.ok(Format.rate(1000, 5000, 0.5) == nil, "no figure under a second")
T.ok(Format.rate(0, 5000, 3) == nil, "no figure before any data")
T.eq(Format.rate(2 * 1024 * 1024, 10 * 1024 * 1024, 2), "1.0 MB/s · about 8 s left", "speed and time left")
T.eq(Format.rate(4 * 1024 * 1024, 4 * 1024 * 1024, 2), "2.0 MB/s", "no time left once complete")
T.done()
