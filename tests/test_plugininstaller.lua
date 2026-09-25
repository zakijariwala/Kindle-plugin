-- Unit tests for the plugin installer's file operations: install (new and
-- replace), Undo, and leftover cleanup, in real temporary folders. KOReader's
-- archive reader is replaced by an in-memory fake.
local T = require("harness")
local lfs = require("lfs")
package.preload["libs/libkoreader-lfs"] = function() return lfs end
package.preload["logger"] = function()
    local function nop() end
    return { info = nop, warn = nop, err = nop, dbg = nop }
end

local settings = {}
_G.G_reader_settings = {
    readSetting = function(_, k) return settings[k] end,
    saveSetting = function(_, k, v) settings[k] = v end,
}

local root = T.tmpdir()
local data_dir = root .. "/data"
lfs.mkdir(data_dir)
package.preload["datastorage"] = function()
    return {
        getDataDir = function() return data_dir end,
        getSettingsDir = function() return data_dir .. "/settings" end,
    }
end

-- Fake ffi/archiver: zips[path] = { { path, mode, content }, ... }
-- Like the real one, it only extracts entries already seen by iterate().
local zips = {}
package.preload["ffi/archiver"] = function()
    local Reader = {}
    Reader.__index = Reader
    function Reader:new() return setmetatable({}, Reader) end
    function Reader:open(path) self.z = zips[path] self.seen = {} return self.z ~= nil end
    function Reader:close() self.z = nil end
    function Reader:iterate()
        local i = 0
        return function()
            i = i + 1
            local e = self.z[i]
            if e then
                self.seen[e.path] = e
                return { path = e.path, mode = e.mode, size = e.content and #e.content or 0 }
            end
        end
    end
    function Reader:extractToMemory(p) local e = self.seen[p] return e and e.content end
    function Reader:extractToPath(p, dest)
        local e = self.seen[p]
        if not e then self.err = "missing" return false end
        local f = io.open(dest, "wb")
        if not f then return false end
        f:write(e.content) f:close()
        return true
    end
    return { Reader = Reader }
end

local Installer = require("kindleui/util/plugininstaller")
local Config = require("kindleui/config")

local function read(path)
    local f = io.open(path, "r") if not f then return nil end
    local d = f:read("*a") f:close() return d
end
local function isDir(p) return lfs.attributes(p, "mode") == "directory" end
local function listed(dir)
    local t = T.listDir(dir)
    table.sort(t)
    return table.concat(t, ",")
end

local function pluginZip(path, version, extra)
    local z = {
        { path = "greeter-main/", mode = "directory" },
        { path = "greeter-main/greeter.koplugin/", mode = "directory" },
        { path = "greeter-main/greeter.koplugin/_meta.lua", mode = "file",
          content = 'local _ = require("gettext")\nreturn { name = "greeter", fullname = _("Greeter"), description = _("Says hi.") }\n' },
        { path = "greeter-main/greeter.koplugin/main.lua", mode = "file", content = "return { version = " .. version .. " }\n" },
        { path = "greeter-main/greeter.koplugin/lib/util.lua", mode = "file", content = "return " .. version .. "\n" },
        { path = "greeter-main/greeter.koplugin/.DS_Store", mode = "file", content = "junk" },
        { path = "greeter-main/README.md", mode = "file", content = "readme" },
    }
    for __, e in ipairs(extra or {}) do table.insert(z, e) end
    zips[path] = z
    return path
end

local plugins = Installer.userPluginsDir()
T.section("folders")
T.eq(plugins, data_dir .. "/plugins", "user plugins folder under the data dir")
T.ok(isDir(plugins), "created when missing")
T.ok(isDir(Installer.incomingDir()), "incoming folder created")

T.section("analyze")
local z1 = pluginZip("/zip/v1.zip", 1)
local a1 = assert(Installer.analyze(z1, "greeter-main.zip"))
T.eq(#a1.candidates, 1, "one plugin found")
local c1 = a1.candidates[1]
T.eq(c1.name, "greeter.koplugin", "folder name")
T.eq(c1.fullname, "Greeter", "display name read from _meta.lua")
T.eq(c1.description, "Says hi.", "description read from _meta.lua")
T.ok(not c1.exists and not c1.builtin and not c1.disabled, "new, not built-in, not disabled")
zips["/zip/none.zip"] = { { path = "x/readme.txt", mode = "file", content = "x" } }
T.eq(select(2, Installer.analyze("/zip/none.zip", "none.zip")), "no_plugin", "zip without a plugin")
T.eq(select(2, Installer.analyze("/zip/missing.zip", "m.zip")), "not_zip", "unreadable zip")

T.section("install new")
T.ok(not Installer.canUndo(), "nothing to undo before any install")
local ok, had = Installer.install(z1, a1, c1)
T.ok(ok, "installed")
T.eq(had, false, "no previous version")
T.eq(read(plugins .. "/greeter.koplugin/main.lua"), "return { version = 1 }\n", "main.lua in place")
T.eq(read(plugins .. "/greeter.koplugin/lib/util.lua"), "return 1\n", "nested file in place")
T.ok(read(plugins .. "/greeter.koplugin/.DS_Store") == nil, "junk skipped")
T.ok(read(plugins .. "/greeter.koplugin/README.md") == nil, "files outside the plugin skipped")
T.eq(listed(plugins), "greeter.koplugin", "no staging folder left")
T.ok(Installer.canUndo(), "undo available")
T.eq(Config.get("last_plugin_install").had_previous, false, "record: new plugin")

T.section("install replace keeps the previous version")
local z2 = pluginZip("/zip/v2.zip", 2)
local a2 = assert(Installer.analyze(z2, "greeter-main.zip"))
T.ok(a2.candidates[1].exists, "analysis says it replaces")
ok, had = Installer.install(z2, a2, a2.candidates[1])
T.ok(ok and had == true, "replaced")
T.eq(read(plugins .. "/greeter.koplugin/main.lua"), "return { version = 2 }\n", "new version in place")
T.eq(read(plugins .. "/.greeter.koplugin.undo/main.lua"), "return { version = 1 }\n", "previous version kept for Undo")
T.eq(listed(plugins), ".greeter.koplugin.undo,greeter.koplugin", "no .new/.old left")

T.section("undo restores the previous version")
local rec = Installer.undo()
T.ok(rec and rec.name == "greeter.koplugin", "undone")
T.eq(read(plugins .. "/greeter.koplugin/main.lua"), "return { version = 1 }\n", "version 1 back")
T.eq(listed(plugins), "greeter.koplugin", "undo folder consumed")
T.ok(not Installer.canUndo(), "only one level of undo")
T.eq(select(2, Installer.undo()), "nothing", "second undo refused")

T.section("undo removes a newly added plugin")
zips["/zip/other.zip"] = {
    { path = "other.koplugin/_meta.lua", mode = "file", content = 'return { name = "other" }' },
    { path = "other.koplugin/main.lua", mode = "file", content = "return {}" },
}
local ao = assert(Installer.analyze("/zip/other.zip", "other.zip"))
T.ok(Installer.install("/zip/other.zip", ao, ao.candidates[1]), "other installed")
T.ok(isDir(plugins .. "/other.koplugin"), "present")
T.ok(Installer.undo(), "undone")
T.ok(not isDir(plugins .. "/other.koplugin"), "removed again")
T.eq(listed(plugins), "greeter.koplugin", "greeter untouched")

T.section("a later install drops the older undo folder")
T.ok(Installer.install(z2, a2, a2.candidates[1]), "greeter v2 over v1")
T.ok(isDir(plugins .. "/.greeter.koplugin.undo"), "greeter undo kept")
T.ok(Installer.install("/zip/other.zip", ao, ao.candidates[1]), "then other installed")
T.ok(not isDir(plugins .. "/.greeter.koplugin.undo"), "greeter's undo folder removed (only the last install undoes)")
T.eq(Config.get("last_plugin_install").name, "other.koplugin", "record points at the last install")
Installer.undo()

T.section("refused and failed installs change nothing")
local before = listed(plugins)
T.eq(select(2, Installer.install(z2, a2, { name = "statistics.koplugin", root = "", builtin = true })), "builtin", "built-in refused")
T.eq(select(2, Installer.install(z2, a2, { name = "kindleui.koplugin", root = "" })), "self", "this plugin refused (use Check for updates)")
local bad = pluginZip("/zip/bad.zip", "(")
local ab = assert(Installer.analyze(bad, "greeter-main.zip"))
T.eq(select(2, Installer.install(bad, ab, ab.candidates[1])), "invalid", "syntax error in main.lua refused")
local evil = pluginZip("/zip/evil.zip", 3, { { path = "../evil.lua", mode = "file", content = "x" } })
local ae = assert(Installer.analyze(evil, "greeter-main.zip"))
T.eq(select(2, Installer.install(evil, ae, ae.candidates[1])), "unsafe_path", "path traversal refused")
local link = pluginZip("/zip/link.zip", 3, { { path = "greeter-main/greeter.koplugin/l", mode = "link" } })
local al = assert(Installer.analyze(link, "greeter-main.zip"))
T.eq(select(2, Installer.install(link, al, al.candidates[1])), "link", "symbolic link refused")
T.eq(listed(plugins), before, "plugins folder unchanged")
T.eq(read(plugins .. "/greeter.koplugin/main.lua"), "return { version = 2 }\n", "installed version unchanged")

T.section("commit / revert edge cases")
local dir = T.tmpdir()
lfs.mkdir(dir .. "/.x.koplugin.new")
io.open(dir .. "/.x.koplugin.new/main.lua", "w"):close()
lfs.mkdir(dir .. "/x.koplugin")
lfs.mkdir(dir .. "/.x.koplugin.undo") -- stale
lfs.mkdir(dir .. "/.x.koplugin.old")  -- stale
local c_ok, c_had = Installer.commit(dir, "x.koplugin", dir .. "/.x.koplugin.new")
T.ok(c_ok and c_had, "stale .undo/.old do not block a replace")
T.eq(listed(dir), ".x.koplugin.undo,x.koplugin", "result: plugin + undo")
T.ok(read(dir .. "/x.koplugin/main.lua") ~= nil, "staged copy is the plugin")
T.eq(select(2, Installer.commit(dir, "y.koplugin", dir .. "/nope")), "swap", "missing staged folder reported")
T.eq(select(2, Installer.revert(dir, { name = "../x.koplugin" })), "nothing", "invalid record name refused")
T.eq(select(2, Installer.revert(dir, { name = "z.koplugin", had_previous = true })), "nothing", "no undo folder")

T.section("startup cleanup")
lfs.mkdir(dir .. "/.a.koplugin.undo")
T.eq(Installer.cleanupUndo(dir, { name = "x.koplugin", had_previous = true }), 1, "orphan undo removed")
T.eq(listed(dir), ".x.koplugin.undo,x.koplugin", "the recorded one kept")
T.eq(Installer.cleanupUndo(dir, nil), 1, "no record: all undo folders removed")
local inc = Installer.incomingDir()
io.open(inc .. "/upload.zip", "w"):close()
Installer.clearIncoming()
T.eq(#T.listDir(inc), 0, "incoming folder emptied")

T.done()
