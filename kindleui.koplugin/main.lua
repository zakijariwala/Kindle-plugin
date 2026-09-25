--[[--
Kindle-style Home: a thin, Kindle-like shell on top of KOReader.

KOReader keeps doing everything it already does (reading, rendering,
library data, settings, plugins). This plugin only adds a simple Home screen
and a few full-screen views that *delegate* to KOReader's existing APIs.

Module layout (namespaced under `kindleui/` so our requires can never collide
with KOReader's own `ui/...` or `util` modules):

    kindleui/config.lua            preferences (one G_reader_settings key)
    kindleui/ui/*.lua              Home, Library, Installed Plugins, Settings, Send Book
    kindleui/transfer/*.lua        provider registry, session, HTTP server, upload, QR
    kindleui/util/*.lua            books (KOReader adapter), network, filesystem, security

@module koplugin.kindleui
]]

local Dispatcher = require("dispatcher")
local InfoMessage = require("ui/widget/infomessage")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local logger = require("logger")
local _ = require("gettext")

local Books = require("kindleui/util/books")
local Common = require("kindleui/ui/common")
local Config = require("kindleui/config")

-- State shared by the successive plugin instances (KOReader creates a new
-- instance for every FileManager / ReaderUI).
local shell = {
    home = nil,            -- the Home widget currently shown, if any
    pending_home = false,  -- show Home when the file browser comes up next
    suppress_home = false, -- user explicitly asked for the file browser
    home_dirty = false,    -- library changed while Home was covered
    cleaned = false,       -- stale upload temp files removed (once per run)
}

local KindleUI = WidgetContainer:extend{
    name = "kindleui",
    is_doc_only = false,
}

function KindleUI:onDispatcherRegisterActions()
    Dispatcher:registerAction("kindleui_show_home", {
        category = "none",
        event = "KindleUIShowHome",
        title = _("Kindle-style Home"),
        general = true,
    })
    Dispatcher:registerAction("kindleui_send_book", {
        category = "none",
        event = "KindleUISendBook",
        title = _("Send Book (local Wi-Fi)"),
        general = true,
    })
end

function KindleUI:init()
    self:onDispatcherRegisterActions()
    self.ui.menu:registerToMainMenu(self)

    if not shell.cleaned then
        -- A crash or power loss mid-upload leaves a hidden .part file behind;
        -- no transfer can be running this early, so they are all stale.
        shell.cleaned = true
        UIManager:nextTick(function()
            local FS = require("kindleui/util/filesystem")
            local removed = 0
            local seen = {}
            for __, dir in ipairs({ Books.destinationDir(), Books.homeDir() }) do
                if not seen[dir] then
                    seen[dir] = true
                    removed = removed + FS.removeStaleUploads(dir)
                end
            end
            if removed > 0 then
                logger.info("KindleUI: removed", removed, "stale upload temp file(s)")
            end
        end)
    end

    if self:isFileManager() then
        local want = shell.pending_home or Config.get("show_on_start")
        if shell.suppress_home then
            want = false
        end
        shell.pending_home = false
        shell.suppress_home = false
        if want then
            -- After the file browser itself has been shown.
            UIManager:nextTick(function() self:showHome() end)
        end
    end
end

-- ReaderUI instances always carry their document (set before plugins are
-- instantiated); FileManager instances never do.
function KindleUI:isFileManager()
    return self.ui ~= nil and self.ui.document == nil
end

function KindleUI:addToMainMenu(menu_items)
    menu_items.kindleui = {
        text = _("Kindle-style Home"),
        sorting_hint = "main",
        callback = function(touchmenu_instance)
            if touchmenu_instance then touchmenu_instance:closeMenu() end
            self:showHome()
        end,
    }
end

-- Navigation ----------------------------------------------------------------

function KindleUI:showHome()
    if not self:isFileManager() then
        -- From the reader: go back to the file browser, where Home is shown.
        if self.ui and self.ui.document and self.ui.onHome then
            shell.pending_home = true
            self.ui:onHome()
        end
        return
    end
    if shell.home and UIManager:isWidgetShown(shell.home) then
        shell.home:refresh()
        return
    end
    local Home = require("kindleui/ui/home")
    shell.home = Home:new{ plugin = self }
    shell.home_dirty = false
    UIManager:show(shell.home)
end

function KindleUI:onKindleUIShowHome()
    self:showHome()
    return true
end

function KindleUI:onKindleUISendBook()
    self:showTransfer()
    return true
end

function KindleUI:onHomeClosed(home)
    if shell.home == home then
        shell.home = nil
    end
end

--- Called when a full-screen child (Library, Plugins, Send Book) closes.
function KindleUI:onChildClosed()
    if shell.home_dirty and shell.home and UIManager:isWidgetShown(shell.home) then
        shell.home_dirty = false
        shell.home:refresh()
    end
end

function KindleUI:onLibraryChanged()
    shell.home_dirty = true
end

function KindleUI:closeHome()
    if shell.home then
        UIManager:close(shell.home)
        shell.home = nil
    end
end

function KindleUI:showLibrary()
    require("kindleui/ui/library").show(self)
end

function KindleUI:showPlugins()
    local Plugins = require("kindleui/ui/plugins")
    UIManager:show(Plugins:new{ plugin = self })
end

function KindleUI:showSettings()
    local Settings = require("kindleui/ui/settings")
    Common.showTouchMenu(Settings.build(self), "appbar.settings")
end

function KindleUI:showTransfer()
    local TransferScreen = require("kindleui/ui/transfer")
    UIManager:show(TransferScreen:new{ plugin = self })
end

--- Opens a book through KOReader's normal reader.
function KindleUI:openBook(file, after_open_callback)
    self:closeHome()
    Books.open(file, after_open_callback)
end

--- Reveals KOReader's own file browser (the shell steps aside).
function KindleUI:showFileBrowser()
    if self:isFileManager() then
        self:closeHome()
    elseif self.ui and self.ui.onHome then
        shell.suppress_home = true
        self.ui:onHome()
    end
end

--- Opens the reader's bottom configuration menu (font, size, margins...).
function KindleUI:showReadingConfig()
    local function showConfig(reader)
        if reader and reader.config then
            UIManager:nextTick(function() reader.config:onShowConfigMenu() end)
        end
    end
    if self.ui and self.ui.document then
        showConfig(self.ui)
        return
    end
    local last = Books.lastFile()
    if not last then
        UIManager:show(InfoMessage:new{
            text = _("Open a book first. Reading settings (font, size, margins) are changed while a book is open."),
        })
        return
    end
    self:openBook(last, showConfig)
end

--- Returns one of KOReader's own main-menu entries by id (e.g. "frontlight"),
-- as found in the host's sorted menu, or nil if it does not exist here.
function KindleUI:getKOMenuItem(id)
    local menu = self.ui and self.ui.menu
    if not menu then return nil end
    if menu.tab_item_table == nil and menu.setUpdateItemTable then
        local ok, err = pcall(menu.setUpdateItemTable, menu)
        if not ok then
            logger.warn("KindleUI: could not build KOReader menu:", err)
            return nil
        end
    end
    if not menu.tab_item_table then return nil end
    local MenuSorter = require("ui/menusorter")
    local ok, item = pcall(MenuSorter.findById, MenuSorter, menu.tab_item_table, id)
    if ok and type(item) == "table" and (item.text or item.text_func) then
        return item
    end
    return nil
end

--- Opens KOReader's full main menu on the tab with the given icon.
function KindleUI:showKOReaderMenu(icon)
    local menu = self.ui and self.ui.menu
    if not menu then return end
    if menu.tab_item_table == nil then
        menu:setUpdateItemTable()
    end
    local index
    for i, tab in ipairs(menu.tab_item_table or {}) do
        if tab.icon == icon then index = i break end
    end
    menu:onShowMenu(index)
end

--- Settings → About → Check for updates. Runs only when tapped.
function KindleUI:checkForUpdates()
    local ConfirmBox = require("ui/widget/confirmbox")
    local NetworkMgr = require("ui/network/manager")
    local Updater = require("kindleui/util/updater")
    local T = require("ffi/util").template
    local plugin_dir = self.path
    if not plugin_dir then
        UIManager:show(InfoMessage:new{ text = _("Cannot find the plugin folder.") })
        return
    end
    -- Shows a message, lets it paint, then runs the (blocking) network step.
    local function withMessage(text, fn)
        local msg = InfoMessage:new{ text = text }
        UIManager:show(msg)
        UIManager:forceRePaint()
        local ok, a, b = pcall(fn)
        UIManager:close(msg)
        if not ok then return nil, tostring(a) end
        return a, b
    end
    NetworkMgr:runWhenOnline(function()
        local latest, err = withMessage(_("Checking for updates…"), Updater.fetchLatest)
        if not latest then
            logger.warn("KindleUI updater: check failed:", err)
            UIManager:show(InfoMessage:new{ text = T(_("Could not check for updates.\n\n%1"), tostring(err)) })
            return
        end
        local installed = Updater.installedBuild(plugin_dir)
        if installed and installed == latest.sha then
            UIManager:show(InfoMessage:new{
                text = T(_("You have the latest version (build %1)."), Updater.short(installed)),
            })
            return
        end
        UIManager:show(ConfirmBox:new{
            text = T(_("An update is available.\n\nInstalled: %1\nAvailable: %2 (%3)\n%4\n\nInstall it now? KOReader will need to restart."),
                installed and Updater.short(installed) or _("unknown"),
                Updater.short(latest.sha), latest.date or "?", latest.message or ""),
            ok_text = _("Update"),
            ok_callback = function()
                local ok, ierr = withMessage(_("Downloading and installing the update…"), function()
                    return Updater.install(plugin_dir, latest.sha)
                end)
                if not ok then
                    logger.warn("KindleUI updater: install failed:", ierr)
                    UIManager:show(InfoMessage:new{
                        text = T(_("The update could not be installed. The current version is unchanged.\n\n%1"), tostring(ierr)),
                    })
                    return
                end
                UIManager:askForRestart(_("The update is installed. Restart KOReader now to use it?"))
            end,
        })
    end)
end

function KindleUI:showPluginManagement()
    local item = self:getKOMenuItem("plugin_management")
    if item and item.sub_item_table then
        Common.showTouchMenu(item.sub_item_table, "appbar.tools")
    else
        self:showKOReaderMenu("appbar.tools")
    end
end

return KindleUI
