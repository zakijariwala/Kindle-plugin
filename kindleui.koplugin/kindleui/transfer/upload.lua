--[[--
One incoming file upload.

Lifecycle:

    UploadJob:new{...}      -- filename already sanitized, extension already accepted
    job:begin()             -- opens a hidden temporary file *in the destination dir*
    job:write(chunk) ...    -- streamed from the socket
    job:finish()            -- size check, format sniff, atomic rename into place
    job:abort(reason)       -- any failure / disconnect: temp file is deleted

Why the temporary file lives in the destination directory rather than /tmp:
on Kindle /tmp is a small RAM-backed tmpfs, and /mnt/us is a different
filesystem, so a rename from /tmp would turn into a slow copy that can fail
half-way. A hidden ".part" file on the same filesystem gives an atomic rename
and never shows up in KOReader's file browser (hidden files are filtered).

@module kindleui.transfer.upload
]]

local FS = require("kindleui/util/filesystem")
local Security = require("kindleui/util/security")

local UploadJob = {}
UploadJob.__index = UploadJob

-- Error codes surfaced to the UI and to the phone.
UploadJob.ERR_DISK_FULL = "disk_full"
UploadJob.ERR_IO = "io"
UploadJob.ERR_INCOMPLETE = "incomplete"
UploadJob.ERR_CORRUPT = "corrupt"
UploadJob.ERR_CANCELLED = "cancelled"

--- @param o table { dir = destination directory, filename = sanitized name,
--                   expected_size = Content-Length, logger = optional }
function UploadJob:new(o)
    assert(o.dir and o.filename and o.expected_size, "UploadJob: missing fields")
    assert(Security.isSafeComponent(o.filename), "UploadJob: unsafe filename")
    o.received = 0
    o.state = "new"
    o.ext = Security.getExtension(o.filename)
    return setmetatable(o, self)
end

function UploadJob:_log(level, ...)
    if self.logger and self.logger[level] then
        self.logger[level]("KindleUI upload:", ...)
    end
end

--- Opens the temporary file. Returns true, or nil + error code.
function UploadJob:begin()
    local suffix, err = Security.randomToken(6)
    if not suffix then
        self:_log("err", "random suffix failed:", err)
        return nil, UploadJob.ERR_IO
    end
    self.temp_path = FS.join(self.dir, ".kindleui-upload-" .. suffix .. ".part")
    local f, open_err = io.open(self.temp_path, "wb")
    if not f then
        self:_log("err", "cannot create temp file:", open_err)
        self.temp_path = nil
        return nil, UploadJob.ERR_IO
    end
    self.file = f
    self.state = "receiving"
    return true
end

--- Appends a chunk. Returns true, or nil + error code (job is aborted).
function UploadJob:write(chunk)
    if self.state ~= "receiving" then return nil, UploadJob.ERR_IO end
    if self.received + #chunk > self.expected_size then
        -- More data than announced: truncate to Content-Length semantics.
        chunk = chunk:sub(1, self.expected_size - self.received)
    end
    local ok, err, code = self.file:write(chunk)
    if not ok then
        -- ENOSPC = 28, EDQUOT = 122
        local reason = (code == 28 or code == 122 or tostring(err):find("space"))
            and UploadJob.ERR_DISK_FULL or UploadJob.ERR_IO
        self:_log("err", "write failed:", err)
        self:abort(reason)
        return nil, reason
    end
    self.received = self.received + #chunk
    return true
end

function UploadJob:isComplete()
    return self.received >= self.expected_size
end

--- Finalizes the upload. Returns the final path, or nil + error code.
function UploadJob:finish()
    if self.state ~= "receiving" then return nil, UploadJob.ERR_IO end
    if not self:isComplete() then
        self:abort(UploadJob.ERR_INCOMPLETE)
        return nil, UploadJob.ERR_INCOMPLETE
    end
    -- flush + close can also hit ENOSPC on buffered data
    local ok_flush, flush_err = self.file:flush()
    local ok_close = self.file:close()
    self.file = nil
    if not ok_flush or not ok_close then
        self:_log("err", "flush/close failed:", flush_err)
        self:abort(UploadJob.ERR_DISK_FULL)
        return nil, UploadJob.ERR_DISK_FULL
    end
    if FS.size(self.temp_path) ~= self.expected_size then
        self:abort(UploadJob.ERR_INCOMPLETE)
        return nil, UploadJob.ERR_INCOMPLETE
    end
    if self.expected_size == 0 or not FS.looksLike(self.temp_path, self.ext) then
        self:_log("warn", "validation failed for extension", self.ext)
        self:abort(UploadJob.ERR_CORRUPT)
        return nil, UploadJob.ERR_CORRUPT
    end
    local final_path = FS.uniquePath(self.dir, self.filename)
    if not final_path then
        self:abort(UploadJob.ERR_IO)
        return nil, UploadJob.ERR_IO
    end
    local ok_rename, rename_err = os.rename(self.temp_path, final_path)
    if not ok_rename then
        self:_log("err", "rename failed:", rename_err)
        self:abort(UploadJob.ERR_IO)
        return nil, UploadJob.ERR_IO
    end
    self.temp_path = nil
    self.final_path = final_path
    self.state = "done"
    self:_log("info", "validated and stored", self.received, "bytes as", final_path)
    return final_path
end

--- Aborts the job and deletes the temporary file. Idempotent.
function UploadJob:abort(reason)
    if self.state == "done" or self.state == "aborted" then return end
    if self.file then
        pcall(self.file.close, self.file)
        self.file = nil
    end
    if self.temp_path then
        FS.removeQuietly(self.temp_path)
        self.temp_path = nil
    end
    self.state = "aborted"
    self.abort_reason = reason or UploadJob.ERR_CANCELLED
    self:_log("info", "aborted:", self.abort_reason, "after", self.received, "bytes")
end

return UploadJob
