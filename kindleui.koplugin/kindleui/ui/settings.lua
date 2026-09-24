--[[--
Simplified Settings.

    Settings
      Reading       – a few common reading options (KOReader's own items)
      Library       – sort order, Home screen at startup, refresh
      Device        – frontlight, sleep screen, rotation (KOReader's own items)
      Connectivity  – Wi-Fi (KOReader's own), transfer method
      Advanced      – Open KOReader Settings / all menus, plugin management
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
local Providers = require("kindleui/transfer/provider")
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
    local library = {
        {
            text = _("Sort books by"),
            sub_item_table = sort_items,
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
    -- Cover browser's display mode (list / mosaic), if that plugin is enabled.
    addIf(library, ko("filemanager_display_mode"))

    -- Device ------------------------------------------------------------------
    local device = {}
    addIf(device, ko("frontlight"))
    addIf(device, ko("screensaver"))
    addIf(device, ko("screen_rotation"))

    -- Connectivity ----------------------------------------------------------
    local method_items = {}
    for __, p in ipairs(Providers.list()) do
        table.insert(method_items, {
            text = p.name,
            radio = true,
            enabled_func = function() return p.available end,
            checked_func = function() return Config.get("transfer_method") == p.id end,
            callback = function() Config.set("transfer_method", p.id) end,
        })
    end
    local connectivity = {
        {
            text = _("Send Book"),
            callback = function(touchmenu_instance)
                if touchmenu_instance then touchmenu_instance:closeMenu() end
                plugin:showTransfer()
            end,
        },
        {
            text = _("Transfer method"),
            sub_item_table = method_items,
        },
    }
    addIf(connectivity, ko("network"))

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

    -- About -------------------------------------------------------------------
    local about = {
        text = _("About"),
        keep_menu_open = true,
        callback = function()
            local ok, Version = pcall(require, "version")
            local ko_version = ok and Version:getCurrentRevision() or _("unknown")
            local model = Device.model or _("unknown")
            UIManager:show(InfoMessage:new{
                text = T(_("Kindle-style Home for KOReader\nVersion %1\n\nKOReader %2\nDevice: %3\n\nKOReader remains the reading engine; all its features stay available under Settings → Advanced."),
                    Config.VERSION, ko_version, model),
            })
        end,
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
