-- QR URL + upload page checks. If KOREADER_BASE points at a koreader-base
-- checkout, the URL is also encoded with KOReader's own ffi/qrencode.lua.
local T = require("harness")
local QR = require("kindleui/transfer/qr")
local UploadPage = require("kindleui/transfer/uploadpage")
local Security = require("kindleui/util/security")

T.section("QR URL")
local token = assert(Security.randomToken())
local url = QR.buildUrl("192.168.43.100", 8080, "/" .. token)
T.eq(url, "http://192.168.43.100:8080/" .. token, "URL format http://<ip>:<port>/<token>")
T.ok(#url < 80, "URL short enough for a low-density QR code")

local base = os.getenv("KOREADER_BASE")
if base then
    local qrencode = dofile(base .. "/ffi/qrencode.lua")
    local ok, grid = qrencode.qrcode(url)
    T.ok(ok, "KOReader's qrencode encodes the URL")
    T.ok(type(grid) == "table" and #grid <= 37, "QR version <= 5 (" .. tostring(#grid) .. " modules)")
else
    io.write("  skip KOReader qrencode check (set KOREADER_BASE=/path/to/koreader/base)\n")
end

T.section("upload page")
local page = UploadPage.render{ base_path = "/" .. token, formats = "EPUB, PDF <b>", max_mb = 500 }
T.ok(page:find('"/' .. token .. '"', 1, true), "tokenized base path embedded")
T.ok(page:find('type="file" multiple', 1, true), "several books can be selected")
T.ok(page:find("EPUB, PDF &lt;b&gt;", 1, true), "format list HTML-escaped")
T.ok(not page:find("<script src", 1, true), "no external scripts")
T.ok(not page:find("<link", 1, true), "no external stylesheets")
T.ok(not pcall(UploadPage.render, { base_path = '/x";alert(1)//' }), "refuses unexpected base path")
T.ok(UploadPage.CSP:find("default-src 'none'", 1, true), "CSP denies everything by default")

T.done()
