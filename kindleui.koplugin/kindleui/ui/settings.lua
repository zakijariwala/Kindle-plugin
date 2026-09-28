--[[--
Simplified Settings.

    Settings
      Reading       – a few common reading options (KOReader's own items)
      Library       – sort order, Home screen at startup, refresh
      Device        – frontlight, sleep screen, rotation (KOReader's own items)
      Connectivity  – the Kindle's Wi-Fi settings (airplane mode, networks,
                      saved networks, details: ui/connectivity.lua), Send Book,
                      KOReader's Network menu
      Advanced      – Open KOReader Settings / all menus, plugin management,
                      undo the last plugin install, exit to the Kindle home
      About

Wherever possible the entries *are* KOReader's menu entries, taken from the
host's `ui.menu.menu_items` (the same tables KOReader's menu shows), so
nothing is re-implemented and behaviour stays identical.

@module kindleui.ui.settings
]]

local Books = require("kindleui/util/books")
local Config = require("kindleui/config")
local Device = require("device")
local InfoMessage = require("ui/widget/infomessage")
local Library = require("kindleui/ui/library")
local UIManager = require("ui/uimanager")
local _ = require("gettext")
local T = require("ffi/util").template

local Settings = {}

--- Builds the Settings item table for KOReader's TouchMenu.
-- @param plugin the KindleUI plugin instance
function Settings.build(plugin)
    local function ko(key)
        return plugin:getKOMenuItem(key)
    end
    local function addIf(t, item)
        if item then table.insert(t, item) end
    end

    -- Reading ---------------------------------------------------------------
    local reading = {}
    table.insert(reading, {
        text = _("Font, size and margins"),
        help_text = _("Opens the reading settings of the current book (the same menu as tapping the bottom of the page while reading)."),
        callback = function(touchmenu_instance)
            if touchmenu_instance then touchmenu_instance:closeMenu() end
            plugin:showReadingConfig()
        end,
    })
    addIf(reading, ko("night_mode"))
    addIf(reading, ko("document_end_action"))

    -- Library ---------------------------------------------------------------
    local sort_items = {}
    for __, s in ipairs(Library.SORTS) do
        table.insert(sort_items, {
            text = s.text,
            radio = true,
            checked_func = function() return Config.get("library_sort") == s.id end,
            callback = function() Config.set("library_sort", s.id) end,
        })
    end
    local view_items = {}
    for __, v in ipairs(Library.VIEWS) do
        table.insert(view_items, {
            text = v.text,
            radio = true,
            checked_func = function() return Config.get("library_view") == v.id end,
            callback = function() Config.set("library_view", v.id) end,
        })
    end
    local size_names = { small = _("Small"), medium = _("Medium"), large = _("Large") }
    local size_items = {}
    for __, t in ipairs(require("kindleui/ui/common").TEXT_SIZES) do
        table.insert(size_items, {
            text = size_names[t.id],
            radio = true,
            checked_func = function() return Config.get("text_size") == t.id end,
            callback = function()
                Config.set("text_size", t.id)
                plugin:onLibraryChanged() -- Home is rebuilt when Settings closes
            end,
        })
    end
    local library = {
        {
            text = _("Text size"),
            help_text = _("Text size of the Home screen, My Library and Send Book. Books keep their own font settings."),
            sub_item_table = size_items,
        },
        {
            text = _("View"),
            sub_item_table = view_items,
        },
        {
            text = _("Sort books by"),
            sub_item_table = sort_items,
        },
        {
            text = _("Show time left on Home"),
            help_text = _("Estimated reading time left in the current book, from the Statistics plugin (average time per page so far). Shown only when Statistics is enabled and has data for the book."),
            checked_func = function() return Config.get("home_time_left") ~= false end,
            callback = function()
                Config.set("home_time_left", Config.get("home_time_left") == false)
                plugin:onLibraryChanged()
            end,
        },
        {
            text = _("Show other books being read on Home"),
            help_text = _("Up to two more books from your reading history, under Continue Reading. Finished books are left out."),
            checked_func = function() return Config.get("home_more_reading") ~= false end,
            callback = function()
                Config.set("home_more_reading", Config.get("home_more_reading") == false)
                plugin:onLibraryChanged()
            end,
        },
        {
            text = _("Show \"Recently added\" on Home"),
            checked_func = function() return Config.get("home_recent") ~= false end,
            callback = function()
                Config.set("home_recent", Config.get("home_recent") == false)
                plugin:onLibraryChanged()
            end,
        },
        {
            text = _("Show Home screen at startup"),
            help_text = _("When disabled, KOReader starts in its regular file browser. The Home screen stays available from the KOReader main menu."),
            checked_func = function() return Config.get("show_on_start") end,
            callback = function() Config.set("show_on_start", not Config.get("show_on_start")) end,
        },
        {
            text = _("Refresh library now"),
            keep_menu_open = true,
            callback = function()
                Books.refreshLibrary()
                UIManager:show(InfoMessage:new{ text = _("Library refreshed."), timeout = 2 })
            end,
        },
    }

    -- Device ------------------------------------------------------------------
    local device = {}
    addIf(device, ko("frontlight"))
    addIf(device, ko("screensaver"))
    addIf(device, ko("screen_rotation"))

    -- Connectivity ----------------------------------------------------------
    local connectivity = require("kindleui/ui/connectivity").items()
    table.insert(connectivity, {
        text = _("Send Book"),
        callback = function(touchmenu_instance)
            if touchmenu_instance then touchmenu_instance:closeMenu() end
            plugin:showTransfer()
        end,
    })
    local ko_network = ko("network")
    if ko_network then
        -- KOReader's own Network menu, under a clearer name
        local more = {}
        for k, v in pairs(ko_network) do more[k] = v end
        more.text, more.text_func = _("More network settings (KOReader)"), nil
        table.insert(connectivity, more)
    end

    -- Advanced ----------------------------------------------------------------
    local advanced = {
        {
            text = _("Open KOReader Settings"),
            help_text = _("Opens KOReader's complete menu, starting on its Settings tab. Every KOReader option is available there."),
            callback = function(touchmenu_instance)
                if touchmenu_instance then touchmenu_instance:closeMenu() end
                plugin:showKOReaderMenu("appbar.settings")
            end,
        },
        {
            text = _("Open KOReader tools menu"),
            callback = function(touchmenu_instance)
                if touchmenu_instance then touchmenu_instance:closeMenu() end
                plugin:showKOReaderMenu("appbar.tools")
            end,
        },
        {
            text = _("Open KOReader file browser"),
            help_text = _("Closes the Home screen and shows KOReader's regular file browser."),
            callback = function(touchmenu_instance)
                if touchmenu_instance then touchmenu_instance:closeMenu() end
                plugin:showFileBrowser()
            end,
        },
    }
    addIf(advanced, ko("plugin_management"))
    table.insert(advanced, {
        text_func = function()
            local record = require("kindleui/util/plugininstaller").lastInstall()
            return record and T(_("Undo last plugin install (%1)"), record.name) or _("Undo last plugin install")
        end,
        help_text = _("Restores the version the last install replaced, or removes the plugin if it was new. KOReader then restarts."),
        enabled_func = function() return require("kindleui/util/plugininstaller").canUndo() end,
        callback = function(touchmenu_instance)
            if touchmenu_instance then touchmenu_instance:closeMenu() end
            require("kindleui/ui/plugininstall").confirmUndo()
        end,
    })
    table.insert(advanced, {
        text = plugin.exitLabel(),
        callback = function(touchmenu_instance)
            if touchmenu_instance then touchmenu_instance:closeMenu() end
            plugin:confirmExit()
        end,
    })

    -- About -------------------------------------------------------------------
    local about = {
        text = _("About"),
        sub_item_table = {
            {
                text = _("Version"),
                keep_menu_open = true,
                callback = function()
                    local ok, Version = pcall(require, "version")
                    local ko_version = ok and Version:getCurrentRevision() or _("unknown")
                    local model = Device.model or _("unknown")
                    local build = require("kindleui/util/updater").installedBuild(plugin.path or ".")
                    UIManager:show(InfoMessage:new{
                        text = T(_("Kindle-style Home\nVersion %1 (build %2)\n\nKOReader %3\nDevice: %4\n\nKOReader remains the reading engine; all its features stay available under Settings → Advanced."),
                            Config.VERSION, build and build:sub(1, 7) or _("unknown"), ko_version, model),
                    })
                end,
            },
            {
                text = _("Check for updates"),
                help_text = _("Downloads the latest version of this plugin from GitHub (needs internet). Nothing is checked automatically."),
                callback = function(touchmenu_instance)
                    if touchmenu_instance then touchmenu_instance:closeMenu() end
                    plugin:checkForUpdates()
                end,
            },
        },
    }

    local root = {
        { text = _("Reading"), sub_item_table = reading },
        { text = _("Library"), sub_item_table = library },
    }
    if #device > 0 then
        table.insert(root, { text = _("Device"), sub_item_table = device })
    end
    table.insert(root, { text = _("Connectivity"), sub_item_table = connectivity })
    table.insert(root, { text = _("Advanced"), sub_item_table = advanced })
    table.insert(root, about)
    return root
end

return Settings
