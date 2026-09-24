--[[--
A single, short-lived transfer session.

A session owns:
  * a cryptographically random token (only valid while the session lives),
  * the temporary HTTP server (registered with the UI main loop),
  * at most one in-flight upload.

It ends (server stopped, sockets closed, token cleared) when:
  * a book has been received successfully,
  * the user cancels,
  * the session expires,
  * the device suspends or KOReader exits.

KOReader-specific services are injected (`scheduler`, `firewall`,
`is_supported`) so the whole flow can be exercised by tests under plain
LuaJIT. See tests/test_transfer.lua.

@module kindleui.transfer.session
]]

local FS = require("kindleui/util/filesystem")
local Security = require("kindleui/util/security")
local Server = require("kindleui/transfer/server")
local UploadJob = require("kindleui/transfer/upload")
local UploadPage = require("kindleui/transfer/uploadpage")

local Session = {}
Session.__index = Session

-- Messages returned to the phone browser (plain text, shown verbatim).
local PHONE_MSG = {
    expired = "This transfer link has expired. Tap Send Book on your Kindle to get a new QR code.",
    busy = "Another upload is already in progress.",
    unsupported = "Unsupported file type. This file was not added to your library.",
    bad_name = "This file name cannot be used. Please rename the file and try again.",
    too_large = "This file is too large to send.",
    disk_full = "Not enough storage space to save this book.",
    length_required = "Your browser did not announce the file size. Please try another browser.",
    corrupt = "The uploaded file could not be added.",
    incomplete = "Upload interrupted. Please try again.",
    io = "The uploaded file could not be added.",
    done = "Book sent successfully.",
}
Session.PHONE_MSG = PHONE_MSG

--- @param o table
--   dest_dir      (string)   where books go (KOReader home folder)
--   is_supported  (function) filename -> bool (KOReader DocumentRegistry)
--   scheduler     (table)    UIManager-like: scheduleIn, unschedule, nextTick, insertZMQ, removeZMQ
--   port          (int)      preferred port
--   timeout       (int)      session lifetime in seconds
--   max_bytes     (int)      largest accepted upload
--   firewall      (table)    optional { open(port), close(port) }
--   callbacks     (table)    onProgress(filename, received, total),
--                            onReceived(path, filename), onFailed(reason, filename),
--                            onExpired(), onStopped()
--   logger        (table)    optional KOReader logger
--   random_source (string)   optional, tests only
function Session:new(o)
    assert(o.dest_dir and o.is_supported and o.scheduler, "Session: missing fields")
    o.port = o.port or 8080
    o.timeout = o.timeout or 15 * 60
    o.max_bytes = o.max_bytes or 500 * 1024 * 1024
    o.callbacks = o.callbacks or {}
    o.state = "new"
    return setmetatable(o, self)
end

function Session:_log(level, ...)
    if self.logger and self.logger[level] then
        self.logger[level]("KindleUI session:", ...)
    end
end

function Session:_emit(name, ...)
    local cb = self.callbacks[name]
    if cb then
        local ok, err = pcall(cb, ...)
        if not ok then self:_log("err", "callback", name, "failed:", err) end
    end
end

--- Starts the session. Returns true, or nil + reason
-- ("random" | "server" | "dest_dir").
function Session:start()
    assert(self.state == "new", "Session:start called twice")
    if not FS.isDir(self.dest_dir) then
        self:_log("err", "destination directory missing:", self.dest_dir)
        return nil, "dest_dir"
    end
    local token, err = Security.randomToken(16, self.random_source)
    if not token then
        self:_log("err", "token generation failed:", err)
        return nil, "random"
    end
    self.token = token
    self.server = Server:new{
        port = self.port,
        handler = self,
        logger = self.logger,
    }
    local ok, bind_err = self.server:start(10)
    if not ok then
        self:_log("err", "server failed to start:", bind_err)
        self.token = nil
        self.server = nil
        return nil, "server"
    end
    self.port = self.server.port
    if self.firewall then
        self.firewall.open(self.port)
        self.firewall_open = true
    end
    self.scheduler:insertZMQ(self.server)
    self.expire_action = function()
        self.expire_action = nil
        self:_log("info", "session expired")
        self:stop("expired")
    end
    self.scheduler:scheduleIn(self.timeout, self.expire_action)
    self.expires_at = os.time() + self.timeout
    self.state = "waiting"
    -- Deliberately not logging the token or full URL.
    self:_log("info", "session started, port", self.port, "timeout", self.timeout, "s")
    return true
end

--- Path component of the upload URL (the part after the host), e.g. "/<token>".
function Session:getPath()
    return self.token and ("/" .. self.token) or nil
end

function Session:isActive()
    return self.state == "waiting" or self.state == "receiving"
end

--- Stops everything and clears the token. Idempotent.
-- @string reason "done" | "cancelled" | "expired" | "suspend" | "exit"
function Session:stop(reason)
    if self.state == "stopped" then return end
    local was_state = self.state
    self.state = "stopped"
    self.stop_reason = reason
    if self.expire_action then
        self.scheduler:unschedule(self.expire_action)
        self.expire_action = nil
    end
    if self.server then
        self.scheduler:removeZMQ(self.server)
        self.server:stop() -- aborts in-flight uploads, deletes temp files
        self.server = nil
    end
    if self.firewall_open then
        self.firewall.close(self.port)
        self.firewall_open = nil
    end
    self.token = nil
    self.active_job = nil
    self:_log("info", "session stopped:", reason or "?", "(was", was_state .. ")")
    if reason == "expired" then
        self:_emit("onExpired")
    end
    self:_emit("onStopped", reason)
end

-- Request routing -----------------------------------------------------------

-- Splits "/<token>/<action>" and validates the token in constant time.
function Session:_route(path)
    local tok, rest = path:match("^/([%w]+)(.*)$")
    if not tok or not self.token or not Security.constantTimeEquals(tok, self.token) then
        return nil
    end
    if self.expires_at and os.time() > self.expires_at then
        return nil
    end
    if rest == "" or rest == "/" then return "page" end
    if rest == "/upload" then return "upload" end
    return "unknown"
end

local function text(status, body)
    return { status = status, body = body }
end

function Session:onHeaders(req)
    if not self:isActive() then
        return text(410, PHONE_MSG.expired)
    end
    local route = self:_route(req.path)
    if not route then
        self.bad_requests = (self.bad_requests or 0) + 1
        self:_log("warn", "rejected request with invalid/expired token (#" .. self.bad_requests .. ")")
        return text(404, PHONE_MSG.expired)
    end
    if route == "page" then
        if req.method ~= "GET" and req.method ~= "HEAD" then return text(405, "Method not allowed.") end
        self:_log("info", "phone connected")
        return {
            status = 200,
            content_type = "text/html; charset=utf-8",
            csp = UploadPage.CSP,
            body = UploadPage.render{
                upload_path = self:getPath() .. "/upload",
                formats = self.format_list,
                max_mb = math.floor(self.max_bytes / (1024 * 1024)),
            },
        }
    end
    if route ~= "upload" then return text(404, "Not found.") end
    if req.method ~= "POST" and req.method ~= "PUT" then return text(405, "Method not allowed.") end
    if self.active_job then return text(409, PHONE_MSG.busy) end

    local filename, why = Security.sanitizeFilename(req.query.name)
    if not filename then
        self:_log("warn", "rejected filename:", why)
        return text(400, PHONE_MSG.bad_name)
    end
    if not self.is_supported(filename) then
        self:_log("info", "rejected unsupported file type:", Security.getExtension(filename))
        self:_emit("onFailed", "unsupported", filename)
        return text(415, PHONE_MSG.unsupported)
    end
    local te = req.headers["transfer-encoding"]
    local len = tonumber(req.headers["content-length"] or "")
    if (te and te:lower() ~= "identity") or not len or len < 0 or len ~= math.floor(len) then
        return text(411, PHONE_MSG.length_required)
    end
    if len == 0 then
        return text(400, PHONE_MSG.corrupt)
    end
    if len > self.max_bytes then
        return text(413, PHONE_MSG.too_large)
    end
    local free = (self.free_space or FS.freeSpace)(self.dest_dir)
    if free and free < len + 1024 * 1024 then -- keep 1 MiB headroom
        self:_log("warn", "not enough space:", len, "bytes needed,", free, "available")
        self:_emit("onFailed", "disk_full", filename)
        return text(507, PHONE_MSG.disk_full)
    end
    local job = UploadJob:new{
        dir = self.dest_dir,
        filename = filename,
        expected_size = len,
        logger = self.logger,
    }
    local ok, err = job:begin()
    if not ok then
        self:_emit("onFailed", err, filename)
        return text(500, PHONE_MSG[err] or PHONE_MSG.io)
    end
    self.active_job = job
    self.state = "receiving"
    self.last_progress_pct = -1
    self:_log("info", "upload started:", len, "bytes, type", job.ext)
    self:_emit("onProgress", filename, 0, len)
    -- Progress is reported from a light wrapper to keep UploadJob UI-agnostic.
    local session = self
    local orig_write = job.write
    job.write = function(j, chunk)
        local r1, r2 = orig_write(j, chunk)
        if r1 then
            local pct = math.floor(j.received * 100 / j.expected_size)
            -- E-ink friendly: report in 10% steps only.
            if pct >= session.last_progress_pct + 10 or pct == 100 then
                session.last_progress_pct = pct - pct % 10
                session:_emit("onProgress", filename, j.received, j.expected_size)
            end
        end
        return r1, r2
    end
    local expect = req.headers["expect"]
    return { upload = job, expect_continue = expect and expect:lower() == "100-continue" }
end

function Session:onUploadDone(req, job)
    self.active_job = nil
    local path, err = job:finish()
    if not path then
        self.state = "waiting"
        self:_log("warn", "validation failed:", err)
        self:_emit("onFailed", err, job.filename)
        return text(err == UploadJob.ERR_DISK_FULL and 507 or 422, PHONE_MSG[err] or PHONE_MSG.io)
    end
    self.received_path = path
    self:_log("info", "upload complete, stored in destination directory")
    -- Stop on the next tick, *after* the server has sent this response.
    self.scheduler:nextTick(function()
        self:stop("done")
        self:_emit("onReceived", path, job.filename)
    end)
    return text(200, PHONE_MSG.done)
end

function Session:onUploadFailed(req, job, reason)
    if self.active_job == job then
        self.active_job = nil
        if self.state == "receiving" then self.state = "waiting" end
    end
    self:_log("warn", "upload failed:", reason)
    if reason ~= "server_stopped" then
        self:_emit("onFailed", reason, job.filename)
    end
    return text(reason == UploadJob.ERR_DISK_FULL and 507 or 500, PHONE_MSG[reason] or PHONE_MSG.incomplete)
end

return Session
