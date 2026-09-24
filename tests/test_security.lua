-- Unit tests for kindleui/util/security.lua, filesystem.lua and network.lua
-- Run via tests/run.sh
local T = require("harness")
local Security = require("kindleui/util/security")
local FS = require("kindleui/util/filesystem")
local Network = require("kindleui/util/network")

T.section("random tokens")
local seen = {}
for _ = 1, 200 do
    local tok = assert(Security.randomToken())
    T.eq(#tok, 32, "token is 32 hex chars")
    T.ok(tok:match("^[0-9a-f]+$"), "token is lowercase hex")
    T.ok(not seen[tok], "token is unique")
    seen[tok] = true
end
local tok, err = Security.randomToken(16, "/nonexistent/random")
T.ok(tok == nil and err, "missing random source fails closed (no math.random fallback)")

T.section("constant time compare")
T.ok(Security.constantTimeEquals("abc", "abc"), "equal")
T.ok(not Security.constantTimeEquals("abc", "abd"), "differ")
T.ok(not Security.constantTimeEquals("abc", "abcd"), "length differs")
T.ok(not Security.constantTimeEquals(nil, "abc"), "nil")

T.section("filename sanitizing")
local cases_ok = {
    { "The Hobbit.epub", "The Hobbit.epub" },
    { "  spaced   name  .pdf", "spaced name .pdf" },
    { "Ünïcödé 日本語.epub", "Ünïcödé 日本語.epub" },
    { "a:b*c?d\"e<f>g|h.pdf", "a_b_c_d_e_f_g_h.pdf" },
    { ".hidden.epub", "hidden.epub" },
    { "...dots.epub", "dots.epub" },
    { "tab\there.epub", "tab here.epub" },
    { "Book.EPUB", "Book.EPUB" },
    { "trailing.epub...", "trailing.epub" },
}
for _, c in ipairs(cases_ok) do
    local got, why = Security.sanitizeFilename(c[1])
    T.eq(got, c[2], "sanitize " .. c[1] .. (why and (" (" .. why .. ")") or ""))
end
local cases_bad = {
    { "../../etc/passwd", "path_separator" },
    { "/etc/passwd.epub", "path_separator" },
    { "..\\..\\win.epub", "path_separator" },
    { "sub/dir.epub", "path_separator" },
    { "nul\0byte.epub", "null_byte" },
    { "", "empty" },
    { "..", "empty" },
    { ".", "empty" },
    { "noextension", "no_extension" },
    { "bad\255utf8.epub", "invalid_utf8" },
    { "overlong\192\175.epub", "invalid_utf8" },
    { "surrogate\237\160\128.epub", "invalid_utf8" },
}
for _, c in ipairs(cases_bad) do
    local got, why = Security.sanitizeFilename(c[1])
    T.ok(got == nil, "reject " .. c[1]:gsub("%z", "\\0"))
    T.eq(why, c[2], "reason for " .. c[1]:gsub("%z", "\\0"))
end
T.ok(Security.sanitizeFilename(nil) == nil, "reject nil")
local long = string.rep("é", 200) .. ".epub"
local s = Security.sanitizeFilename(long)
T.ok(#s <= Security.MAX_FILENAME_BYTES, "long name truncated to limit")
T.ok(Security.isValidUtf8(s), "truncation keeps valid UTF-8")
T.ok(s:sub(-5) == ".epub", "truncation keeps extension")
T.eq(Security.getExtension("a.tar.GZ"), "gz", "extension lowercased")

T.section("safe path joining")
T.ok(not pcall(FS.join, "/tmp", "../x"), "join refuses traversal")
T.ok(not pcall(FS.join, "/tmp", "a/b"), "join refuses separators")
T.eq(FS.join("/tmp/", "a.epub"), "/tmp/a.epub", "join")

T.section("unique destination names")
local dir = T.tmpdir()
T.eq(FS.uniquePath(dir, "x.epub"), dir .. "/x.epub", "free name kept")
io.open(dir .. "/x.epub", "wb"):close()
T.eq(FS.uniquePath(dir, "x.epub"), dir .. "/x (2).epub", "collision gets suffix")
io.open(dir .. "/x (2).epub", "wb"):close()
T.eq(FS.uniquePath(dir, "x.epub"), dir .. "/x (3).epub", "second collision")
T.ok(FS.isDir(dir), "isDir")
T.ok(not FS.isDir(dir .. "/x.epub"), "file is not dir")

T.section("format sniffing")
local function write(name, data) local f = io.open(dir .. "/" .. name, "wb") f:write(data) f:close() return dir .. "/" .. name end
T.ok(FS.looksLike(write("a.epub", "PK\3\4rest"), "epub"), "epub zip magic")
T.ok(not FS.looksLike(write("b.epub", "<html>"), "epub"), "fake epub rejected")
T.ok(FS.looksLike(write("c.pdf", "%PDF-1.7\n"), "pdf"), "pdf magic")
T.ok(not FS.looksLike(write("d.pdf", "hello"), "pdf"), "fake pdf rejected")
T.ok(FS.looksLike(write("e.txt", "anything"), "txt"), "unknown formats deferred to KOReader")
T.ok(FS.looksLike(write("f.mobi", string.rep("\0", 60) .. "BOOKMOBI"), "mobi"), "mobi magic")

T.section("IP selection")
T.ok(Network.isUsableIPv4("192.168.43.100"), "hotspot ip usable")
T.ok(not Network.isUsableIPv4("127.0.0.1"), "loopback unusable")
T.ok(not Network.isUsableIPv4("169.254.3.4"), "link-local unusable")
T.ok(not Network.isUsableIPv4("300.1.1.1"), "invalid octet")
T.ok(not Network.isUsableIPv4("1.2.3"), "malformed")
local pick = Network.pickAddress({
    { iface = "usb0", ip = "192.168.15.244" },
    { iface = "lo", ip = "127.0.0.1" },
    { iface = "wlan0", ip = "172.20.10.3", wireless = true },
}, "wlan0")
T.eq(pick and pick.ip, "172.20.10.3", "prefers managed wifi interface (iPhone hotspot range)")
pick = Network.pickAddress({ { iface = "eth0", ip = "10.1.2.3" }, { iface = "wlan0", ip = "169.254.1.1" } })
T.eq(pick and pick.ip, "10.1.2.3", "skips link-local")
T.ok(Network.pickAddress({}) == nil, "no candidates => nil")
T.ok(Network.pickAddress({ { iface = "lo", ip = "127.0.0.1" } }) == nil, "only loopback => nil")

T.done()
