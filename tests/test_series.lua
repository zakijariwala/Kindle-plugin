-- Unit tests for series grouping (pure Lua).
local T = require("harness")
local Series = require("kindleui/util/series")

local function book(path, title, series, index)
    return { path = path, title = title, series = series, series_index = index, entry = { path = path } }
end

-- Library sort order: most recent first.
local books = {
    book("/b/hp3", "Prisoner", "Harry Potter", 3),
    book("/b/solo", "A Standalone"),
    book("/b/hp1", "Stone", "Harry Potter", 1),
    book("/b/one", "Only One", "Lonely Series", 1),
    book("/b/hp2", "Chamber", "Harry Potter", 2),
    book("/b/dune", "Dune", "Dune", nil),
    book("/b/dune2", "Dune Messiah", "Dune", nil),
}

T.section("members")
local hp = Series.members(books, "Harry Potter")
T.eq(#hp, 3, "three books")
T.eq(hp[1].title .. "," .. hp[2].title .. "," .. hp[3].title, "Stone,Chamber,Prisoner", "reading order by index")
local dune = Series.members(books, "Dune")
T.eq(dune[1].title, "Dune", "no index: by title")

T.section("group")
local items = Series.group(books)
T.eq(#items, 4, "HP group, standalone, lonely book, Dune group")
T.ok(items[1].is_series and items[1].series == "Harry Potter", "group placed where its first book was (most recent)")
T.eq(items[1].count, 3, "group count")
T.eq(items[1].path, "/b/hp1", "group shows book 1's cover")
T.eq(items[1].entry.path, "/b/hp1", "group entry is book 1's")
T.eq(items[2].path, "/b/solo", "standalone kept in place")
T.ok(not items[3].is_series and items[3].path == "/b/one", "a series of one book is not grouped")
T.ok(items[4].is_series and items[4].count == 2, "Dune grouped")
T.eq(Series.bookCount(items), #books, "book count through groups")
T.eq(#Series.group({}), 0, "empty library")
local mixed = { book("/x", "X", "S", 2), book("/y", "Y", "S", 1.5) }
T.eq(Series.members(mixed, "S")[1].path, "/y", "fractional index")

T.done()
