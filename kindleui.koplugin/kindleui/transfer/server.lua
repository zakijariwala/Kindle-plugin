--[[--
Minimal, temporary, non-blocking HTTP/1.1 server for local book transfer.

Built on LuaSocket (bundled with KOReader). It follows the same integration
pattern as KOReader's own `ui/message/simpletcpserver.lua` (used by the HTTP
inspector plugin): the object exposes `waitEvent()` and `stop()` and is
registered with `UIManager:insertZMQ()`, so KOReader's main loop polls it.
Unlike SimpleTCPServer it can stream a large request body straight to disk
without holding it in RAM and without blocking the UI.

Polling only happens while the server is registered, i.e. while the Send
Book screen is open. `stop()` closes every socket immediately.

The server knows nothing about tokens or files: all decisions are made by a
`handler` object (see transfer/session.lua):

    handler:onHeaders(req) -> response | { upload = job, expect_continue = bool }
    handler:onUploadDone(req, job) -> response          (job:finish() inside)
    handler:onUploadFailed(req, job, reason) -> response|nil
    handler:onServerStopped()                         (optional)

where `response = { status = 200, content_type = "...", body = "..." }`.

@module kindleui.transfer.server
]]

local socket = require("socket")

local Server = {}
Server.__index = Server

local STATUS_TEXT = {
    [100] = "Continue", [200] = "OK", [400] = "Bad Request", [403] = "Forbidden",
    [404] = "Not Found", [405] = "Method Not Allowed", [408] = "Request Timeout",
    [409] = "Conflict", [410] = "Gone", [411] = "Length Required",
    [413] = "Payload Too Large", [415] = "Unsupported Media Type",
    [431] = "Request Header Fields Too Large", [500] = "Internal Server Error",
    [503] = "Service Unavailable", [507] = "Insufficient Storage",
}

local DEFAULTS = {
    host = "*",
    port = 8080,
    max_header_bytes = 16 * 1024,
    max_clients = 6,
    header_timeout = 15,  -- seconds to receive complete request headers
    body_idle_timeout = 45, -- seconds without any body data => upload cancelled
    chunk_size = 64 * 1024,
    time_budget = 0.04,   -- max seconds spent per main-loop iteration
}

function Server:new(o)
    o = o or {}
    for k, v in pairs(DEFAULTS) do
        if o[k] == nil then o[k] = v end
    end
    assert(o.handler, "Server: handler required")
    o.clients = {}
    return setmetatable(o, self)
end

function Server:_log(level, ...)
    if self.logger and self.logger[level] then
        self.logger[level]("KindleUI server:", ...)
    end
end

--- Binds the listening socket. Tries `port`, then the next `port_attempts-1` ports.
-- @treturn bool ok
-- @treturn string|nil error
function Server:start(port_attempts)
    port_attempts = port_attempts or 1
    local last_err
    for i = 0, port_attempts - 1 do
        local port = self.port + i
        local srv, err = socket.bind(self.host, port)
        if srv then
            srv:settimeout(0)
            self.listener = srv
            local _, bound_port = srv:getsockname()
            self.port = tonumber(bound_port) or port
            self:_log("info", "listening on port", self.port)
            return true
        end
        last_err = err
        self:_log("warn", "cannot bind port", port, err)
    end
    return false, last_err
end

function Server:isRunning()
    return self.listener ~= nil
end

--- Stops the server: closes the listener and every client, aborting any
-- in-flight upload. Idempotent (also called by UIManager on quit).
function Server:stop()
    if not self.listener and not next(self.clients) then return end
    for c in pairs(self.clients) do
        self:_dropClient(c, "server_stopped")
    end
    if self.listener then
        self.listener:close()
        self.listener = nil
        self:_log("info", "stopped")
    end
    if self.handler.onServerStopped then
        pcall(self.handler.onServerStopped, self.handler)
    end
end

function Server:clientCount()
    local n = 0
    for _ in pairs(self.clients) do n = n + 1 end
    return n
end

-- Parses "a=b&c=d" (form-urlencoded semantics).
local function parseQuery(q)
    local t = {}
    if not q then return t end
    for pair in q:gmatch("[^&]+") do
        local k, v = pair:match("^([^=]*)=?(.*)$")
        if k then
            local function dec(s)
                s = s:gsub("+", " ")
                return (s:gsub("%%(%x%x)", function(h) return string.char(tonumber(h, 16)) end))
            end
            t[dec(k)] = dec(v)
        end
    end
    return t
end
Server.parseQuery = parseQuery

local function parseHead(head)
    local lines = {}
    for line in (head .. "\r\n"):gmatch("(.-)\r?\n") do
        table.insert(lines, line)
    end
    local method, target, version = (lines[1] or ""):match("^(%u+) (%S+) HTTP/(%d%.%d)$")
    if not method then return nil end
    local headers = {}
    for i = 2, #lines do
        local line = lines[i]
        if line ~= "" then
            local k, v = line:match("^([^:]+):%s*(.-)%s*$")
            if not k then return nil end
            headers[k:lower()] = v
        end
    end
    local path, query = target:match("^([^?#]*)%??([^#]*)")
    return {
        method = method,
        target = target,
        path = path,
        query = parseQuery(query),
        version = version,
        headers = headers,
    }
end
Server.parseHead = parseHead

--- Builds a complete HTTP response string.
function Server.buildResponse(resp)
    local status = resp.status or 200
    local body = resp.body or ""
    local head = {
        string.format("HTTP/1.1 %d %s", status, STATUS_TEXT[status] or "Unknown"),
        "Content-Type: " .. (resp.content_type or "text/plain; charset=utf-8"),
        "Content-Length: " .. #body,
        "Connection: close",
        "Cache-Control: no-store",
        "X-Content-Type-Options: nosniff",
        "Referrer-Policy: no-referrer",
        "X-Frame-Options: DENY",
    }
    if resp.csp then
        table.insert(head, "Content-Security-Policy: " .. resp.csp)
    end
    return table.concat(head, "\r\n") .. "\r\n\r\n" .. body
end

-- Sends a response (bounded blocking time) and closes the connection.
function Server:_respond(c, resp)
    if c.closed then return end
    c.sock:settimeout(2)
    c.sock:send(Server.buildResponse(resp))
    self:_closeClient(c)
end

function Server:_closeClient(c)
    if c.closed then return end
    c.closed = true
    pcall(c.sock.close, c.sock)
    self.clients[c] = nil
end

-- Drops a client, aborting its upload (if any) and notifying the handler.
function Server:_dropClient(c, reason)
    if c.job and c.job.state ~= "done" and c.job.state ~= "aborted" then
        c.job:abort(reason)
        if self.handler.onUploadFailed then
            pcall(self.handler.onUploadFailed, self.handler, c.req, c.job, reason)
        end
    end
    self:_closeClient(c)
end

function Server:_accept(now)
    for _ = 1, 4 do -- a few per iteration at most
        local sock = self.listener:accept()
        if not sock then return end
        if self:clientCount() >= self.max_clients then
            sock:close()
        else
            sock:settimeout(0)
            local c = { sock = sock, phase = "head", buf = {}, buf_len = 0, last = now, started = now }
            self.clients[c] = true
        end
    end
end

function Server:_onHeadData(c, data, now)
    table.insert(c.buf, data)
    c.buf_len = c.buf_len + #data
    local all = table.concat(c.buf)
    local head_end = all:find("\r\n\r\n", 1, true)
    if not head_end then
        if c.buf_len > self.max_header_bytes then
            self:_respond(c, { status = 431, body = "Request headers too large." })
        else
            c.buf = { all }
        end
        return
    end
    local req = parseHead(all:sub(1, head_end - 1))
    local rest = all:sub(head_end + 4)
    c.buf, c.buf_len = nil, 0
    if not req then
        self:_respond(c, { status = 400, body = "Bad request." })
        return
    end
    c.req = req
    local ok, result = pcall(self.handler.onHeaders, self.handler, req)
    if not ok then
        self:_log("err", "handler error:", result)
        self:_respond(c, { status = 500, body = "Internal error." })
        return
    end
    if not result.upload then
        self:_respond(c, result)
        return
    end
    c.job = result.upload
    c.phase = "body"
    c.last = now
    if result.expect_continue then
        c.sock:settimeout(1)
        c.sock:send("HTTP/1.1 100 Continue\r\n\r\n")
        c.sock:settimeout(0)
    end
    if #rest > 0 then
        self:_onBodyData(c, rest)
    elseif c.job:isComplete() then
        self:_completeUpload(c)
    end
end

function Server:_completeUpload(c)
    local ok, resp = pcall(self.handler.onUploadDone, self.handler, c.req, c.job)
    if not ok then
        self:_log("err", "handler error:", resp)
        c.job:abort("io")
        resp = { status = 500, body = "Internal error." }
    end
    c.job = nil -- ownership handed back to the handler
    self:_respond(c, resp)
end

function Server:_onBodyData(c, data)
    local ok, err = c.job:write(data)
    if not ok then
        local resp
        if self.handler.onUploadFailed then
            local okh, r = pcall(self.handler.onUploadFailed, self.handler, c.req, c.job, err)
            resp = okh and r or nil
        end
        c.job = nil
        self:_respond(c, resp or { status = 500, body = "Upload failed." })
        return
    end
    if c.job:isComplete() then
        self:_completeUpload(c)
    end
end

-- Reads whatever is available from one client, within the time budget.
function Server:_service(c, now, deadline)
    while not c.closed do
        local want
        if c.phase == "body" then
            want = math.min(self.chunk_size, c.job.expected_size - c.job.received)
            if want <= 0 then want = 1 end
        else
            want = 4096
        end
        local data, err, partial = c.sock:receive(want)
        local chunk = data or partial
        if chunk and #chunk > 0 then
            c.last = now
            if c.phase == "body" then
                self:_onBodyData(c, chunk)
            else
                self:_onHeadData(c, chunk, now)
            end
        end
        if c.closed then return end
        if err == "closed" then
            self:_dropClient(c, "cancelled")
            return
        end
        if err == "timeout" or (not data and not err) then
            -- Nothing more right now. While a body is streaming, wait briefly
            -- for more data (bounded by the per-iteration budget) to keep
            -- throughput up without spinning.
            local remaining = deadline - socket.gettime()
            if c.phase ~= "body" or remaining <= 0 then return end
            local readable = socket.select({ c.sock }, nil, remaining)
            if not readable or not readable[1] then return end
        end
        if socket.gettime() >= deadline then return end
    end
end

--- Called by UIManager's main loop (ZMQ-style polling). Never returns an
-- event: all work is done in place, the handler schedules UI updates itself.
function Server:waitEvent()
    if not self.listener then return nil end
    local now = socket.gettime()
    local deadline = now + self.time_budget
    self:_accept(now)
    for c in pairs(self.clients) do
        if c.phase == "head" and now - c.started > self.header_timeout then
            self:_respond(c, { status = 408, body = "Request timeout." })
        elseif c.phase == "body" and now - c.last > self.body_idle_timeout then
            self:_log("warn", "upload stalled, dropping client")
            self:_dropClient(c, "cancelled")
        else
            self:_service(c, now, deadline)
        end
        if not self.listener then break end -- handler stopped us
    end
    return nil
end

return Server
