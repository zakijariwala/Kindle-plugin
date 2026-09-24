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
}

--- Pre-flight checks. Returns { ip = ..., dest_dir = ... } or nil + error key
-- ("no_wifi" | "no_ip").
function LocalHttp:prepare()
    if not Network.isWifiConnected() then
        return nil, "no_wifi"
    end
    local ip, iface = Network.getLocalAddress()
    if not ip then
        return nil, "no_ip"
    end
    return { ip = ip, iface = iface, dest_dir = Books.destinationDir() }
end

--- Starts a session. Returns the session (with `.url`) or nil + error key
-- ("server" | "random" | "dest_dir" | "qr").
function LocalHttp:start(info, callbacks)
    local session = Session:new{
        dest_dir = info.dest_dir,
        is_supported = Books.isSupportedName,
        scheduler = UIManager,
        port = Config.get("transfer_port"),
        timeout = Config.get("transfer_timeout"),
        max_bytes = Config.get("transfer_max_mb") * 1024 * 1024,
        firewall = Network.firewallFor(Device),
        callbacks = callbacks,
        logger = logger,
    }
    session.format_list = Books.formatList()
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
