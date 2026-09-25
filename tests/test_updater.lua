-- Unit tests for the self-updater's pure parts (no network, no KOReader).
local T = require("harness")
package.preload["libs/libkoreader-lfs"] = function() return require("lfs") end
local Https = require("kindleui/util/https")
local Updater = require("kindleui/util/updater")

T.section("certificate host name matching")
T.ok(Https.hostMatches("api.github.com", "api.github.com"), "exact")
T.ok(Https.hostMatches("API.GitHub.com", "api.github.com"), "case-insensitive")
T.ok(Https.hostMatches("*.github.com", "codeload.github.com"), "wildcard, one label")
T.ok(not Https.hostMatches("*.github.com", "github.com"), "wildcard does not match the bare domain")
T.ok(not Https.hostMatches("*.github.com", "a.b.github.com"), "wildcard does not span labels")
T.ok(not Https.hostMatches("*.com", "github.com"), "no wildcard on a TLD")
T.ok(not Https.hostMatches("github.com.evil.com", "github.com"), "different host")
T.ok(not Https.hostMatches("api.github.com", "api.github.com.evil.com"), "suffix attack")
T.ok(not Https.hostMatches("a*.github.com", "api.github.com"), "partial-label wildcards refused")
T.ok(not Https.hostMatches(nil, "x"), "nil pattern")

T.section("certificate names")
local cert = {
    extensions = function() return { ["2.5.29.17"] = { dNSName = { "github.com", "www.github.com" } } } end,
    subject = function() return { { name = "CN", value = "ignored.example" } } end,
}
T.eq(table.concat(Https.certNames(cert), ","), "github.com,www.github.com", "subjectAltName DNS names")
local cn_only = {
    extensions = function() return {} end,
    subject = function() return { { name = "O", value = "x" }, { name = "CN", value = "old.example" } } end,
}
T.eq(table.concat(Https.certNames(cn_only), ","), "old.example", "falls back to CN without SAN")

T.section("archive entry filtering")
T.eq(Updater.archiveTarget("kindle-plugin-abc123/kindleui.koplugin/main.lua"), "main.lua", "plugin file")
T.eq(Updater.archiveTarget("kindle-plugin-abc123/kindleui.koplugin/kindleui/ui/home.lua"), "kindleui/ui/home.lua", "nested file")
T.eq(Updater.archiveTarget("kindle-plugin-abc123/kindleui.koplugin/kindleui/"), "kindleui/", "directory entry")
T.ok(Updater.archiveTarget("kindle-plugin-abc123/README.md") == nil, "outside the plugin ignored")
T.ok(Updater.archiveTarget("kindle-plugin-abc123/tests/test_qr.lua") == nil, "tests ignored")
T.ok(Updater.archiveTarget("kindle-plugin-abc123/kindleui.koplugin/../../evil.lua") == nil, "traversal refused")
T.ok(Updater.archiveTarget("kindle-plugin-abc123/kindleui.koplugin/") == nil, "the folder itself")
T.ok(Updater.archiveTarget("kindle-plugin-abc123/kindleuiXkoplugin/main.lua") == nil, "dot is literal")

T.section("staging paths")
local new, old = Updater.stagePath("/mnt/us/koreader/plugins/kindleui.koplugin")
T.eq(new, "/mnt/us/koreader/plugins/.kindleui.koplugin.new", "staging is hidden and not a .koplugin")
T.eq(old, "/mnt/us/koreader/plugins/.kindleui.koplugin.old", "backup is hidden and not a .koplugin")

local function write(path, text)
    local f = assert(io.open(path, "w")) f:write(text) f:close()
end
local function read(path)
    local f = io.open(path, "r") if not f then return nil end
    local s = f:read("*a") f:close() return s
end
local function makePlugin(dir, marker)
    os.execute('mkdir -p "' .. dir .. '/kindleui/ui"')
    write(dir .. "/main.lua", "return { marker = '" .. marker .. "' }\n")
    write(dir .. "/_meta.lua", "return {}\n")
    write(dir .. "/kindleui/config.lua", "return {}\n")
    write(dir .. "/kindleui/ui/home.lua", "return {}\n")
end

T.section("validate + swap")
local root = T.tmpdir()
local plugin = root .. "/kindleui.koplugin"
makePlugin(plugin, "old")
write(plugin .. "/BUILD", "1111111111111111111111111111111111111111\n")
T.eq(Updater.installedBuild(plugin), "1111111111111111111111111111111111111111", "reads BUILD")
T.ok(Updater.installedBuild(root .. "/missing") == nil, "no BUILD -> unknown")

local staged = Updater.stagePath(plugin)
makePlugin(staged, "new")
T.ok(Updater.validateStaged(staged), "complete staged copy is valid")
write(staged .. "/kindleui/ui/home.lua", "return {")
local ok, err = Updater.validateStaged(staged)
T.ok(not ok and err:find("home.lua"), "syntax error in staged copy is caught")
write(staged .. "/kindleui/ui/home.lua", "return {}\n")
os.remove(staged .. "/_meta.lua")
T.ok(not Updater.validateStaged(staged), "missing file is caught")
write(staged .. "/_meta.lua", "return {}\n")

T.ok(Updater.swapIn(plugin, staged), "swap succeeds")
T.ok(read(plugin .. "/main.lua"):find("new"), "new version in place")
T.ok(read(staged .. "/main.lua") == nil, "staging folder consumed")
T.ok(read(select(2, Updater.stagePath(plugin)) .. "/main.lua") == nil, "old copy removed")

T.section("rollback")
makePlugin(staged, "newer")
os.execute('chmod 555 "' .. root .. '"')
local can_write = io.open(root .. "/.probe", "w")
if can_write then -- running as root: permissions not enforced, simulate with a missing staging dir
    can_write:close() os.remove(root .. "/.probe")
    os.execute('chmod 755 "' .. root .. '"')
    Updater._purge(staged)
    local ok2 = Updater.swapIn(plugin, staged)
    T.ok(not ok2, "swap fails when the staged copy is missing")
    T.ok(read(plugin .. "/main.lua"):find("new"), "current version restored after a failed swap")
else
    local ok2 = Updater.swapIn(plugin, staged)
    os.execute('chmod 755 "' .. root .. '"')
    T.ok(not ok2, "swap fails on a read-only folder")
    T.ok(read(plugin .. "/main.lua"):find("new"), "current version untouched")
end

T.section("startup cleanup of interrupted updates")
do
    local pd = T.tmpdir()
    local sd = T.tmpdir()
    makePlugin(pd .. "/kindleui.koplugin", "current")
    makePlugin(pd .. "/.kindleui.koplugin.new", "half-staged")          -- staging left behind
    makePlugin(pd .. "/.kindleui.koplugin.old", "stale-backup")         -- backup, plugin present
    makePlugin(pd .. "/.other.koplugin.old", "interrupted-swap")        -- other.koplugin missing
    makePlugin(pd .. "/SSH.koplugin", "untouched")
    write(pd .. "/.kindleui.koplugin.new.txt", "not a dir")             -- not our pattern
    write(sd .. "/kindleui-update.zip", "zip")
    local res = Updater.cleanupLeftovers(pd, sd)
    T.eq(res.removed, 3, "staging + stale backup + update zip removed")
    T.eq(res.restored, 1, "interrupted swap restored")
    local left = T.listDir(pd)
    table.sort(left)
    T.eq(table.concat(left, ","), ".kindleui.koplugin.new.txt,SSH.koplugin,kindleui.koplugin,other.koplugin",
        "only leftovers touched")
    T.ok(read(pd .. "/kindleui.koplugin/main.lua"):find("current"), "installed plugin untouched")
    T.ok(read(pd .. "/other.koplugin/main.lua"):find("interrupted-swap", 1, true), "restored copy in place")
    T.ok(read(sd .. "/kindleui-update.zip") == nil, "update zip removed")
    local res2 = Updater.cleanupLeftovers(pd, sd)
    T.eq(res2.removed + res2.restored, 0, "second run finds nothing")
    T.eq(Updater.cleanupLeftovers(pd .. "/missing", nil).removed, 0, "missing folder is harmless")
end

T.done()
