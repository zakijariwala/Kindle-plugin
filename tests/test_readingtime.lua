-- Unit tests for the "time left" estimate (pure part).
local T = require("harness")
local ReadingTime = require("kindleui/util/readingtime")
local est = ReadingTime.estimate

T.section("estimate")
T.eq(est(3000, 50, 300, 0.5), 9000, "150 pages left at 60 s/page")
T.eq(est(600, 10, 100, 0.9), 600, "10 pages left at 60 s/page")
T.eq(est(0, 10, 100, 0.5), nil, "no time recorded")
T.eq(est(600, 4, 100, 0.5), nil, "fewer than MIN_PAGES read: no estimate")
T.eq(est(600, 10, 100, 1), nil, "finished: nothing left")
T.eq(est(600, 10, 0, 0.5), nil, "unknown page count")
T.eq(est(nil, 10, 100, 0.5), nil, "no statistics row")
T.eq(est("600", "10", "100", 0.5), 3000, "numbers stored as text")
T.eq(est(600, 10, 100, nil), nil, "no progress")
T.done()
