--[[--
The menu shown when a book is held (Library cover or list row, Home):

    Reading · On hold · Finished        KOReader's own status buttons
    Reset (mark as unread)…             KOReader's own Reset (it confirms)
    Collections…                        KOReader's own collection chooser (add/remove)
    Remove from Continue Reading        only if the book is in the history
    Select…                             selection mode, this book ticked (Library)
    Book details
    Delete book…                        KOReader's own delete (it confirms and
                                        also removes the sidecar, history and
                                        collection entries)

Every action goes through KOReader's functions, so the result is the same as
doing it from KOReader's file browser.

@module kindleui.ui.bookmenu
]]

local Books = require("kindleui/util/books")
local ButtonDialog = require("ui/widget/buttondialog")
local Cache = require("kindleui/util/librarycache")
local UIManager = require("ui/uimanager")
local filemanagerutil = require("apps/filemanager/filemanagerutil")
local logger = require("logger")
local _ = require("gettext")

local BookMenu = {}

--- Removes a book from KOReader's reading history. If it was the book in
-- Continue Reading, the next one in the history takes its place.
function BookMenu.removeFromHistory(path)
    local ReadHistory = require("readhistory")
    ReadHistory:removeItemByPath(path)
    if G_reader_settings:readSetting("lastfile") == path then
        local next_file = Books.recentlyRead(1)[1]
        if next_file then
            G_reader_settings:saveSetting("lastfile", next_file)
        else
            G_reader_settings:delSetting("lastfile")
        end
    end
end

--- True if the book is in KOReader's reading history.
function BookMenu.inHistory(path)
    local ok, ReadHistory = pcall(require, "readhistory")
    return ok and ReadHistory.getIndexByFile and ReadHistory:getIndexByFile(path) ~= nil or false
end

--- Shows the menu.
-- @param o { plugin, path, title, on_change = function() (redraw the caller) }
function BookMenu.show(o)
    local dialog
    local function changed()
        Cache.invalidate(o.path)
        if o.plugin then o.plugin:onLibraryChanged() end
        if o.on_change then o.on_change() end
    end
    local function close() UIManager:close(dialog) end

    local status_row = filemanagerutil.genStatusButtonsRow(o.path, function()
        close()
        changed()
    end)
    local reset = filemanagerutil.genResetSettingsButton(o.path, function()
        changed()
    end)
    local reset_callback = reset.callback
    reset.text = _("Reset (mark as unread)…")
    reset.callback = function()
        close()
        reset_callback() -- KOReader's confirm dialog
    end

    local buttons = { status_row, { reset } }
    local fmc = o.plugin and o.plugin.ui and o.plugin.ui.collections
    if fmc and fmc.genAddToCollectionButton then
        local function saved()
            -- KOReader writes collection.lua only when its file browser
            -- closes; save now so a crash or power loss cannot lose it.
            pcall(function() require("readcollection"):write({ [1] = true }) end)
            changed()
        end
        local ok, btn = pcall(fmc.genAddToCollectionButton, fmc, o.path, close, saved)
        if ok and btn then
            table.insert(buttons, { btn })
        end
    end
    if BookMenu.inHistory(o.path) then
        table.insert(buttons, {{
            text = _("Remove from Continue Reading"),
            callback = function()
                close()
                BookMenu.removeFromHistory(o.path)
                changed()
            end,
        }})
    end
    if o.on_select then
        table.insert(buttons, {{
            text = _("Select… (several books)"),
            callback = function()
                close()
                o.on_select()
            end,
        }})
    end
    table.insert(buttons, {{
        text = _("Book details"),
        callback = function()
            close()
            local ui = o.plugin and o.plugin.ui
            if ui and ui.bookinfo then ui.bookinfo:show(o.path) end
        end,
    }})
    table.insert(buttons, {{
        text = _("Delete book…"),
        callback = function()
            close()
            local FileManager = require("apps/filemanager/filemanager")
            if not FileManager.instance then
                logger.warn("KindleUI: no file manager to delete the book with")
                return
            end
            FileManager.instance:showDeleteFileDialog(o.path, function()
                Cache.forget(o.path)
                changed()
            end)
        end,
    }})
    dialog = ButtonDialog:new{
        title = o.title or filemanagerutil.splitFileNameType(o.path),
        title_align = "center",
        buttons = buttons,
    }
    UIManager:show(dialog)
    return dialog
end

return BookMenu
