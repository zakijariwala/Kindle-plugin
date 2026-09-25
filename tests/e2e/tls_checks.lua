-- TLS checks for util/https.lua, run with KOReader's own LuaJIT inside the
-- emulator container (see tests/e2e/updater.sh).
require("setupkoenv")
package.path = "/home/user/.config/koreader/plugins/kindleui.koplugin/?.lua;" .. package.path
local H = require("kindleui/util/https")
local function try(label, url, ca, cap)
  local body, code = H.get(url, cap or 100000, ca)
  print(label, body and ("OK " .. tostring(code) .. " " .. #body .. " bytes") or ("REFUSED: " .. tostring(code)))
end
try("valid cert, test CA     ", "https://updates.test:8443/repos/x/y/commits/main", "/certs/ca.pem")
try("wrong host name in cert ", "https://updates.test:8444/repos/x/y/commits/main", "/certs/ca.pem")
try("self-signed cert        ", "https://updates.test:8445/repos/x/y/commits/main", "/certs/ca.pem")
try("valid cert, KOReader CAs", "https://updates.test:8443/repos/x/y/commits/main", nil)
try("plain http              ", "http://updates.test:8443/", "/certs/ca.pem")
try("size cap (1 KB)         ", "https://updates.test:8443/zip/" .. os.getenv("SHA"), "/certs/ca.pem", 1024)
try("zip download            ", "https://updates.test:8443/zip/" .. os.getenv("SHA"), "/certs/ca.pem", 20*1024*1024)
