-- Unit tests for kindleui/util/pluginzip.lua (plugin zip analysis).
local T = require("harness")
local PZ = require("kindleui/util/pluginzip")

local function F(path, size) return { path = path, mode = "file", size = size or 100 } end
local function D(path) return { path = path, mode = "directory", size = 0 } end
local function names(found)
    local t = {}
    for __, f in ipairs(found) do table.insert(t, f.name .. "@" .. f.root) end
    return table.concat(t, ",")
end

T.section("finding the plugin folder")
-- 1. Plain: the zip contains the .koplugin folder
T.eq(names(PZ.findPlugins({ D("coolread.koplugin/"), F("coolread.koplugin/main.lua"), F("coolread.koplugin/_meta.lua") })),
    "coolread.koplugin@coolread.koplugin", "folder at the top")
-- 2. GitHub "Download ZIP" of a repo that contains the plugin in a subfolder
T.eq(names(PZ.findPlugins({
    F("MyRepo-main/README.md"), F("MyRepo-main/docs/x.md"),
    F("MyRepo-main/src/coolread.koplugin/main.lua"), F("MyRepo-main/src/coolread.koplugin/_meta.lua"),
})), "coolread.koplugin@MyRepo-main/src/coolread.koplugin", "nested inside a repository download")
-- 3. GitHub "Download ZIP" of a repo itself named <name>.koplugin
T.eq(names(PZ.findPlugins({ F("coolread.koplugin-main/main.lua"), F("coolread.koplugin-main/_meta.lua"), F("coolread.koplugin-main/README.md") })),
    "coolread.koplugin@coolread.koplugin-main", "repo named <name>.koplugin, branch suffix")
T.eq(names(PZ.findPlugins({ F("coolread.koplugin-v1.2.0/main.lua"), F("coolread.koplugin-v1.2.0/_meta.lua") })),
    "coolread.koplugin@coolread.koplugin-v1.2.0", "release tag suffix")
-- 4. Files at the zip root, zip named <name>.koplugin.zip
T.eq(names(PZ.findPlugins({ F("main.lua"), F("_meta.lua") }, "coolread.koplugin.zip")),
    "coolread.koplugin@", "files at the root of coolread.koplugin.zip")
T.eq(#PZ.findPlugins({ F("main.lua"), F("_meta.lua") }, "download.zip"), 0, "root files without a usable name: refused")
-- several plugins in one zip
T.eq(names(PZ.findPlugins({
    F("pack/a.koplugin/main.lua"), F("pack/a.koplugin/_meta.lua"),
    F("pack/b.koplugin/main.lua"), F("pack/b.koplugin/_meta.lua"),
})), "a.koplugin@pack/a.koplugin,b.koplugin@pack/b.koplugin", "several plugins: all offered")
-- not plugins
T.eq(#PZ.findPlugins({ F("x.koplugin/main.lua") }), 0, "main.lua without _meta.lua")
T.eq(#PZ.findPlugins({ F("book.epub") }), 0, "not a plugin at all")
T.eq(#PZ.findPlugins({ F("__MACOSX/x.koplugin/main.lua"), F("__MACOSX/x.koplugin/_meta.lua") }), 0, "macOS junk copy ignored")
T.eq(#PZ.findPlugins({ F(".hidden.koplugin/main.lua"), F(".hidden.koplugin/_meta.lua") }), 0, "hidden name refused")

T.section("what gets extracted")
local entries = {
    D("repo-main/"), F("repo-main/README.md"), F("repo-main/screenshot.png", 5000000),
    D("repo-main/x.koplugin/"), F("repo-main/x.koplugin/main.lua"), F("repo-main/x.koplugin/_meta.lua"),
    D("repo-main/x.koplugin/icons/"), F("repo-main/x.koplugin/icons/a.svg"),
    F("repo-main/x.koplugin/.DS_Store"), F("repo-main/x.koplugin/._main.lua"),
    D("repo-main/x.koplugin/.git/"), F("repo-main/x.koplugin/.git/config"),
    F("__MACOSX/repo-main/x.koplugin/._main.lua"),
}
local plan, err, bytes = PZ.plan(entries, "repo-main/x.koplugin")
local rels = {}
for __, p in ipairs(plan or {}) do table.insert(rels, p.rel) end
T.eq(table.concat(rels, ","), "main.lua,_meta.lua,icons,icons/a.svg", "only the plugin folder, minus junk (README, screenshots, .git, macOS files)")
T.ok(err == nil and bytes == 300, "size counts only extracted files")
T.ok(PZ.isJunk("a/.git/config") and PZ.isJunk("._x") and PZ.isJunk("__MACOSX/y") and not PZ.isJunk("icons/a.svg"), "junk detection")

T.section("hostile or broken archives")
local p2, e2 = PZ.plan({ F("x.koplugin/main.lua"), F("x.koplugin/../../evil.lua") }, "x.koplugin")
T.ok(p2 == nil and e2 == "unsafe_path", "'..' anywhere: refused")
local _p3, e3 = PZ.plan({ F("x.koplugin/main.lua"), F("/etc/passwd") }, "x.koplugin")
T.eq(e3, "unsafe_path", "absolute path: refused")
local _p4, e4 = PZ.plan({ F("x.koplugin/main.lua"), { path = "x.koplugin/link", mode = "link", size = 0 } }, "x.koplugin")
T.eq(e4, "link", "symbolic link: refused")
local _p5, e5 = PZ.plan({ F("x.koplugin/main.lua", PZ.MAX_UNPACKED_BYTES), F("x.koplugin/_meta.lua", 10) }, "x.koplugin")
T.eq(e5, "too_big", "unpacked size limit")
local many = {}
for i = 1, PZ.MAX_FILES + 1 do table.insert(many, F("x.koplugin/f" .. i .. ".lua", 1)) end
local _p6, e6 = PZ.plan(many, "x.koplugin")
T.eq(e6, "too_many", "file count limit")
T.ok(PZ.isUnsafePath("C:/x") and PZ.isUnsafePath("a\\b") and not PZ.isUnsafePath("a/b.lua"), "windows-style paths refused")

T.section("plugin names")
T.ok(PZ.validName("coolread.koplugin") and PZ.validName("SSH.koplugin") and PZ.validName("my-plugin_2.koplugin"), "valid names")
T.ok(not PZ.validName(".x.koplugin") and not PZ.validName("x") and not PZ.validName("a b.koplugin") and not PZ.validName("../x.koplugin"), "invalid names")

T.section("reading _meta.lua without running it")
local meta = [[
local _ = require("gettext")
return {
    name = "coolread",
    fullname = _("Cool Reader Tools"),
    description = _([[Adds cool things.
Second line.]].."]]"..[[),
}
]]
T.eq(PZ.metaField(meta, "fullname"), "Cool Reader Tools", "fullname in _()")
T.eq(PZ.metaField(meta, "description"), "Adds cool things. Second line.", "long-string description, whitespace folded")
T.eq(PZ.metaField('return { fullname = "Plain \\"quoted\\"" }', "fullname"), 'Plain "quoted"', "plain string with escapes")
T.eq(PZ.metaField("return { fullname = _('Single') }", "fullname"), "Single", "single quotes")
T.ok(PZ.metaField("return { fullname = computeName() }", "fullname") == nil, "computed value: not guessed")
T.ok(PZ.metaField(meta, "missing") == nil, "missing key")

T.section("built-in plugin list from KOReader's source")
local src = [[
local BUILTIN_PLUGINS = {
    ["archiveviewer"] = true,
    ["SSH"] = true,
    ["statistics"] = true,
}
]]
local set = PZ.parseBuiltins(src)
T.ok(set and set.SSH and set.statistics and set.archiveviewer and not set.kindleui, "parsed")
T.ok(PZ.parseBuiltins("nothing here") == nil, "unknown source: nil")
local koreader_src = os.getenv("KOREADER_SRC")
if koreader_src then
    local f = io.open(koreader_src .. "/frontend/pluginloader.lua")
    local real = PZ.parseBuiltins(f:read("*a")) f:close()
    T.ok(real and real.calibre and real.SSH and real.coverbrowser, "parses the real pluginloader.lua")
end

T.done()
