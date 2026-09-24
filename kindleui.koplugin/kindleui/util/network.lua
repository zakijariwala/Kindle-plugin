--[[--
Local network discovery for the transfer screen.

Finds an IPv4 address on which the phone (typically the hotspot provider)
can reach the Kindle. Nothing here needs, or tries to reach, the internet.

Discovery order:
 1. KOReader's `ffi/netinfo` (getifaddrs) — every UP, non-loopback interface,
    preferring the Wi-Fi interface KOReader's NetworkMgr manages;
 2. a routing-table lookup through an *unconnected* UDP socket (no packet is
    sent; it only asks the kernel which source address it would use);
 3. parsing `ip -4 addr` / `ifconfig` output as a last resort.

No subnet (e.g. 192.168.43.x) is ever assumed: hotspot implementations
differ between phone vendors and OS versions.

@module kindleui.util.network
]]

local Network = {}

local function log(level, ...)
    local ok, logger = pcall(require, "logger")
    if ok and logger and logger[level] then logger[level]("KindleUI network:", ...) end
end

--- Parses a dotted-quad IPv4 string. Returns 4 numbers or nil.
function Network.parseIPv4(ip)
    if type(ip) ~= "string" then return nil end
    local a, b, c, d = ip:match("^(%d+)%.(%d+)%.(%d+)%.(%d+)$")
    if not a then return nil end
    a, b, c, d = tonumber(a), tonumber(b), tonumber(c), tonumber(d)
    if a > 255 or b > 255 or c > 255 or d > 255 then return nil end
    return a, b, c, d
end

--- True if `ip` can plausibly be reached by a phone on the same LAN.
function Network.isUsableIPv4(ip)
    local a, b = Network.parseIPv4(ip)
    if not a then return false end
    if a == 0 or a == 127 then return false end       -- unspecified / loopback
    if a == 169 and b == 254 then return false end    -- link-local (no DHCP lease)
    if a >= 224 then return false end                 -- multicast / reserved
    return true
end

function Network.isPrivateIPv4(ip)
    local a, b = Network.parseIPv4(ip)
    if not a then return false end
    return a == 10 or (a == 172 and b >= 16 and b <= 31) or (a == 192 and b == 168)
        or (a == 100 and b >= 64 and b <= 127) -- CGNAT range, used by some hotspots
end

--- Picks the best candidate address.
-- @param candidates list of { iface = "wlan0", ip = "192.168.1.5", wireless = bool }
-- @string[opt] preferred_iface interface managed by KOReader's NetworkMgr
-- @treturn table|nil the chosen candidate
function Network.pickAddress(candidates, preferred_iface)
    local best, best_score
    for _, cand in ipairs(candidates or {}) do
        if Network.isUsableIPv4(cand.ip) then
            local score = 0
            if preferred_iface and cand.iface == preferred_iface then score = score + 100 end
            if cand.wireless then score = score + 50 end
            if cand.iface and cand.iface:match("^wl") then score = score + 25 end
            if Network.isPrivateIPv4(cand.ip) then score = score + 20 end
            -- USB networking (usb0) is a valid but unlikely target for a phone
            if cand.iface and cand.iface:match("^usb") then score = score - 30 end
            if not best or score > best_score then
                best, best_score = cand, score
            end
        end
    end
    return best
end

-- 1. getifaddrs via KOReader's ffi/netinfo
local function fromNetInfo()
    local ok, NetInfo = pcall(require, "ffi/netinfo")
    if not ok or not NetInfo then return {} end
    local cands = {}
    local ok_ret, err = pcall(function()
        local ni = NetInfo:new()
        for _, iface in ipairs(ni:retrieve()) do
            if iface.ipv4 then
                -- several addresses are joined with " / "
                for ip in tostring(iface.ipv4):gmatch("[^%s/]+") do
                    table.insert(cands, { iface = iface.name, ip = ip, wireless = iface.wireless and true or false })
                end
            end
        end
        ni:free()
    end)
    if not ok_ret then log("warn", "netinfo failed:", err) end
    return cands
end

-- 2. routing lookup through an unconnected UDP socket (sends nothing)
local function fromRoute()
    local ok, socket = pcall(require, "socket")
    if not ok then return {} end
    local targets = {}
    local ok_dev, Device = pcall(require, "device")
    if ok_dev and Device and Device.getDefaultRoute then
        local ok_gw, gw = pcall(Device.getDefaultRoute, Device)
        if ok_gw and gw then table.insert(targets, gw) end
    end
    table.insert(targets, "192.0.2.1") -- TEST-NET-1: only used for the route lookup
    local cands = {}
    for _, target in ipairs(targets) do
        local udp = socket.udp()
        if udp then
            if udp:setpeername(target, 9) then
                local ip = udp:getsockname()
                if ip then table.insert(cands, { ip = ip }) end
            end
            udp:close()
        end
        if cands[1] then break end
    end
    return cands
end

-- 3. command-line tools (BusyBox on Kindle provides ifconfig)
local function fromCommands()
    local cands = {}
    local function run(cmd, pattern_iface, pattern_ip)
        local p = io.popen(cmd .. " 2>/dev/null")
        if not p then return end
        local out = p:read("*a") or ""
        p:close()
        local iface
        for line in out:gmatch("[^\n]+") do
            local name = line:match(pattern_iface)
            if name then iface = name end
            local ip = line:match(pattern_ip)
            if ip then table.insert(cands, { iface = iface, ip = ip }) end
        end
    end
    run("ip -4 -o addr show", "^%d+:%s+(%S+)", "inet (%d+%.%d+%.%d+%.%d+)")
    if not cands[1] then
        run("ifconfig", "^(%S+)%s", "inet addr:(%d+%.%d+%.%d+%.%d+)")
    end
    if not cands[1] then
        run("ifconfig", "^(%S+):?%s", "inet (%d+%.%d+%.%d+%.%d+)")
    end
    return cands
end

--- Returns the name of the Wi-Fi interface KOReader manages, if known.
function Network.getManagedInterface()
    local ok, NetworkMgr = pcall(require, "ui/network/manager")
    if ok and NetworkMgr and NetworkMgr.getNetworkInterfaceName then
        local ok_name, name = pcall(NetworkMgr.getNetworkInterfaceName, NetworkMgr)
        if ok_name then return name end
    end
end

--- Finds the local IPv4 address to put in the QR code.
-- @treturn string|nil ip
-- @treturn string|nil interface name (may be nil even on success)
function Network.getLocalAddress()
    local preferred = Network.getManagedInterface()
    for _, source in ipairs({ fromNetInfo, fromRoute, fromCommands }) do
        local ok, cands = pcall(source)
        if ok then
            local best = Network.pickAddress(cands, preferred)
            if best then
                log("info", "local address", best.ip, "on", best.iface or "?")
                return best.ip, best.iface
            end
        end
    end
    log("warn", "no usable local IPv4 address")
    return nil
end

--- True if KOReader believes Wi-Fi is connected (no internet check!).
-- On platforms without a Wi-Fi toggle KOReader always reports true.
function Network.isWifiConnected()
    local ok, NetworkMgr = pcall(require, "ui/network/manager")
    if not ok or not NetworkMgr then return true end
    local ok_c, connected = pcall(NetworkMgr.isConnected, NetworkMgr)
    return not ok_c or connected and true or false
end

--- Kindle firmware ships an iptables firewall that drops unsolicited inbound
-- TCP. KOReader's SSH and HTTP-inspector plugins punch a temporary hole the
-- same way; we mirror that and always remove the rule again.
function Network.firewallFor(Device)
    if not (Device and Device.isKindle and Device:isKindle()) then return nil end
    local function run(cmd)
        local rc = os.execute(cmd)
        return rc == 0 or rc == true
    end
    local function rules(action, port)
        port = math.floor(tonumber(port))
        local ok_in = run(string.format(
            "iptables -%s INPUT -p tcp --dport %d -m conntrack --ctstate NEW,ESTABLISHED -j ACCEPT", action, port))
        local ok_out = run(string.format(
            "iptables -%s OUTPUT -p tcp --sport %d -m conntrack --ctstate ESTABLISHED -j ACCEPT", action, port))
        if ok_in and ok_out then
            log("info", action == "A" and "firewall opened for port" or "firewall closed for port", port)
        else
            -- Most likely cause of "the phone times out": say so in the log.
            log("err", "iptables", action == "A" and "open" or "close", "failed for port", port,
                "(INPUT ok:", ok_in, "OUTPUT ok:", ok_out, ")")
        end
        return ok_in and ok_out
    end
    return {
        open = function(port) return rules("A", port) end,
        close = function(port) return rules("D", port) end,
    }
end

return Network
