--[[--
The Kindle's own Wi-Fi settings, as its Settings → Wi-Fi & Bluetooth screen
uses them: airplane mode, saved networks (forget), network details.

Everything goes through the Kindle's lipc services, the same ones KOReader's
Kindle NetworkMgr uses (frontend/device/kindle/device.lua):

    com.lab126.cmd   wirelessEnable (Int)   0 = airplane mode on
    com.lab126.wifid profileData (hash)     saved networks: netid, essid, secured, …
                     currentEssid (hash)    essid, signal, signal_max, connected
                     deleteProfile (Int)    forget saved network <netid>
                     711 (Str)              the connection diagnostics text

Passwords never leave lipc: only netid, essid and secured are read from
profileData. Joining a network (list or hidden) uses KOReader's NetworkMgr
(saveNetwork / authenticateNetwork), not this module.

Nothing here runs until a Settings entry is opened. On anything that is not a
Kindle with lipc, `available()` is false and the entries are left out.

@module kindleui.util.kindlewifi
]]

local KindleWifi = {}

local function log(level, ...)
    local ok, logger = pcall(require, "logger")
    if ok and logger and logger[level] then logger[level]("KindleUI wifi:", ...) end
end

-- lipc handles, opened per call and closed again (as KOReader does). Tests
-- replace these two functions.
function KindleWifi._simple()
    local ok, lipc = pcall(require, "liblipclua")
    return ok and lipc and lipc.init("com.github.koreader.kindleui") or nil
end
function KindleWifi._hash()
    local ok, lipc = pcall(require, "libopenlipclua")
    return ok and lipc and lipc.open_no_name() or nil
end

--- True on a Kindle whose lipc bindings load.
function KindleWifi.available()
    local ok, Device = pcall(require, "device")
    if not (ok and Device and Device.isKindle and Device:isKindle()) then return false end
    local h = KindleWifi._simple()
    if not h then return false end
    h:close()
    return true
end

local function withSimple(fn)
    local h = KindleWifi._simple()
    if not h then return nil end
    local ok, a = pcall(fn, h)
    h:close()
    if not ok then log("warn", a) return nil end
    return a
end

local function readHash(prop)
    local h = KindleWifi._hash()
    if not h then return nil end
    local input = h:new_hasharray()
    local ok, result = pcall(function() return h:access_hash_property("com.lab126.wifid", prop, input) end)
    local t
    if ok and result then
        t = result:to_table()
        result:destroy()
    else
        log("warn", "cannot read", prop)
    end
    input:destroy()
    h:close()
    return t
end

--- Airplane mode: true, false, or nil when unknown.
function KindleWifi.airplaneMode()
    local v = withSimple(function(h) return h:get_int_property("com.lab126.cmd", "wirelessEnable") end)
    if v == nil then return nil end
    return v == 0
end

function KindleWifi.setAirplaneMode(on)
    log("info", "airplane mode", on and "on" or "off")
    return withSimple(function(h)
        h:set_int_property("com.lab126.cmd", "wirelessEnable", on and 0 or 1)
        return true
    end)
end

--- Saved networks, sorted by name: { { netid = 3, essid = "…", secured = true }, … }.
-- Nothing else (no password field) is copied out of the profile.
function KindleWifi.cleanProfiles(raw)
    local out = {}
    for __, p in ipairs(raw or {}) do
        local id = tonumber(p.netid)
        if id and p.essid and p.essid ~= "" then
            table.insert(out, { netid = id, essid = p.essid, secured = p.secured == "yes" })
        end
    end
    table.sort(out, function(a, b) return a.essid:lower() < b.essid:lower() end)
    return out
end

function KindleWifi.savedNetworks()
    return KindleWifi.cleanProfiles(readHash("profileData"))
end

--- The network in use: { essid, netid, signal, signal_max, connected } or nil.
function KindleWifi.current()
    local t = readHash("currentEssid")
    local p = t and t[1]
    if not p or not p.essid or p.essid == "" then return nil end
    return {
        essid = p.essid,
        netid = tonumber(p.netid),
        signal = tonumber(p.signal),
        signal_max = tonumber(p.signal_max),
        connected = p.connected == "yes",
    }
end

--- Forgets a saved network (its password too), like "Forget" on the Kindle.
function KindleWifi.forget(netid)
    netid = tonumber(netid)
    if not netid then return nil end
    log("info", "forgetting saved network", netid)
    return withSimple(function(h)
        h:set_int_property("com.lab126.wifid", "deleteProfile", netid)
        return true
    end)
end

--- Parses wifid's diagnostics text (property "711") into a table:
-- mac, wireless, essid, bssid, signal, captive, security, channel, country,
-- ip, netmask, gateway, config, dns. Unknown or empty fields are left out.
function KindleWifi.parseDiagnostics(text)
    local d = {}
    if type(text) ~= "string" then return d end
    local function field(pattern)
        local v = text:match(pattern)
        v = v and v:gsub("^%s+", ""):gsub("[%s,]+$", "")
        return v ~= "" and v or nil
    end
    d.mac = field("MAC:%s*([%x:]+)")
    d.wireless = field("Wireless:%s*([^\n]-)%s*%(")
    local ap = field("AP:%s*([^\n]+)")
    if ap then
        d.essid, d.bssid = ap:match("^(.-)%s*%(([%x:]+)%)$")
        d.essid = d.essid or ap
    end
    d.signal = field("Signal:%s*([^\n]+)")
    d.captive = field("Captive:%s*([^\n]-)%s*%(")
    d.security = field("Security:%s*([^\n]+)")
    d.channel = field("Channel:%s*([^\n]+)")
    d.country = field("Country:%s*([^\n]+)")
    d.ip = field("\n[%d.]+%s+IP%s*:%s*([^\n]*)")
    d.netmask = field("Netmask%s*:%s*([^\n]*)")
    d.gateway = field("Gateway%s*:%s*([^\n]*)")
    d.config = field("Config%s*:%s*([^\n]*)")
    d.dns = field("DNS%s*:%s*([^\n]*)")
    return d
end

function KindleWifi.details()
    local text = withSimple(function(h) return h:get_string_property("com.lab126.wifid", "711") end)
    return KindleWifi.parseDiagnostics(text)
end

return KindleWifi
