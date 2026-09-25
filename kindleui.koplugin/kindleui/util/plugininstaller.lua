--[[--
Installs a KOReader plugin from a .zip received from the phone.

    analyze(zip)            → plugin folders found, with name/description read
                              as text (nothing from the zip runs)
    install(zip, candidate) → staging → compile check → folder swap
    undo()                  → reverts the last install (restores the previous
                              version, or removes a newly added plugin)

Folder layout in the user plugins folder while it works:
    .<name>.koplugin.new    staging (hidden, never loaded by KOReader)
    .<name>.koplugin.old    previous version during the swap (seconds)
    .<name>.koplugin.undo   previous version kept for "Undo last plugin install"
Interrupted installs are cleaned up at startup by Updater.cleanupLeftovers.

@module kindleui.util.plugininstaller
]]

local PluginZip = require("kindleui/util/pluginzip")
local Updater = require("kindleui/util/updater")
local logger = require("logger")

local Installer = {}

-- Used only if KOReader's own list cannot be read (pluginloader.lua moved).
local FALLBACK_BUILTINS = {
    "archiveviewer", "autodim", "autostandby", "autosuspend", "autoturn", "autowarmth",
    "batterystat", "bookshortcuts", "calibre", "cloudstorage", "coverbrowser", "coverimage",
    "docsettingtweak", "exporter", "externalkeyboard", "gestures", "hello", "hotkeys",
    "httpinspector", "japanese", "keepalive", "kosync", "movetoarchive", "newsdownloader",
    "opds", "perceptionexpander", "profiles", "qrclipboard", "readtimer", "SSH",
    "statistics", "systemstat", "terminal", "texteditor", "timesync", "vocabbuilder", "wallabag",
}

local function lfs() return require("libs/libkoreader-lfs") end

local function isDir(path) return lfs().attributes(path, "mode") == "directory" end

local function mkdirs(path)
    local acc = path:sub(1, 1) == "/" and "" or nil
    for part in path:gmatch("[^/]+") do
        acc = acc and (acc .. "/" .. part) or part
        if not isDir(acc) then lfs().mkdir(acc) end
    end
    return isDir(path)
end

--- Folder where KOReader loads user plugins from (same rule as PluginLoader).
function Installer.userPluginsDir()
    local data_dir = require("datastorage"):getDataDir()
    if data_dir == "." then
        -- Kindle/Kobo: data dir is KOReader's own folder; user plugins sit
        -- next to the built-in ones.
        return lfs().currentdir() .. "/plugins"
    end
    local dir = data_dir .. "/plugins"
    mkdirs(dir)
    return dir
end

--- Folder where the phone's upload lands before it is looked at.
function Installer.incomingDir()
    local dir = require("datastorage"):getSettingsDir() .. "/kindleui-incoming"
    mkdirs(dir)
    return dir
end

--- Removes everything in the incoming folder (after an install, and at startup).
function Installer.clearIncoming()
    local dir = require("datastorage"):getSettingsDir() .. "/kindleui-incoming"
    if not isDir(dir) then return end
    for name in lfs().dir(dir) do
        if name ~= "." and name ~= ".." then os.remove(dir .. "/" .. name) end
    end
end

local builtins_cache
--- Set of KOReader's built-in plugin names (never overwritten by this installer).
function Installer.builtins()
    if builtins_cache then return builtins_cache end
    local f = io.open("frontend/pluginloader.lua", "r") -- relative to KOReader's folder
    local set = f and PluginZip.parseBuiltins(f:read("*a"))
    if f then f:close() end
    if not set then
        set = {}
        for __, n in ipairs(FALLBACK_BUILTINS) do set[n] = true end
    end
    builtins_cache = set
    return set
end

local function readEntries(reader)
    local entries = {}
    for e in reader:iterate() do
        table.insert(entries, { path = e.path, mode = e.mode, size = tonumber(e.size) or 0 })
    end
    return entries
end

--- Looks inside a received zip.
-- @treturn table|nil { candidates = { { root, name, short, fullname, description,
--                     exists, builtin, disabled } }, entries }
-- @treturn string|nil error key: "not_zip" | "no_plugin"
function Installer.analyze(zip_path, zip_name)
    local Archiver = require("ffi/archiver")
    local reader = Archiver.Reader:new()
    if not reader:open(zip_path) then return nil, "not_zip" end
    local entries = readEntries(reader)
    local found = PluginZip.findPlugins(entries, zip_name)
    if #found == 0 then
        reader:close()
        return nil, "no_plugin"
    end
    local plugins_dir = Installer.userPluginsDir()
    local builtins = Installer.builtins()
    local disabled = G_reader_settings:readSetting("plugins_disabled") or {}
    for __, c in ipairs(found) do
        local prefix = c.root == "" and "" or (c.root .. "/")
        local meta = reader:extractToMemory(prefix .. "_meta.lua") or ""
        c.short = c.name:gsub("%.koplugin$", "")
        c.fullname = PluginZip.metaField(meta, "fullname") or c.short
        c.description = PluginZip.metaField(meta, "description")
        c.exists = isDir(plugins_dir .. "/" .. c.name)
        c.builtin = builtins[c.short] == true
        c.disabled = disabled[c.short] == true
    end
    reader:close()
    return { candidates = found, entries = entries }
end

--- Installs one candidate from the zip. Returns true, or nil + error key
-- ("builtin" | "unsafe_path" | "link" | "too_big" | "too_many" | "empty" |
--  "disk_full" | "extract" | "invalid" | "swap").
function Installer.install(zip_path, analysis, candidate)
    if candidate.builtin then return nil, "builtin" end
    local plan, err, bytes = PluginZip.plan(analysis.entries, candidate.root)
    if not plan then return nil, err end
    local plugins_dir = Installer.userPluginsDir()
    local free = require("kindleui/util/filesystem").freeSpace(plugins_dir)
    if free and free < bytes + 1024 * 1024 then return nil, "disk_full" end

    local target = plugins_dir .. "/" .. candidate.name
    local staged, old = Updater.stagePath(target)
    local undo = plugins_dir .. "/." .. candidate.name .. ".undo"
    Updater._purge(staged)
    if not mkdirs(staged) then return nil, "extract" end

    local Archiver = require("ffi/archiver")
    local reader = Archiver.Reader:new()
    if not reader:open(zip_path) then
        Updater._purge(staged)
        return nil, "extract"
    end
    local ok_all = true
    for __, item in ipairs(plan) do
        local dest = staged .. "/" .. item.rel
        if item.mode == "directory" then
            mkdirs(dest)
        else
            mkdirs(dest:match("^(.*)/[^/]+$"))
            if not reader:extractToPath(item.path, dest) then
                logger.warn("KindleUI installer: extract failed:", item.rel, reader.err)
                ok_all = false
                break
            end
        end
    end
    reader:close()
    if not ok_all then
        Updater._purge(staged)
        return nil, "extract"
    end
    -- Compile (not run) the two files KOReader loads first.
    for __, f in ipairs({ "main.lua", "_meta.lua" }) do
        local fn, cerr = loadfile(staged .. "/" .. f)
        if not fn then
            logger.warn("KindleUI installer: invalid plugin:", cerr)
            Updater._purge(staged)
            return nil, "invalid"
        end
    end

    local had_previous = isDir(target)
    if had_previous then
        Updater._purge(undo)
        local swapped = Updater.swapIn(target, staged) -- target → .old, staged → target
        if not swapped then
            Updater._purge(staged)
            return nil, "swap"
        end
        -- swapIn deleted .old; keep the previous version instead: redo with undo kept
    else
        local ok_mv = os.rename(staged, target)
        if not ok_mv then
            Updater._purge(staged)
            return nil, "swap"
        end
    end
    logger.info("KindleUI installer: installed", candidate.name, had_previous and "(replaced)" or "(new)")
    return true, had_previous, old
end

return Installer
