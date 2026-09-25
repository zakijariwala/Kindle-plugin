--[[--
HTTPS GET with real certificate checking, for the self-updater.

KOReader's default LuaSec setup (`ssl.https`) uses `verify = "none"`, which
is fine for fetching a web page but not for downloading code that will be
installed. This helper follows LuaSec's own `https.tcp()` connection
pattern, with two additions:

  * the server's certificate chain must verify against KOReader's bundled CA
    list (`data/ca-bundle.crt`, the Mozilla/certifi bundle KOReader ships);
  * the certificate must be issued for the host we asked for (LuaSec 1.3
    does not check host names itself), via subjectAltName DNS names (the
    common name is used only when a certificate has no DNS names).

Redirects are not followed; the updater only calls fixed GitHub endpoints
that answer directly.

@module kindleui.util.https
]]

local Https = {
    CAFILE = "data/ca-bundle.crt", -- relative to KOReader's directory (its working dir)
    TIMEOUT = 20,                  -- seconds per blocking socket operation
}

--- RFC 6125-style match of a certificate name against a host name.
-- Wildcards only as the whole left-most label ("*.github.com"), never
-- matching more than one label, never on a bare TLD.
function Https.hostMatches(pattern, host)
    if type(pattern) ~= "string" or type(host) ~= "string" then return false end
    pattern, host = pattern:lower(), host:lower()
    if pattern == host then return true end
    local rest = pattern:match("^%*%.(.+)$")
    if not rest or not rest:find("%.") then return false end
    local first, host_rest = host:match("^([^.]+)%.(.+)$")
    return first ~= nil and host_rest == rest
end

--- DNS names a LuaSec certificate is valid for.
function Https.certNames(cert)
    local names = {}
    local ok, ext = pcall(cert.extensions, cert)
    local san = ok and ext and ext["2.5.29.17"]
    if san and san.dNSName then
        for __, n in ipairs(san.dNSName) do table.insert(names, n) end
    end
    if #names == 0 then
        local ok_s, subject = pcall(cert.subject, cert)
        for __, e in ipairs(ok_s and subject or {}) do
            if e.name == "CN" or e.name == "commonName" then table.insert(names, e.value) end
        end
    end
    return names
end

local function verifyingCreate(params)
    local socket = require("socket")
    local ssl = require("ssl")
    return function()
        local conn = { sock = socket.try(socket.tcp()) }
        function conn:settimeout()
            return self.sock:settimeout(Https.TIMEOUT)
        end
        function conn:connect(host, port)
            socket.try(self.sock:connect(host, port))
            self.sock = socket.try(ssl.wrap(self.sock, params))
            self.sock:sni(host)
            self.sock:settimeout(Https.TIMEOUT)
            socket.try(self.sock:dohandshake()) -- fails if the chain does not verify
            local cert = self.sock:getpeercertificate()
            local matched = false
            for __, name in ipairs(cert and Https.certNames(cert) or {}) do
                if Https.hostMatches(name, host) then matched = true break end
            end
            if not matched then
                self.sock:close()
                socket.try(nil, "certificate is not valid for " .. tostring(host))
            end
            -- forward the remaining socket methods (send/receive/close/...)
            local mt = getmetatable(self.sock).__index
            for name, method in pairs(mt) do
                if type(method) == "function" and name ~= "settimeout" and name ~= "connect" then
                    self[name] = function(c, ...) return method(c.sock, ...) end
                end
            end
            return 1
        end
        return conn
    end
end

--- GET `url` (https only). Returns body, code; or nil, error.
-- @param max_bytes refuse larger responses (protects memory)
function Https.get(url, max_bytes, cafile)
    local http = require("socket.http")
    if not url:match("^https://") then return nil, "not an https URL" end
    local chunks, size, too_big = {}, 0, false
    local sink = function(chunk)
        if chunk then
            size = size + #chunk
            if max_bytes and size > max_bytes then
                too_big = true
                return nil, "response too large"
            end
            table.insert(chunks, chunk)
        end
        return 1
    end
    local params = {
        mode = "client",
        protocol = "any",
        options = { "all", "no_sslv2", "no_sslv3", "no_tlsv1" },
        verify = "peer",
        cafile = cafile or Https.CAFILE,
    }
    local ok, res, code = pcall(http.request, {
        url = url,
        method = "GET",
        sink = sink,
        redirect = false,
        headers = { ["accept"] = "application/vnd.github+json, application/zip, */*" },
        create = verifyingCreate(params),
    })
    if not ok then return nil, tostring(res) end
    if too_big then return nil, "response too large" end
    if not res then return nil, tostring(code) end
    return table.concat(chunks), code
end

return Https
