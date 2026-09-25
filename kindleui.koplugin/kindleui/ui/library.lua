--[[--
"My Library": shared data loading + the options dialog, and the list view.

The default view is the cover grid (ui/librarygrid.lua); the list view below
is the compact alternative (Settings → Library → View). Both get their data
from `Library.loadBooks`, which scans the home folder and fills in metadata
from the plugin's own cache (util/librarycache.lua), so opening the Library
does not re-read every book's sidecar.

@module kindleui.ui.library
]]

local Books = require("kindleui/util/books")
local ButtonDialog = require("ui/widget/buttondialog")
local Cache = require("kindleui/util/librarycache")
local Config = require("kindleui/config")
local Device = require("device")
local Menu = require("ui/widget/menu")
local Perf = require("kindleui/util/perf")
local UIManager = require("ui/uimanager")
local ffiUtil = require("ffi/util")
local _ = require("gettext")
local Screen = Device.screen

local SORTS = {
    { id = "recent", text = _("Recent") },
    { id = "title", text = _("Title") },
    { id = "author", text = _("Author") },
    { id = "added", text = _("Recently added") },
}
local VIEWS = {
    { id = "covers", text = _("Covers") },
    { id = "list", text = _("List") },
}

local Library = {
    SORTS = SORTS,
    VIEWS = VIEWS,
    -- Remembered for this KOReader session only (not saved to disk).
    session = { grid_page = 1, list_page = 1 },
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
    Perf.log("library data", t0, {
        books = stats.books, scan_ms = scan_ms, meta_ms = meta_ms,
        sidecar_reads = stats.sidecar_reads, new_entries = stats.new_entries,
    })
    return books
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

function Library.List:buildItems()
    local items = {}
    for __, b in ipairs(Library.loadBooks(self.plugin)) do
        table.insert(items, {
            text = b.authors and (b.title .. " — " .. b.authors) or b.title,
            mandatory = Library.progressText(b),
            file = b.path,
        })
    end
    if #items == 0 then
        table.insert(items, {
            text = _("No books yet. Use Send Book on the Home screen to add one."),
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
    self:switchItemTable(nil, self:buildItems())
end

function Library.List:onMenuChoice(item)
    if item.file then
        UIManager:close(self)
        self.plugin:openBook(item.file)
    end
    return true
end

function Library.List:onLeftButtonTap()
    Library.showOptions(self, self.plugin)
end

function Library.List:onCloseWidget()
    Library.session.list_page = self.page or 1
    Menu.onCloseWidget(self)
    if self.plugin then self.plugin:onChildClosed() end
end

return Library
