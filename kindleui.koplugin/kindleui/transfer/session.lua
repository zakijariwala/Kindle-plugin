--[[--
A single, short-lived transfer session.

A session owns:
  * a cryptographically random token (only valid while the session lives),
  * the temporary HTTP server (registered with the UI main loop),
  * at most one in-flight upload at a time (a phone may send several books
    one after another in the same session).

It ends (server stopped, sockets closed, token cleared) when:
  * the phone reports its batch is finished (POST /<token>/finish),
  * the user cancels,
  * the session has been idle for `timeout` seconds (never while a file is
    arriving: a slow upload is not cut off by the expiry),
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
    received = "Received.",
    done = "Book sent successfully.",
}
Session.PHONE_MSG = PHONE_MSG

-- Replacements when a plugin .zip (not a book) is being sent.
Session.PLUGIN_MSG = {
    unsupported = "Only a plugin .zip file can be sent here.",
    too_large = "This file is too large for a plugin.",
    disk_full = "Not enough storage space to receive this plugin.",
    corrupt = "This is not a valid .zip file.",
    io = "The plugin could not be received.",
    one_only = "Only one plugin can be sent at a time.",
    done = "Plugin sent. Confirm the install on your Kindle.",
}

--- @param o table
--   dest_dir      (string)   where books go (KOReader home folder)
--   is_supported  (function) filename -> bool (KOReader DocumentRegistry)
--   scheduler     (table)    UIManager-like: scheduleIn, unschedule, nextTick, insertZMQ, removeZMQ
--   port          (int)      preferred port
--   timeout       (int)      idle lifetime in seconds (reset by every upload)
--   max_bytes     (int)      largest accepted upload
--   firewall      (table)    optional { open(port), close(port) }
--   callbacks     (table)    onProgress(filename, received, total, index, count),
--                            onReceived(path, filename, index, count, collection),
--                            onFailed(reason, filename), onFinished(paths),
--                            onExpired(), onStopped(reason)
--   kind          (string)   "books" (default) or "plugin" (page wording, phone messages)
--   max_files     (int)      optional: uploads accepted per session
--   collections   (table)    optional { { name, title }, ... }: offered on the phone page;
--                            onReceived gets the chosen collection's name
--   logger        (table)    optional KOReader logger
--   random_source (string)   optional, tests only
function Session:new(o)
    assert(o.dest_dir and o.is_supported and o.scheduler, "Session: missing fields")
    o.port = o.port or 8080
    o.timeout = o.timeout or 15 * 60
    o.max_bytes = o.max_bytes or 500 * 1024 * 1024
    o.callbacks = o.callbacks or {}
    o.clock = o.clock or os.time
    o.kind = o.kind or "books"
    o.state = "new"
    return setmetatable(o, self)
end

function Session:_log(level, ...)
    if self.logger and self.logger[level] then
        self.logger[level]("KindleUI session:", ...)
    end
end

-- Message shown on the phone for `key` (nil if there is none).
function Session:_msg(key)
    if key == nil then return nil end
    return (self.kind == "plugin" and Session.PLUGIN_MSG[key]) or PHONE_MSG[key]
end

function Session:_emit(name, ...)
    local cb = self.callbacks[name]
    if cb then
        local ok, err = pcall(cb, ...)
        if not ok then self:_log("err", "callback", name, "failed:", err) end
    end
end

--- Starts the session. Returns true, or nil + reason
-- ("random" | "server" | "dest_dir" | "dest_readonly").
function Session:start()
    assert(self.state == "new", "Session:start called twice")
    if not FS.isDir(self.dest_dir) then
        self:_log("err", "destination directory missing:", self.dest_dir)
        return nil, "dest_dir"
    end
    if not FS.isWritableDir(self.dest_dir) then
        self:_log("err", "destination directory not writable:", self.dest_dir)
        return nil, "dest_readonly"
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
    self.received = {}
    self:_touch()
    self.expire_action = function()
        self.expire_action = nil
        self:_checkExpiry()
    end
    self.scheduler:scheduleIn(self.timeout, self.expire_action)
    self.state = "waiting"
    -- Deliberately not logging the token or full URL.
    self:_log("info", "session started, port", self.port, "timeout", self.timeout, "s")
    return true
end

-- Pushes the idle deadline back (called on start and on every upload).
function Session:_touch()
    self.expires_at = self.clock() + self.timeout
end

-- Fires at the (old) deadline; re-arms itself while uploads keep it alive.
function Session:_checkExpiry()
    if self.state == "stopped" then return end
    local remaining = (self.expires_at or 0) - self.clock()
    if self.state == "receiving" then
        -- never expire mid-upload: look again a little later
        remaining = math.max(remaining, math.min(self.timeout, 60))
    end
    if remaining > 0 then
        self.expire_action = function()
            self.expire_action = nil
            self:_checkExpiry()
        end
        self.scheduler:scheduleIn(remaining, self.expire_action)
        return
    end
    self:_log("info", "session expired")
    self:stop("expired")
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
    if self.state ~= "receiving" and self.expires_at and self.clock() > self.expires_at then
        return nil
    end
    if rest == "" or rest == "/" then return "page" end
    if rest == "/upload" then return "upload" end
    if rest == "/finish" then return "finish" end
    return "unknown"
end

local function text(status, body)
    return { status = status, body = body }
end

function Session:onHeaders(req)
    if not self:isActive() then
        return text(410, self:_msg("expired"))
    end
    local route = self:_route(req.path)
    if not route then
        self.bad_requests = (self.bad_requests or 0) + 1
        self:_log("warn", "rejected request with invalid/expired token (#" .. self.bad_requests .. ")")
        return text(404, self:_msg("expired"))
    end
    if route == "page" then
        if req.method ~= "GET" and req.method ~= "HEAD" then return text(405, "Method not allowed.") end
        self:_log("info", "phone connected")
        return {
            status = 200,
            content_type = "text/html; charset=utf-8",
            csp = UploadPage.CSP,
            body = UploadPage.render{
                base_path = self:getPath(),
                formats = self.format_list,
                max_mb = math.floor(self.max_bytes / (1024 * 1024)),
                kind = self.kind,
                collections = self.collections,
            },
        }
    end
    if route == "finish" then
        if req.method ~= "POST" then return text(405, "Method not allowed.") end
        if self.active_job then return text(409, self:_msg("busy")) end
        local paths = self.received
        self:_log("info", "phone finished; books received:", #paths)
        -- Stop on the next tick, *after* the server has sent this response.
        self.scheduler:nextTick(function()
            self:stop("done")
            self:_emit("onFinished", paths)
        end)
        return text(200, self:_msg("done"))
    end
    if route ~= "upload" then return text(404, "Not found.") end
    if req.method ~= "POST" and req.method ~= "PUT" then return text(405, "Method not allowed.") end
    if self.active_job then return text(409, self:_msg("busy")) end
    if self.max_files and #self.received >= self.max_files then
        return text(409, self:_msg("one_only") or self:_msg("busy"))
    end

    local filename, why = Security.sanitizeFilename(req.query.name)
    if not filename then
        self:_log("warn", "rejected filename:", why)
        return text(400, self:_msg("bad_name"))
    end
    if not self.is_supported(filename) then
        self:_log("info", "rejected unsupported file type:", Security.getExtension(filename))
        self:_emit("onFailed", "unsupported", filename)
        return text(415, self:_msg("unsupported"))
    end
    local te = req.headers["transfer-encoding"]
    local len = tonumber(req.headers["content-length"] or "")
    if (te and te:lower() ~= "identity") or not len or len < 0 or len ~= math.floor(len) then
        return text(411, self:_msg("length_required"))
    end
    if len == 0 then
        return text(400, self:_msg("corrupt"))
    end
    if len > self.max_bytes then
        return text(413, self:_msg("too_large"))
    end
    local free = (self.free_space or FS.freeSpace)(self.dest_dir)
    if free and free < len + 1024 * 1024 then -- keep 1 MiB headroom
        self:_log("warn", "not enough space:", len, "bytes needed,", free, "available")
        self:_emit("onFailed", "disk_full", filename)
        return text(507, self:_msg("disk_full"))
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
        return text(500, self:_msg(err) or self:_msg("io"))
    end
    self.active_job = job
    self.state = "receiving"
    self.last_progress_pct = -1
    local index = tonumber(req.query.index)
    local count = tonumber(req.query.count)
    job.index, job.count = index, count
    -- A position in our own list; anything else is ignored.
    local pick = tonumber(req.query.collection)
    local coll = pick and self.collections and self.collections[pick]
    job.collection = coll and coll.name or nil
    self:_log("info", "upload started:", len, "bytes, type", job.ext,
        index and count and string.format("(%d of %d)", index, count) or "")
    self:_emit("onProgress", filename, 0, len, index, count)
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
                session:_emit("onProgress", filename, j.received, j.expected_size, j.index, j.count)
            end
        end
        return r1, r2
    end
    local expect = req.headers["expect"]
    return { upload = job, expect_continue = expect and expect:lower() == "100-continue" }
end

function Session:onUploadDone(req, job)
    self.active_job = nil
    self.state = "waiting"
    self:_touch()
    local path, err = job:finish()
    if not path then
        self:_log("warn", "validation failed:", err)
        self:_emit("onFailed", err, job.filename)
        return text(err == UploadJob.ERR_DISK_FULL and 507 or 422, self:_msg(err) or self:_msg("io"))
    end
    table.insert(self.received, path)
    self:_log("info", "upload complete, stored in destination directory")
    self:_emit("onReceived", path, job.filename, job.index, job.count, job.collection)
    return text(200, self:_msg("received"))
end

function Session:onUploadFailed(req, job, reason)
    if self.active_job == job then
        self.active_job = nil
        if self.state == "receiving" then self.state = "waiting" end
    end
    self:_touch()
    self:_log("warn", "upload failed:", reason)
    if reason ~= "server_stopped" then
        self:_emit("onFailed", reason, job.filename)
    end
    return text(reason == UploadJob.ERR_DISK_FULL and 507 or 500, self:_msg(reason) or self:_msg("incomplete"))
end

return Session
