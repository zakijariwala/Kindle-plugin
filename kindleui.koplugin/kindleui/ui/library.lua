--[[--
"My Library": shared data loading + the options dialog, and the list view.

The default view is the cover grid (ui/librarygrid.lua); the list view below
is the compact alternative (Settings → Library → View). Both get their data
from `Library.loadBooks`, which scans the home folder and fills in metadata
from the plugin's own cache (util/librarycache.lua), so opening the Library
does not re-read every book's sidecar.

Collections are KOReader's own (readcollection.lua, the same ones as its file
browser); the Library only shows one of them as a filter.

@module kindleui.ui.library
]]

local Books = require("kindleui/util/books")
local ButtonDialog = require("ui/widget/buttondialog")
local Cache = require("kindleui/util/librarycache")
local Config = require("kindleui/config")
local Device = require("device")
local Menu = require("ui/widget/menu")
local Perf = require("kindleui/util/perf")
local Selection = require("kindleui/ui/selection")
local UIManager = require("ui/uimanager")
local ffiUtil = require("ffi/util")
local _ = require("gettext")
local T = require("ffi/util").template
local Screen = Device.screen

local SORTS = {
    { id = "recent", text = _("Recent") },
    { id = "title", text = _("Title") },
    { id = "author", text = _("Author") },
    { id = "added", text = _("Recently added") },
}
local FILTERS = {
    { id = "all", text = _("All") },
    { id = "unread", text = _("Unread") },
    { id = "reading", text = _("Reading") },
    { id = "finished", text = _("Finished") },
}
local VIEWS = {
    { id = "covers", text = _("Covers") },
    { id = "list", text = _("List") },
}

local Library = {
    SORTS = SORTS,
    VIEWS = VIEWS,
    FILTERS = FILTERS,
    -- Remembered for this KOReader session only (not saved to disk).
    session = { grid_page = 1, list_page = 1, search = nil },
}

local function lower(s) return s and s:lower() or "" end

--- Scans, annotates from the cache and sorts. Logs timings.
-- @treturn table array of books { path, name, mtime, size, title, authors, percent, status, entry }
function Library.loadBooks(plugin)
    local ui = plugin and plugin.ui
    local t0 = Perf.start()
    local books = Books.scan(Books.homeDir(), Config.get("library_max_depth"), Config.get("library_max_books"))
    local scan_ms = Perf.ms(t0)
    local t1 = Perf.start()
    local stats = Cache.annotate(ui, books)
    local meta_ms = Perf.ms(t1)
    local history = Books.historyTimes()
    for __, b in ipairs(books) do
        b.read_time = history[b.path] or 0
    end
    local sort = Config.get("library_sort")
    local strcoll = ffiUtil.strcoll
    local cmp
    if sort == "title" then
        cmp = function(a, b) return strcoll(lower(a.title), lower(b.title)) end
    elseif sort == "author" then
        cmp = function(a, b)
            if lower(a.authors) ~= lower(b.authors) then
                -- books without an author go last
                if not a.authors then return false end
                if not b.authors then return true end
                return strcoll(lower(a.authors), lower(b.authors))
            end
            return strcoll(lower(a.title), lower(b.title))
        end
    elseif sort == "added" then
        cmp = function(a, b) return (a.mtime or 0) > (b.mtime or 0) end
    else -- recent: last read first, then newest files
        cmp = function(a, b)
            if a.read_time ~= b.read_time then return a.read_time > b.read_time end
            return (a.mtime or 0) > (b.mtime or 0)
        end
    end
    table.sort(books, cmp)
    Cache.save()
    local shown = Library.applyCollection(books, Library.currentCollection())
    shown = Library.applySearch(Library.applyFilter(shown, Config.get("library_filter")), Library.session.search)
    Perf.log("library data", t0, {
        books = stats.books, shown = #shown, scan_ms = scan_ms, meta_ms = meta_ms,
        sidecar_reads = stats.sidecar_reads, new_entries = stats.new_entries,
    })
    return shown, #books, books
end

--- Reading state of a book: "unread" (never opened), "finished", or "reading".
function Library.readingState(b)
    if b.status == "complete" then return "finished" end
    if b.percent or b.status then return "reading" end
    return "unread"
end

--- Books matching a filter id ("all" | "unread" | "reading" | "finished").
function Library.applyFilter(books, filter)
    if not filter or filter == "all" then return books end
    local out = {}
    for __, b in ipairs(books) do
        if Library.readingState(b) == filter then table.insert(out, b) end
    end
    return out
end

-- Collections ------------------------------------------------------------------

local function readCollection()
    local ok, ReadCollection = pcall(require, "readcollection")
    if not ok or type(ReadCollection) ~= "table" then return nil end
    pcall(ReadCollection._read, ReadCollection) -- re-reads only if the file changed
    return ReadCollection.coll and ReadCollection or nil
end

--- Display name of a collection ("favorites" is KOReader's Favorites).
function Library.collectionTitle(name, plugin)
    local fmc = plugin and plugin.ui and plugin.ui.collections
    if fmc and fmc.getCollectionTitle then
        local ok, title = pcall(fmc.getCollectionTitle, fmc, name)
        if ok and title then return title end
    end
    local RC = readCollection()
    if RC and name == RC.default_collection_name then return _("Favorites") end
    return name
end

--- KOReader's collections: array of { name, title, count }, in KOReader's order.
function Library.collections(plugin)
    local RC = readCollection()
    if not RC then return {} end
    local list = {}
    for name, coll in pairs(RC.coll) do
        local n = 0
        for __ in pairs(coll) do n = n + 1 end
        local settings = RC.coll_settings and RC.coll_settings[name] or {}
        table.insert(list, { name = name, title = Library.collectionTitle(name, plugin), count = n, order = settings.order or 0 })
    end
    table.sort(list, function(a, b)
        if a.order ~= b.order then return a.order < b.order end
        return a.title < b.title
    end)
    return list
end

--- The collection the Library shows, or nil (all books). A collection that no
-- longer exists counts as nil.
function Library.currentCollection()
    local name = Config.get("library_collection")
    if not name then return nil end
    local RC = readCollection()
    if not RC or not RC.coll[name] then return nil end
    return name
end

--- Books in collection `name` (all books when nil).
function Library.applyCollection(books, name)
    if not name then return books end
    local RC = readCollection()
    local coll = RC and RC.coll[name]
    if not coll then return books end
    local out = {}
    for __, b in ipairs(books) do
        -- KOReader stores real paths; most books match directly.
        if coll[b.path] or coll[ffiUtil.realpath(b.path) or ""] then table.insert(out, b) end
    end
    return out
end

--- Lets the user pick the collection to show.
function Library.chooseCollection(widget, plugin)
    local dialog
    local current = Library.currentCollection()
    local function pick(name)
        UIManager:close(dialog)
        Config.set("library_collection", name)
        Library.session.grid_page, Library.session.list_page = 1, 1
        widget.page = 1
        widget:reload()
    end
    local buttons = {{{
        text = (current == nil and "✓ " or "") .. _("All books"),
        callback = function() pick(nil) end,
    }}}
    for __, c in ipairs(Library.collections(plugin)) do
        table.insert(buttons, {{
            text = (current == c.name and "✓ " or "") .. T("%1 (%2)", c.title, c.count),
            callback = function() pick(c.name) end,
        }})
    end
    if #buttons == 1 then
        table.insert(buttons, {{
            text = _("No collections yet. Hold a book → Collections…"),
            enabled = false,
        }})
    end
    dialog = ButtonDialog:new{
        title = _("Show collection"),
        title_align = "center",
        buttons = buttons,
    }
    UIManager:show(dialog)
end

--- Books whose title or author contains `query` (case-insensitive).
function Library.applySearch(books, query)
    if not query or query == "" then return books end
    local util = require("util")
    local lc = util.stringLower or string.lower -- UTF-8 aware when available
    local q = lc(query)
    local out = {}
    for __, b in ipairs(books) do
        if lc(b.title or ""):find(q, 1, true) or lc(b.authors or ""):find(q, 1, true) then
            table.insert(out, b)
        end
    end
    return out
end

--- Asks for a search term; empty = clear.
function Library.askSearch(widget)
    local InputDialog = require("ui/widget/inputdialog")
    local dialog
    local function apply(text)
        UIManager:close(dialog)
        Library.session.search = (text and text:match("%S")) and text:gsub("^%s+", ""):gsub("%s+$", "") or nil
        Library.session.grid_page, Library.session.list_page = 1, 1
        widget.page = 1
        widget:reload()
    end
    dialog = InputDialog:new{
        title = _("Search the library"),
        input = Library.session.search or "",
        input_hint = _("Title or author"),
        buttons = {{
            { text = _("Cancel"), id = "close", callback = function() UIManager:close(dialog) end },
            { text = _("Search"), is_enter_default = true, callback = function() apply(dialog:getInputText()) end },
        }},
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

--- Title-bar subtitle, e.g. "150 books" or "12 of 150 · Reading".
function Library.subtitle(shown, total)
    if Library.session.search then
        return T(_("“%1”: %2 of %3"), Library.session.search, shown, total)
    end
    local parts = {}
    local coll = Library.currentCollection()
    if coll then table.insert(parts, Library.collectionTitle(coll)) end
    local filter = Config.get("library_filter")
    if filter and filter ~= "all" then
        for __, f in ipairs(FILTERS) do
            if f.id == filter then table.insert(parts, f.text) end
        end
    end
    if #parts > 0 then
        return T(_("%1 of %2 · %3"), shown, total, table.concat(parts, " · "))
    end
    return T(_("%1 books"), total)
end

--- Message for an empty page: no books at all, or none matching the filter.
function Library.emptyText(total)
    if Library.session.search and total and total > 0 then
        return T(_("No books match “%1”.\nClear the search with the ☰ button (top left)."), Library.session.search)
    end
    if total and total > 0 then
        if Library.currentCollection() then
            return _("No books of this collection match.\nChange the collection or filter with the ☰ button (top left).")
        end
        return _("No books match this filter.\nChange it with the ☰ button (top left).")
    end
    return _("No books yet.\nUse Send Book on the Home screen to add one.")
end

--- Short progress label: "63%", "New" or "Finished".
function Library.progressText(b)
    if b.status == "complete" then return _("Finished") end
    if b.percent then return string.format("%d%%", math.floor(b.percent * 100 + 0.5)) end
    return _("New")
end

--- Opens the Library in the configured view.
function Library.show(plugin)
    local view
    if Config.get("library_view") == "list" then
        view = Library.List:new{ plugin = plugin }
    else
        view = require("kindleui/ui/librarygrid"):new{ plugin = plugin }
    end
    UIManager:show(view)
    return view
end

--- The ☰ dialog shared by both views. `widget` must implement reload()/close().
function Library.showOptions(widget, plugin)
    local dialog
    local current_sort = Config.get("library_sort")
    local current_view = Config.get("library_view")
    local buttons = {}
    local row = {}
    for __, v in ipairs(VIEWS) do
        table.insert(row, {
            text = (v.id == current_view and "✓ " or "") .. v.text,
            callback = function()
                UIManager:close(dialog)
                if v.id ~= current_view then
                    Config.set("library_view", v.id)
                    UIManager:close(widget)
                    Library.show(plugin)
                end
            end,
        })
    end
    table.insert(buttons, row)
    local current_filter = Config.get("library_filter")
    local filter_row = {}
    for __, f in ipairs(FILTERS) do
        table.insert(filter_row, {
            text = (f.id == current_filter and "✓ " or "") .. f.text,
            callback = function()
                UIManager:close(dialog)
                Config.set("library_filter", f.id)
                Library.session.grid_page, Library.session.list_page = 1, 1
                widget.page = 1
                widget:reload()
            end,
        })
    end
    table.insert(buttons, filter_row)
    local coll = Library.currentCollection()
    table.insert(buttons, {{
        text = coll and T(_("Collection: %1…"), Library.collectionTitle(coll, plugin)) or _("Collection: all books…"),
        callback = function()
            UIManager:close(dialog)
            Library.chooseCollection(widget, plugin)
        end,
    }})
    local search_row = {{
        text = Library.session.search and T(_("Search: “%1”…"), Library.session.search) or _("Search…"),
        callback = function()
            UIManager:close(dialog)
            Library.askSearch(widget)
        end,
    }}
    if Library.session.search then
        table.insert(search_row, {
            text = _("Clear search"),
            callback = function()
                UIManager:close(dialog)
                Library.session.search = nil
                Library.session.grid_page, Library.session.list_page = 1, 1
                widget.page = 1
                widget:reload()
            end,
        })
    end
    table.insert(buttons, search_row)
    if widget.setSelecting then
        table.insert(buttons, {{
            text = _("Select books…"),
            callback = function()
                UIManager:close(dialog)
                widget:setSelecting(true)
            end,
        }})
    end
    table.insert(buttons, {})
    for __, s in ipairs(SORTS) do
        table.insert(buttons, {{
            text = (s.id == current_sort and "✓ " or "") .. _("Sort by:") .. " " .. s.text,
            align = "left",
            callback = function()
                UIManager:close(dialog)
                Config.set("library_sort", s.id)
                -- a new order starts at the first page
                Library.session.grid_page, Library.session.list_page = 1, 1
                widget.page = 1
                widget:reload()
            end,
        }})
    end
    table.insert(buttons, {})
    if widget.prepareAll then
        table.insert(buttons, {{
            text = _("Prepare all covers now"),
            align = "left",
            callback = function()
                UIManager:close(dialog)
                widget:prepareAll()
            end,
        }})
    end
    table.insert(buttons, {{
        text = _("Refresh (re-read all books)"),
        align = "left",
        callback = function()
            UIManager:close(dialog)
            Cache.clear()
            widget:reload()
        end,
    }})
    table.insert(buttons, {{
        text = _("Browse all files (KOReader)"),
        align = "left",
        callback = function()
            UIManager:close(dialog)
            UIManager:close(widget)
            plugin:showFileBrowser()
        end,
    }})
    dialog = ButtonDialog:new{
        title = _("Library options"),
        title_align = "center",
        buttons = buttons,
    }
    UIManager:show(dialog)
end

-- List view -------------------------------------------------------------------

Library.List = Menu:extend{
    name = "kindleui_library",
    covers_fullscreen = true,
    is_borderless = true,
    is_popout = false,
    is_enable_shortcut = false,
    title_bar_fm_style = true,
    title_bar_left_icon = "appbar.menu",
    items_per_page = 10,
    plugin = nil,
}

function Library.List:init()
    self.t_open = Perf.start()
    self.title = _("My Library")
    self.width = Screen:getWidth()
    self.height = Screen:getHeight()
    self.item_table = self:buildItems()
    Menu.init(self)
    if Library.session.list_page > 1 then
        self:onGotoPage(math.min(Library.session.list_page, self.page_num or 1))
    end
end

function Library.List:buildItems(keep_books)
    local items = {}
    if not keep_books or not self.books then
        self.books, self.total_books = Library.loadBooks(self.plugin)
        if self.selection then self.selection:keepOnly(self.books) end
    end
    local books, total = self.books, self.total_books
    self.subtitle = self.selecting and (self.selection:label() .. " · " .. _("☰ for actions"))
        or Library.subtitle(#books, total)
    for __, b in ipairs(books) do
        local mark = self.selecting and (self.selection:has(b.path) and "☑ " or "☐ ") or ""
        table.insert(items, {
            text = mark .. (b.authors and (b.title .. " — " .. b.authors) or b.title),
            mandatory = Library.progressText(b),
            file = b.path,
            book_title = b.title,
        })
    end
    if #items == 0 then
        table.insert(items, {
            text = (Library.emptyText(total):gsub("\n", " ")),
            select_enabled = false,
        })
    end
    return items
end

function Library.List:paintTo(bb, x, y)
    Menu.paintTo(self, bb, x, y)
    if self.t_open then
        Perf.log("library open (list, to first paint)", self.t_open)
        self.t_open = nil
    end
end

function Library.List:reload()
    local items = self:buildItems()
    self:switchItemTable(nil, items, nil, nil, self.subtitle)
end

-- Selection mode (same actions as the grid, see ui/selection.lua).
function Library.List:setSelecting(on, first_path)
    self.selecting = on and true or nil
    self.selection = on and Selection.new() or nil
    if on and first_path then self.selection:toggle(first_path) end
    self:refreshSelection()
end

function Library.List:refreshSelection()
    local items = self:buildItems(true)
    self:switchItemTable(nil, items, -1, nil, self.subtitle) -- -1: stay on this page
end

function Library.List:pageBooks()
    local out = {}
    local per_page = self.perpage or self.items_per_page
    local first = ((self.page or 1) - 1) * per_page + 1
    for i = first, math.min(first + per_page - 1, #self.books) do
        table.insert(out, self.books[i])
    end
    return out
end

function Library.List:onMenuChoice(item)
    if not item.file then return true end
    if self.selecting then
        self.selection:toggle(item.file)
        self:refreshSelection()
        return true
    end
    UIManager:close(self)
    self.plugin:openBook(item.file)
    return true
end

function Library.List:onClose()
    if self.selecting then -- ✕ / Back first leaves selection mode
        self:setSelecting(false)
        return true
    end
    return Menu.onClose(self)
end

-- Hold a book: the book menu (status, reset, delete, details).
function Library.List:onMenuHold(item)
    if not item.file then return true end
    if self.selecting then return self:onMenuChoice(item) end
    require("kindleui/ui/bookmenu").show{
        plugin = self.plugin,
        path = item.file,
        title = item.book_title,
        on_change = function()
            if UIManager:isWidgetShown(self) then self:reload() end
        end,
        on_select = function() self:setSelecting(true, item.file) end,
    }
    return true
end

function Library.List:onLeftButtonTap()
    if self.selecting then
        Selection.showActions(self, self.plugin)
    else
        Library.showOptions(self, self.plugin)
    end
end

function Library.List:onCloseWidget()
    Library.session.list_page = self.page or 1
    Menu.onCloseWidget(self)
    if self.plugin then self.plugin:onChildClosed() end
end

return Library
