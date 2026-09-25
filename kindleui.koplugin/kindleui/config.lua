--[[--
Plugin constants and persisted preferences.

Preferences live in KOReader's global settings (settings.reader.lua) under a
single key, so they are backed up/reset with the rest of KOReader's settings
and removed by Plugin management → "Disable plugin and delete settings".

@module kindleui.config
]]

local Config = {
    VERSION = "0.1.0",
    SETTINGS_KEY = "kindleui",
}

local DEFAULTS = {
    show_on_start = true,          -- present the Home screen when the file browser opens
    library_sort = "recent",       -- "recent" | "title" | "author" | "added"
    library_view = "covers",       -- "covers" | "list"
    library_filter = "all",        -- "all" | "unread" | "reading" | "finished"
    library_collection = nil,      -- name of a KOReader collection to show, nil = all books
    library_group_series = false,  -- one tile per series (2+ books) in My Library
    home_recent = true,            -- "Recently added" row on Home
    home_more_reading = true,      -- up to 2 more books being read, under Continue Reading
    text_size = "medium",          -- "small" | "medium" | "large" (Home, Library, Send Book)
    pinned_plugins = nil,          -- plugin names pinned to Home (max 4); nil = none
    library_max_books = 2000,      -- safety cap for the library scan
    library_max_depth = 6,         -- folder depth scanned below the home folder
    transfer_method = "local_http",
    transfer_port = 8080,          -- first port tried; the next 9 are fallbacks
    transfer_timeout = 15 * 60,    -- seconds before a Send Book session expires
    transfer_max_mb = 500,
    last_plugin_install = nil,     -- { name, had_previous }: what "Undo last plugin install" reverts
}
Config.DEFAULTS = DEFAULTS

local function store()
    return G_reader_settings:readSetting(Config.SETTINGS_KEY) or {}
end

function Config.get(key)
    local v = store()[key]
    if v == nil then return DEFAULTS[key] end
    return v
end

function Config.set(key, value)
    local t = store()
    t[key] = value
    G_reader_settings:saveSetting(Config.SETTINGS_KEY, t)
end

return Config
