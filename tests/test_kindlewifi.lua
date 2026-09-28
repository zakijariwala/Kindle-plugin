-- Unit tests for kindleui/util/kindlewifi.lua (the Kindle's Wi-Fi settings
-- through lipc) and the details text of kindleui/ui/connectivity.lua.
local T = require("harness")

-- Only what connectivity.lua needs at load time.
for __, m in ipairs({ "ui/widget/buttondialog", "ui/widget/confirmbox", "ui/widget/infomessage", "ui/uimanager" }) do
    package.preload[m] = function() return {} end
end
package.preload["gettext"] = function() return setmetatable({}, { __call = function(__, s) return s end }) end
package.preload["ffi/util"] = function()
    return { template = function(s, ...) local a = { ... } return (s:gsub("%%(%d)", function(i) return tostring(a[tonumber(i)]) end)) end }
end

local KindleWifi = require("kindleui/util/kindlewifi")
local Connectivity = require("kindleui/ui/connectivity")

-- The Kindle's "711" diagnostics text, as read on a Paperwhite (FW 5.19.5),
-- with made-up names and addresses.
local DIAG = [[********* 2- Connection *********
2.1 MAC: 00:11:22:33:44:55
2.2 Wireless: On(1)
2.3 AP: Home Net 5G (aa:bb:cc:dd:ee:ff)
2.3.1   Signal: 4/5
2.3.2   Captive: No(0)
2.3.3   Security: WPA2-PSK
2.3.4   Channel: 6
2.6 Country: IN

********* 3- Networks *********
3.1   1	Cafe (guest)	0	[WPA2-PSK]	C: [CCMP]	G: [CCMP]	(40)			 EAP: [, , ]
3.2   2	Home Net 5G	1	[WPA2-PSK]	C: [CCMP]	G: [CCMP]	(7)			 EAP: [, , ]
********* 4- Interface *********
4.1  IP        : 192.168.1.23
4.2  Netmask   : 255.255.255.0
4.3  Broadcast :
4.4  Gateway   : 192.168.1.1
4.5  Config    : DHCP
4.6  DNS       : 192.168.1.1,
4.7  Sponsored    : No(0)

********* 5- DHCP *********
adding dns 192.168.1.1
]]

T.section("diagnostics text")
local d = KindleWifi.parseDiagnostics(DIAG)
T.eq(d.mac, "00:11:22:33:44:55", "MAC")
T.eq(d.wireless, "On", "wireless on")
T.eq(d.essid, "Home Net 5G", "network name (spaces kept)")
T.eq(d.bssid, "aa:bb:cc:dd:ee:ff", "access point address")
T.eq(d.signal, "4/5", "signal")
T.eq(d.captive, "No", "captive portal")
T.eq(d.security, "WPA2-PSK", "security")
T.eq(d.channel, "6", "channel")
T.eq(d.country, "IN", "region")
T.eq(d.ip, "192.168.1.23", "IP")
T.eq(d.netmask, "255.255.255.0", "netmask")
T.eq(d.gateway, "192.168.1.1", "gateway")
T.eq(d.config, "DHCP", "address setup")
T.eq(d.dns, "192.168.1.1", "DNS, trailing comma dropped")
T.eq(next(KindleWifi.parseDiagnostics(nil)), nil, "nil text → empty table")
local off = KindleWifi.parseDiagnostics("2.1 MAC: 00:11:22:33:44:55\n2.2 Wireless: Off(0)\n4.1  IP        : \n")
T.eq(off.wireless, "Off", "wireless off")
T.eq(off.ip, nil, "empty IP left out")
T.eq(off.essid, nil, "no access point")

T.section("saved networks")
local raw = {
    { essid = "zeta", netid = "2", secured = "yes", psk = "secret1", key_mgmt = "WPA-PSK" },
    { essid = "Alpha", netid = "5", secured = "no" },
    { essid = "", netid = "7", secured = "yes", psk = "x" },
    { essid = "no id", secured = "yes" },
}
local saved = KindleWifi.cleanProfiles(raw)
T.eq(#saved, 2, "entries without a name or id dropped")
T.eq(saved[1].essid, "Alpha", "sorted by name, case-insensitive")
T.eq(saved[2].netid, 2, "netid is a number")
T.eq(saved[2].secured, true, "secured flag")
T.eq(saved[1].secured, false, "open network")
local leaked = false
for __, n in ipairs(saved) do
    for k in pairs(n) do if k ~= "essid" and k ~= "netid" and k ~= "secured" then leaked = true end end
end
T.ok(not leaked, "nothing but name, id and secured is copied (no password)")

T.section("lipc calls (fake handles)")
local calls = {}
local props = { ["com.lab126.cmd wirelessEnable"] = 1 }
local fake_simple = {
    get_int_property = function(__, svc, prop) return props[svc .. " " .. prop] end,
    set_int_property = function(__, svc, prop, v) table.insert(calls, svc .. " " .. prop .. "=" .. v) props[svc .. " " .. prop] = v end,
    get_string_property = function(__, svc, prop) if prop == "711" then return DIAG end end,
    close = function() calls.closed = (calls.closed or 0) + 1 end,
}
local hashes = {
    currentEssid = { { essid = "Home Net 5G", netid = "3", signal = "4", signal_max = "5", connected = "yes" } },
    profileData = raw,
}
local fake_hash = {
    new_hasharray = function() return { destroy = function() end } end,
    access_hash_property = function(__, svc, prop)
        return { to_table = function() return hashes[prop] end, destroy = function() end }
    end,
    close = function() end,
}
KindleWifi._simple = function() return fake_simple end
KindleWifi._hash = function() return fake_hash end
T.eq(KindleWifi.airplaneMode(), false, "wirelessEnable 1 → airplane mode off")
KindleWifi.setAirplaneMode(true)
T.eq(calls[#calls], "com.lab126.cmd wirelessEnable=0", "airplane on writes wirelessEnable 0")
T.eq(KindleWifi.airplaneMode(), true, "and reads back as on")
KindleWifi.setAirplaneMode(false)
T.eq(calls[#calls], "com.lab126.cmd wirelessEnable=1", "airplane off writes 1")
T.ok(KindleWifi.forget("3"), "forget returns true")
T.eq(calls[#calls], "com.lab126.wifid deleteProfile=3", "forget writes deleteProfile <netid>")
T.eq(KindleWifi.forget("x"), nil, "a non-numeric id is refused")
T.eq(calls[#calls], "com.lab126.wifid deleteProfile=3", "…and nothing is written")
local cur = KindleWifi.current()
T.eq(cur.essid, "Home Net 5G", "current network")
T.eq(cur.signal, 4, "signal as a number")
T.eq(cur.connected, true, "connected")
T.eq(#KindleWifi.savedNetworks(), 2, "saved networks through lipc")
T.eq(KindleWifi.details().ip, "192.168.1.23", "details through lipc")
hashes.currentEssid = { { essid = "" } }
T.eq(KindleWifi.current(), nil, "no current network")
KindleWifi._simple = function() return nil end
T.eq(KindleWifi.airplaneMode(), nil, "no lipc → unknown")

T.section("details text")
local text = Connectivity.detailsText(d, { essid = "Home Net 5G", signal = 4, signal_max = 5, connected = true })
T.ok(text:find("Network: Home Net 5G", 1, true), "network name")
T.ok(text:find("Signal: 4/5", 1, true), "signal")
T.ok(text:find("IP address: 192.168.1.23", 1, true), "IP")
T.ok(text:find("Router: 192.168.1.1", 1, true), "router")
T.ok(text:find("MAC address: 00:11:22:33:44:55", 1, true), "MAC")
local none = Connectivity.detailsText(off, nil)
T.ok(none:find("Not connected", 1, true), "not connected")
T.ok(not none:find("IP address", 1, true), "no empty IP line")

T.done()
