--[[--
Self-updater: "Check for updates" in Settings → About.

Runs only when the user taps it (no automatic checks, no background work).

  1. Ask GitHub for the latest commit on the repo's `main` branch
     (api.github.com, unauthenticated, one small request).
  2. If it differs from the installed build (the `BUILD` file next to
     main.lua), download that exact commit as a zip (codeload.github.com).
  3. Extract only `kindleui.koplugin/` into a hidden staging folder next to
     the plugin, check it looks complete and that its Lua compiles.
  4. Swap folders with two renames (old → .kindleui.koplugin.old,
     staging → kindleui.koplugin), roll back if anything fails, then delete
     the old copy. KOReader must restart to load the new code.

All network requests go through util/https.lua (certificate chain *and*
host name checked). Settings, the library cache and thumbnails live outside
the plugin folder and are not touched.

The file operations (`stagePath`, `swapIn`, `archiveTarget`) do not need
KOReader and are unit-tested.

@module kindleui.util.updater
]]

local Updater = {
    REPO = "zakijariwala/kindle-plugin",
    BRANCH = "main",
    PLUGIN_DIR_NAME = "kindleui.koplugin",
    MAX_API_BYTES = 256 * 1024,
    MAX_ZIP_BYTES = 20 * 1024 * 1024,
}

local function log(level, ...)
    local ok, logger = pcall(require, "logger")
    if ok and logger and logger[level] then logger[level]("KindleUI updater:", ...) end
end

-- Overridable for tests (G_reader_settings "kindleui" → update_api_url / update_zip_url / update_cafile).
local function setting(key)
    local ok, Config = pcall(require, "kindleui/config")
    return ok and Config.get(key) or nil
end

function Updater.apiUrl()
    return setting("update_api_url")
        or string.format("https://api.github.com/repos/%s/commits/%s", Updater.REPO, Updater.BRANCH)
end

function Updater.zipUrl(sha)
    local tpl = setting("update_zip_url") or ("https://codeload.github.com/" .. Updater.REPO .. "/zip/%s")
    return string.format(tpl, sha)
end

--- Installed build (commit SHA) or nil if unknown (manual install).
function Updater.installedBuild(plugin_dir)
    local f = io.open(plugin_dir .. "/BUILD", "r")
    if not f then return nil end
    local sha = (f:read("*l") or ""):match("^(%x+)")
    f:close()
    return sha
end

function Updater.short(sha)
    return sha and sha:sub(1, 7) or "?"
end

--- Maps an archive entry to a path inside the plugin folder, or nil.
-- GitHub archives look like "<repo>-<sha>/kindleui.koplugin/main.lua".
-- Anything outside kindleui.koplugin/, or containing "..", is ignored.
function Updater.archiveTarget(entry_path)
    local rel = entry_path:match("^[^/]+/" .. Updater.PLUGIN_DIR_NAME:gsub("%.", "%%.") .. "/(.*)$")
    if not rel or rel == "" then return nil end
    for part in rel:gmatch("[^/]+") do
        if part == ".." or part == "." then return nil end
    end
    if rel:sub(1, 1) == "/" then return nil end
    return rel
end

function Updater.stagePath(plugin_dir)
    local parent, name = plugin_dir:match("^(.*)/([^/]+)/?$")
    return parent .. "/." .. name .. ".new", parent .. "/." .. name .. ".old"
end

local function isDir(path)
    local lfs = require("libs/libkoreader-lfs")
    return lfs.attributes(path, "mode") == "directory"
end

local function purge(path)
    if not isDir(path) then return end
    local ok, ffiUtil = pcall(require, "ffi/util")
    if ok and ffiUtil.purgeDir then
        ffiUtil.purgeDir(path)
    else
        os.execute('rm -rf "' .. path:gsub('"', '\\"') .. '"')
    end
end
Updater._purge = purge

--- Replaces plugin_dir with staged_dir. Returns true or nil, err (rolled back).
function Updater.swapIn(plugin_dir, staged_dir)
    local old_dir = select(2, Updater.stagePath(plugin_dir))
    purge(old_dir)
    local ok, err = os.rename(plugin_dir, old_dir)
    if not ok then return nil, "could not move the current version aside: " .. tostring(err) end
    ok, err = os.rename(staged_dir, plugin_dir)
    if not ok then
        os.rename(old_dir, plugin_dir) -- roll back
        return nil, "could not move the new version in place: " .. tostring(err)
    end
    purge(old_dir)
    return true
end

--- Checks that a staged copy looks like a complete plugin and compiles.
function Updater.validateStaged(dir)
    for __, f in ipairs({ "main.lua", "_meta.lua", "kindleui/config.lua", "kindleui/ui/home.lua" }) do
        local fn, err = loadfile(dir .. "/" .. f)
        if not fn then return nil, "invalid update (" .. f .. "): " .. tostring(err) end
    end
    return true
end

--- Latest commit on the branch: { sha, date, message } or nil, err.
function Updater.fetchLatest()
    local Https = require("kindleui/util/https")
    local body, code = Https.get(Updater.apiUrl(), Updater.MAX_API_BYTES, setting("update_cafile"))
    if not body then return nil, code end
    if code ~= 200 then return nil, "GitHub answered " .. tostring(code) end
    local ok, data = pcall(function() return require("json").decode(body) end)
    if not ok or type(data) ~= "table" or type(data.sha) ~= "string" or not data.sha:match("^%x+$") then
        return nil, "unexpected answer from GitHub"
    end
    local commit = type(data.commit) == "table" and data.commit or {}
    local committer = type(commit.committer) == "table" and commit.committer or {}
    return {
        sha = data.sha,
        date = type(committer.date) == "string" and committer.date:sub(1, 10) or nil,
        message = type(commit.message) == "string" and commit.message:match("^[^\n]*") or nil,
    }
end

--- Downloads and installs `sha` over the plugin at plugin_dir.
-- Returns true, or nil + error (the installed version is left untouched).
function Updater.install(plugin_dir, sha)
    local Https = require("kindleui/util/https")
    local DataStorage = require("datastorage")
    local lfs = require("libs/libkoreader-lfs")
    local staged = Updater.stagePath(plugin_dir)
    local zip_path = DataStorage:getSettingsDir() .. "/kindleui-update.zip"

    local body, code = Https.get(Updater.zipUrl(sha), Updater.MAX_ZIP_BYTES, setting("update_cafile"))
    if not body then return nil, "download failed: " .. tostring(code) end
    if code ~= 200 then return nil, "download failed: GitHub answered " .. tostring(code) end
    local f = io.open(zip_path, "wb")
    if not f then return nil, "cannot write the download" end
    f:write(body)
    f:close()
    body = nil -- luacheck: ignore

    local ok_arch, Archiver = pcall(require, "ffi/archiver")
    if not ok_arch then
        os.remove(zip_path)
        return nil, "this KOReader cannot extract archives"
    end
    purge(staged)
    lfs.mkdir(staged)
    local reader = Archiver.Reader:new()
    if not reader:open(zip_path) then
        os.remove(zip_path)
        return nil, "the downloaded archive is not readable"
    end
    local count = 0
    local entries = {}
    for entry in reader:iterate() do
        local rel = Updater.archiveTarget(entry.path)
        if rel and (entry.mode == "file" or entry.mode == "directory") then
            table.insert(entries, { path = entry.path, rel = rel, mode = entry.mode })
        end
    end
    local err
    for __, e in ipairs(entries) do
        local target = staged .. "/" .. e.rel
        if e.mode == "directory" then
            lfs.mkdir((target:gsub("/$", "")))
        else
            local ok = reader:extractToPath(e.path, target)
            if not ok then err = "could not extract " .. e.rel .. ": " .. tostring(reader.err) break end
            count = count + 1
        end
    end
    reader:close()
    os.remove(zip_path)
    if err or count == 0 then
        purge(staged)
        return nil, err or "the archive did not contain the plugin"
    end
    local valid, verr = Updater.validateStaged(staged)
    if not valid then
        purge(staged)
        return nil, verr
    end
    local bf = io.open(staged .. "/BUILD", "w")
    if bf then bf:write(sha, "\n") bf:close() end
    local swapped, serr = Updater.swapIn(plugin_dir, staged)
    if not swapped then
        purge(staged)
        return nil, serr
    end
    log("info", "installed build", Updater.short(sha), "(" .. count .. " files)")
    return true
end

return Updater
