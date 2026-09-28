--[[--
Settings → Connectivity, laid out like the Kindle's own Settings → Wi-Fi &
Bluetooth:

    Airplane mode            the Kindle's own switch (com.lab126.cmd)        [Kindle]
    Wi-Fi                    KOReader's Wi-Fi toggle (NetworkMgr)
    Wi-Fi networks…          scan, then KOReader's network list (connect, password)
    Join other network…      a hidden network by name and password           [Kindle]
    Saved networks           connect to or forget each one                   [Kindle]
    Network details          name, signal, security, IP, gateway, DNS, MAC
    Send Book
    (KOReader's full Network menu)

Joining and connecting go through KOReader's NetworkMgr (saveNetwork,
authenticateNetwork), which on a Kindle writes the network into the Kindle's
own list, so the Kindle's home screen knows it too. Airplane mode, saved
networks and details read the Kindle's lipc services (util/kindlewifi.lua).
Entries the device cannot do are left out. Nothing runs until tapped.

@module kindleui.ui.connectivity
]]

local ButtonDialog = require("ui/widget/buttondialog")
local ConfirmBox = require("ui/widget/confirmbox")
local InfoMessage = require("ui/widget/infomessage")
local KindleWifi = require("kindleui/util/kindlewifi")
local UIManager = require("ui/uimanager")
local _ = require("gettext")
local T = require("ffi/util").template

local Connectivity = {}

local function NetworkMgr() return require("ui/network/manager") end

local function info(text, timeout)
    UIManager:show(InfoMessage:new{ text = text, timeout = timeout })
end

-- Refreshes the checkmarks a little later: the Kindle switches radios
-- asynchronously.
local function refreshSoon(touchmenu_instance)
    if touchmenu_instance then
        UIManager:scheduleIn(2, function() touchmenu_instance:updateItems() end)
    end
end

--- Scans, then shows KOReader's own network list (tap a network to join it).
function Connectivity.showNetworks()
    local nm = NetworkMgr()
    if not nm:isWifiOn() then
        info(_("Turn on Wi-Fi first."), 3)
        return
    end
    local msg = InfoMessage:new{ text = _("Scanning for networks…") }
    UIManager:show(msg)
    UIManager:forceRePaint()
    local list, err = nm:getNetworkList()
    if list and #list == 0 then list, err = nm:getNetworkList() end -- first scans can come back empty
    UIManager:close(msg)
    if not list then
        info(err or _("No networks found."), 3)
        return
    end
    table.sort(list, function(a, b) return (a.signal_quality or 0) > (b.signal_quality or 0) end)
    UIManager:show(require("ui/widget/networksetting"):new{ network_list = list })
end

--- Connects to a known network by name (the Kindle uses the saved password).
function Connectivity.connect(essid)
    local nm = NetworkMgr()
    if not nm:isWifiOn() then
        info(_("Turn on Wi-Fi first."), 3)
        return
    end
    nm:authenticateNetwork({ ssid = essid })
    info(T(_("Connecting to %1…"), essid), 3)
end

--- "Join other network": a network that does not broadcast its name.
function Connectivity.joinOther()
    local MultiInputDialog = require("ui/widget/multiinputdialog")
    local dialog
    dialog = MultiInputDialog:new{
        title = _("Join other network"),
        fields = {
            { description = _("Network name"), hint = _("Network name") },
            { description = _("Password (empty for an open network)"), hint = _("Password"), text_type = "password" },
        },
        buttons = {{
            { text = _("Cancel"), id = "close", callback = function() UIManager:close(dialog) end },
            {
                text = _("Join"),
                is_enter_default = true,
                callback = function()
                    local fields = dialog:getFields()
                    local essid, password = fields[1], fields[2] or ""
                    if not essid or essid == "" then
                        info(_("Enter the network name."), 2)
                        return
                    end
                    UIManager:close(dialog)
                    local nm = NetworkMgr()
                    -- flags as in a scan result: the Kindle backend stores a
                    -- password only for WPA networks
                    nm:saveNetwork({ ssid = essid, password = password,
                        flags = password ~= "" and "[WPA2-PSK]" or "" })
                    Connectivity.connect(essid)
                end,
            },
        }},
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

--- Asks, then forgets a saved network (name and password), like the Kindle.
function Connectivity.confirmForget(net, on_done)
    UIManager:show(ConfirmBox:new{
        text = T(_("Forget %1?\n\nIts password is deleted from this Kindle. To use it again, join it and enter the password."), net.essid),
        ok_text = _("Forget"),
        ok_callback = function()
            if KindleWifi.forget(net.netid) then
                info(T(_("%1 forgotten."), net.essid), 2)
            else
                info(_("The network could not be forgotten."), 3)
            end
            if on_done then on_done() end
        end,
    })
end

-- Saved networks as menu items (built each time the submenu opens).
function Connectivity.savedItems()
    local items = {}
    local current = KindleWifi.current()
    for __, net in ipairs(KindleWifi.savedNetworks()) do
        local in_use = current and current.connected and current.essid == net.essid
        table.insert(items, {
            text = net.essid .. (in_use and ("  ·  " .. _("connected")) or ""),
            keep_menu_open = true,
            callback = function(touchmenu_instance)
                local dialog
                dialog = ButtonDialog:new{
                    title = net.essid,
                    title_align = "center",
                    buttons = {
                        {
                            {
                                text = _("Connect"),
                                enabled = not in_use,
                                callback = function()
                                    UIManager:close(dialog)
                                    Connectivity.connect(net.essid)
                                end,
                            },
                            {
                                text = _("Forget"),
                                callback = function()
                                    UIManager:close(dialog)
                                    Connectivity.confirmForget(net, function()
                                        -- the list changed: back out of it
                                        if touchmenu_instance then touchmenu_instance:backToUpperMenu() end
                                    end)
                                end,
                            },
                        },
                    },
                }
                UIManager:show(dialog)
            end,
        })
    end
    if #items == 0 then
        table.insert(items, { text = _("No saved networks"), enabled = false })
    end
    return items
end

--- The details text (pure: takes the parsed diagnostics and the current network).
function Connectivity.detailsText(d, current)
    local lines = {}
    local function add(label, value)
        if value and value ~= "" then table.insert(lines, label .. ": " .. value) end
    end
    local essid = (current and current.essid) or d.essid
    if not essid then
        table.insert(lines, _("Not connected to a network."))
    else
        add(_("Network"), essid)
        local signal = current and current.signal and current.signal_max
            and (current.signal .. "/" .. current.signal_max) or d.signal
        add(_("Signal"), signal)
        add(_("Security"), d.security)
        add(_("Channel"), d.channel)
        add(_("IP address"), d.ip)
        add(_("Subnet mask"), d.netmask)
        add(_("Router"), d.gateway)
        add(_("DNS"), d.dns)
        add(_("Address setup"), d.config)
    end
    add(_("MAC address"), d.mac)
    add(_("Wi-Fi region"), d.country)
    return table.concat(lines, "\n")
end

function Connectivity.showDetails()
    local text
    if KindleWifi.available() then
        text = Connectivity.detailsText(KindleWifi.details(), KindleWifi.current())
    else
        -- elsewhere: at least the address the phone would use
        local ip, iface = require("kindleui/util/network").getLocalAddress()
        text = ip and (_("IP address") .. ": " .. ip .. (iface and (" (" .. iface .. ")") or ""))
            or _("Not connected to a network.")
    end
    UIManager:show(InfoMessage:new{ text = text })
end

--- The Connectivity items for Settings. `extra` (Send Book, KOReader's menu)
-- is appended by the caller.
function Connectivity.items()
    local items = {}
    local kindle = KindleWifi.available()
    local nm = NetworkMgr()
    if kindle and KindleWifi.airplaneMode() ~= nil then
        table.insert(items, {
            text = _("Airplane mode"),
            help_text = _("Turns off all wireless connections, as in the Kindle's own settings."),
            checked_func = function() return KindleWifi.airplaneMode() == true end,
            callback = function(touchmenu_instance)
                KindleWifi.setAirplaneMode(not KindleWifi.airplaneMode())
                refreshSoon(touchmenu_instance)
            end,
        })
    end
    local wifi = nm.getWifiToggleMenuTable and nm:getWifiToggleMenuTable()
    if wifi then
        wifi.text = _("Wi-Fi")
        table.insert(items, wifi)
    end
    table.insert(items, {
        text = _("Wi-Fi networks…"),
        help_text = _("Networks in range. Tap one to join it."),
        enabled_func = function() return nm:isWifiOn() end,
        callback = function(touchmenu_instance)
            if touchmenu_instance then touchmenu_instance:closeMenu() end
            Connectivity.showNetworks()
        end,
    })
    if kindle then
        table.insert(items, {
            text = _("Join other network…"),
            help_text = _("A network that does not show its name. You need its exact name and password."),
            enabled_func = function() return nm:isWifiOn() end,
            callback = function(touchmenu_instance)
                if touchmenu_instance then touchmenu_instance:closeMenu() end
                Connectivity.joinOther()
            end,
        })
        table.insert(items, {
            text = _("Saved networks"),
            help_text = _("Networks this Kindle remembers. Connect to one, or forget it (its password is deleted)."),
            sub_item_table_func = Connectivity.savedItems,
        })
    end
    table.insert(items, {
        text = _("Network details"),
        keep_menu_open = true,
        callback = function() Connectivity.showDetails() end,
    })
    return items
end

return Connectivity
