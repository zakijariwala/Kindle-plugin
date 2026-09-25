--[[--
"Local Wi-Fi" transfer provider: phone → Kindle over the phone's hotspot (or
any shared LAN). No internet, DNS, cloud service or companion app involved.

@module kindleui.transfer.localhttp
]]

local Books = require("kindleui/util/books")
local Config = require("kindleui/config")
local Device = require("device")
local Network = require("kindleui/util/network")
local QR = require("kindleui/transfer/qr")
local Session = require("kindleui/transfer/session")
local SleepGuard = require("kindleui/util/sleepguard")
local UIManager = require("ui/uimanager")
local logger = require("logger")

local LocalHttp = {
    id = "local_http",
    PLUGIN_MAX_BYTES = 20 * 1024 * 1024,
}

local function isZipName(name)
    return name:lower():match("%.zip$") ~= nil
end

--- Pre-flight checks. Returns { ip = ..., dest_dir = ... } or nil + error key
-- ("no_wifi" | "no_ip").
-- @param opts optional { kind = "plugin" }: receive one plugin .zip instead of books
function LocalHttp:prepare(opts)
    if not Network.isWifiConnected() then
        return nil, "no_wifi"
    end
    local ip, iface = Network.getLocalAddress()
    if not ip then
        return nil, "no_ip"
    end
    local plugin = opts and opts.kind == "plugin"
    return {
        ip = ip,
        iface = iface,
        kind = plugin and "plugin" or "books",
        dest_dir = plugin and require("kindleui/util/plugininstaller").incomingDir() or Books.destinationDir(),
    }
end

--- Starts a session. Returns the session (with `.url`) or nil + error key
-- ("server" | "random" | "dest_dir" | "qr").
function LocalHttp:start(info, callbacks)
    local plugin = info.kind == "plugin"
    local session = Session:new{
        dest_dir = info.dest_dir,
        kind = info.kind,
        is_supported = plugin and isZipName or Books.isSupportedName,
        max_files = plugin and 1 or nil,
        scheduler = UIManager,
        port = Config.get("transfer_port"),
        timeout = Config.get("transfer_timeout"),
        max_bytes = plugin and LocalHttp.PLUGIN_MAX_BYTES or Config.get("transfer_max_mb") * 1024 * 1024,
        firewall = Network.firewallFor(Device),
        callbacks = callbacks,
        logger = logger,
    }
    session.format_list = Books.formatList()
    if not plugin then
        -- KOReader's collections, offered on the phone page.
        local ok, list = pcall(function() return require("kindleui/ui/library").collections() end)
        session.collections = ok and list or nil
    end
    local ok, err = session:start()
    if not ok then
        return nil, err
    end
    -- Keep the device awake while the phone may be sending data.
    SleepGuard.hold()
    local orig_stop = session.stop
    session.stop = function(s, reason)
        orig_stop(s, reason)
        SleepGuard.release() -- idempotent
    end
    session.ip = info.ip
    session.url = QR.buildUrl(info.ip, session.port, session:getPath())
    return session
end

return LocalHttp
