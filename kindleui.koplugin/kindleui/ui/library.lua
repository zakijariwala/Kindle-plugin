--[[--
"My Library": a simplified, flat list of the books below KOReader's home
folder, built on KOReader's stock Menu widget.

It is a view, not an index: the folder is scanned when the screen opens (or
on Refresh), metadata comes from KOReader's sidecar files, and nothing is
written anywhere except the chosen sort order.

@module kindleui.ui.library
]]

local Books = require("kindleui/util/books")
local ButtonDialog = require("ui/widget/buttondialog")
local Config = require("kindleui/config")
local Device = require("device")
local Menu = require("ui/widget/menu")
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
local Library = Menu:extend{
    name = "kindleui_library",
    covers_fullscreen = true,
    is_borderless = true,
    is_popout = false,
    title_bar_fm_style = true,
    title_bar_left_icon = "appbar.menu",
    items_per_page = 8,
    items_max_lines = 2,
    plugin = nil,
}
Library.SORTS = SORTS

function Library:init()
    self.title = _("My Library")
    self.width = Screen:getWidth()
    self.height = Screen:getHeight()
    self.item_table = self:buildItems()
    Menu.init(self)
end

local function lower(s) return s and s:lower() or "" end

function Library:buildItems()
    local ui = self.plugin and self.plugin.ui
    local books = Books.scan(Books.homeDir(), Config.get("library_max_depth"), Config.get("library_max_books"))
    local history = Books.historyTimes()
    for __, b in ipairs(books) do
        local info = Books.getInfo(ui, b.path)
        b.title, b.authors, b.percent, b.status = info.title, info.authors, info.percent, info.status
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

    local items = {}
    for __, b in ipairs(books) do
        local progress
        if b.status == "complete" then
            progress = _("Finished")
        elseif b.percent then
            progress = string.format("%d%%", math.floor(b.percent * 100 + 0.5))
        else
            progress = _("New")
        end
        table.insert(items, {
            text = b.authors and (b.title .. "\n" .. b.authors) or b.title,
            mandatory = progress,
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

function Library:reload()
    self:switchItemTable(nil, self:buildItems())
end

function Library:onMenuChoice(item)
    if item.file then
        UIManager:close(self)
        self.plugin:openBook(item.file)
    end
    return true
end

function Library:onLeftButtonTap()
    local dialog
    local current = Config.get("library_sort")
    local buttons = {}
    for __, s in ipairs(SORTS) do
        table.insert(buttons, {{
            text = (s.id == current and "✓ " or "") .. _("Sort by:") .. " " .. s.text,
            align = "left",
            callback = function()
                UIManager:close(dialog)
                Config.set("library_sort", s.id)
                self:reload()
            end,
        }})
    end
    table.insert(buttons, {})
    table.insert(buttons, {{
        text = _("Refresh"),
        align = "left",
        callback = function()
            UIManager:close(dialog)
            self:reload()
        end,
    }})
    table.insert(buttons, {{
        text = _("Browse all files (KOReader)"),
        align = "left",
        callback = function()
            UIManager:close(dialog)
            UIManager:close(self)
            self.plugin:showFileBrowser()
        end,
    }})
    dialog = ButtonDialog:new{
        title = _("Library options"),
        title_align = "center",
        buttons = buttons,
    }
    UIManager:show(dialog)
end

function Library:onCloseWidget()
    Menu.onCloseWidget(self)
    if self.plugin then self.plugin:onChildClosed() end
end

return Library
