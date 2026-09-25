--[[--
Selection mode of My Library (grid and list): tick books, then act on all of
them at once from the ☰ button.

    Select all on this page · Select all · Deselect all
    Reading · On hold · Finished        KOReader's own batch status buttons
    Reset · Collections…                KOReader's own batch buttons
    Delete…                             one confirmation (count and size)
    Done                                leaves selection mode

The view (`widget`) provides: `books` (all shown), `pageBooks()`,
`reload()`, `refreshSelection()` and `setSelecting(bool)`.

@module kindleui.ui.selection
]]

local ButtonDialog = require("ui/widget/buttondialog")
local Cache = require("kindleui/util/librarycache")
local ConfirmBox = require("ui/widget/confirmbox")
local Format = require("kindleui/util/format")
local UIManager = require("ui/uimanager")
local filemanagerutil = require("apps/filemanager/filemanagerutil")
local logger = require("logger")
local _ = require("gettext")
local N_ = _.ngettext
local T = require("ffi/util").template

local Selection = {}
Selection.__index = Selection

function Selection.new()
    return setmetatable({ set = {}, count = 0 }, Selection)
end

function Selection:has(path) return self.set[path] == true end

function Selection:toggle(path)
    if self.set[path] then
        self.set[path] = nil
        self.count = self.count - 1
    else
        self.set[path] = true
        self.count = self.count + 1
    end
end

function Selection:add(books)
    for __, b in ipairs(books) do
        if not self.set[b.path] then
            self.set[b.path] = true
            self.count = self.count + 1
        end
    end
end

function Selection:clear()
    self.set, self.count = {}, 0
end

--- Keeps only paths that are still shown (after a reload).
function Selection:keepOnly(books)
    local still = {}
    local n = 0
    for __, b in ipairs(books) do
        if self.set[b.path] then still[b.path] = true n = n + 1 end
    end
    self.set, self.count = still, n
end

--- Total size in bytes of the selected books.
function Selection:bytes(books)
    local total = 0
    for __, b in ipairs(books) do
        if self.set[b.path] then total = total + (b.size or 0) end
    end
    return total
end

--- "3 selected" (for the title bar).
function Selection:label()
    return T(N_("1 selected", "%1 selected", self.count), self.count)
end

-- Deletes the selected books through KOReader (sidecar, history and
-- collections go with each book). Returns the number that failed.
local function deleteAll(paths)
    local FileManager = require("apps/filemanager/filemanager")
    local fm = FileManager.instance
    if not fm then
        logger.warn("KindleUI: no file manager to delete books with")
        return #paths
    end
    local failed = 0
    for __, path in ipairs(paths) do
        -- deleteFile shows KOReader's own message when a file cannot be deleted.
        if fm:deleteFile(path, true) then
            Cache.forget(path)
        else
            failed = failed + 1
        end
    end
    return failed
end

--- The ☰ dialog while selecting.
function Selection.showActions(widget, plugin)
    local sel = widget.selection
    local dialog
    local function close() UIManager:close(dialog) end
    local function changed()
        for path in pairs(sel.set) do Cache.invalidate(path) end
        if plugin then plugin:onLibraryChanged() end
        widget:reload()
    end
    local none = sel.count == 0
    local page_books = widget:pageBooks()
    local buttons = {
        {
            {
                text = _("Select all on this page"),
                enabled = #page_books > 0,
                callback = function() close() sel:add(page_books) widget:refreshSelection() end,
            },
            {
                text = T(_("Select all (%1)"), #widget.books),
                enabled = #widget.books > 0,
                callback = function() close() sel:add(widget.books) widget:refreshSelection() end,
            },
        },
        {{
            text = _("Deselect all"),
            enabled = not none,
            callback = function() close() sel:clear() widget:refreshSelection() end,
        }},
        filemanagerutil.genMultipleStatusButtonsRow(sel.set, function() close() changed() end, none),
    }
    local reset = filemanagerutil.genMultipleResetSettingsButton(sel.set, function() changed() end, none)
    local reset_cb = reset.callback
    reset.callback = function() close() reset_cb() end
    local row = { reset }
    local fmc = plugin and plugin.ui and plugin.ui.collections
    if fmc and fmc.genAddToCollectionButton then
        local ok, btn = pcall(fmc.genAddToCollectionButton, fmc, sel.set, close, function()
            pcall(function() require("readcollection"):write({ [1] = true }) end)
            changed()
        end, none)
        if ok and btn then table.insert(row, btn) end
    end
    table.insert(buttons, row)
    table.insert(buttons, {{
        text = _("Delete…"),
        enabled = not none,
        callback = function()
            close()
            local paths = {}
            for path in pairs(sel.set) do table.insert(paths, path) end
            table.sort(paths)
            UIManager:show(ConfirmBox:new{
                text = T(N_("Delete 1 book permanently?", "Delete %1 books permanently?", #paths), #paths)
                    .. "\n\n" .. T(_("Total size: %1"), Format.size(sel:bytes(widget.books)))
                    .. "\n" .. _("Reading progress, highlights and notes of these books are deleted too."),
                ok_text = _("Delete"),
                ok_callback = function()
                    deleteAll(paths)
                    sel:clear()
                    if plugin then plugin:onLibraryChanged() end
                    widget:reload()
                end,
            })
        end,
    }})
    table.insert(buttons, {})
    table.insert(buttons, {{
        text = _("Done (leave selection)"),
        callback = function() close() widget:setSelecting(false) end,
    }})
    dialog = ButtonDialog:new{
        title = sel:label(),
        title_align = "center",
        buttons = buttons,
    }
    UIManager:show(dialog)
    return dialog
end

return Selection
