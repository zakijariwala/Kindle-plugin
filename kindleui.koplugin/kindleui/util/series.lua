--[[--
Series grouping for My Library. Pure Lua (unit-tested in tests/test_series.lua).

Books carry `series` and `series_index` from their metadata (see
util/librarycache.lua). With grouping on, every series of two or more books
becomes one item, placed where its first book would be in the current sort
order; books without a series (or alone in theirs) stay as they are.

@module kindleui.util.series
]]

local Series = {}

local function byIndex(a, b)
    local ia, ib = a.series_index, b.series_index
    if ia and ib and ia ~= ib then return ia < ib end
    if ia and not ib then return true end
    if ib and not ia then return false end
    return (a.title or ""):lower() < (b.title or ""):lower()
end

--- The books of one series, in reading order (series index, then title).
function Series.members(books, name)
    local out = {}
    for __, b in ipairs(books) do
        if b.series == name then table.insert(out, b) end
    end
    table.sort(out, byIndex)
    return out
end

--- Collapses each series of 2+ books into one group item:
-- { is_series = true, series, title, count, books, path, entry, authors }
-- (`path` and `entry` are those of the first book in reading order, so the
-- group shows that book's cover).
function Series.group(books)
    local counts = {}
    for __, b in ipairs(books) do
        if b.series then counts[b.series] = (counts[b.series] or 0) + 1 end
    end
    local out, placed = {}, {}
    for __, b in ipairs(books) do
        local name = b.series
        if name and counts[name] >= 2 then
            if not placed[name] then
                placed[name] = true
                local members = Series.members(books, name)
                local first = members[1]
                table.insert(out, {
                    is_series = true,
                    series = name,
                    title = name,
                    count = #members,
                    books = members,
                    path = first.path,
                    entry = first.entry,
                    authors = first.authors,
                })
            end
        else
            table.insert(out, b)
        end
    end
    return out
end

--- Number of books behind a list that may contain groups.
function Series.bookCount(items)
    local n = 0
    for __, it in ipairs(items) do n = n + (it.is_series and it.count or 1) end
    return n
end

return Series
