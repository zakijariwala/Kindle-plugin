--[[--
Cover/metadata extraction in a child process.

Opening documents inside KOReader's own process makes its document engines
keep memory that is never given back: measured in the emulator at about
1.6 MB per distinct book (+245 MB after 150 books), which a Kindle cannot
afford. So, like KOReader's Cover browser plugin, extraction runs in a forked
child (`ffiUtil.runInSubProcess`) whose memory disappears when it exits. It
also keeps the UI responsive while covers are being extracted.

Protocol: the child extracts each item (writing the thumbnail file itself)
and writes one line per book to a pipe:
    <index> TAB <title> TAB <authors> TAB <cover file> TAB <1|0> LF
The parent polls the pipe (only while a job runs) and merges each line into
the cache entry.

    local job = Extractor.start(items, { onResult = fn(item), onDone = fn() })
    job:cancel()

@module kindleui.util.extractor
]]

local Cache = require("kindleui/util/librarycache")
local UIManager = require("ui/uimanager")
local ffi = require("ffi")
local ffiUtil = require("ffi/util")
local logger = require("logger")
require("ffi/posix_h")

local C = ffi.C
local POLL_INTERVAL = 0.25 -- seconds, only while a job is running

local Extractor = {}

local function clean(s)
    if s == nil then return "" end
    return (tostring(s):gsub("[\t\r\n]", " "))
end

local Job = {}
Job.__index = Job

--- Starts extracting `items` = { { path, entry, w, h }, ... } in a child process.
-- Returns a job (with :cancel()), or nil if nothing to do / fork failed.
function Extractor.start(items, callbacks)
    if not items or #items == 0 then return nil end
    local pid, fd = ffiUtil.runInSubProcess(function(__, write_fd)
        for i, it in ipairs(items) do
            local e = {}
            Cache.extract(it.path, e, it.w, it.h)
            local line = table.concat({
                tostring(i), clean(e.title), clean(e.authors), e.cover or "", e.extracted and "1" or "0",
            }, "\t") .. "\n"
            if not ffiUtil.writeToFD(write_fd, line) then break end -- parent gone
        end
        C.close(write_fd)
    end, true)
    if not pid then
        logger.warn("KindleUI: could not start cover extraction:", fd)
        return nil
    end
    local job = setmetatable({
        pid = pid,
        fd = fd,
        items = items,
        callbacks = callbacks or {},
        buf = "",
        done = 0,
    }, Job)
    job.poll = function() job:_poll() end
    UIManager:scheduleIn(POLL_INTERVAL, job.poll)
    return job
end

function Job:_apply(line)
    local idx, title, authors, cover, ok = line:match("^(%d+)\t([^\t]*)\t([^\t]*)\t([^\t]*)\t([01])$")
    local item = idx and self.items[tonumber(idx)]
    if not item then return end
    local e = item.entry
    if title ~= "" and not e.title then
        e.title = title
        e.authors = authors ~= "" and authors or nil
    end
    e.cover = cover ~= "" and cover or nil
    e.extracted = ok == "1"
    Cache.dirty = true
    self.done = self.done + 1
    if self.callbacks.onResult then
        local okc, err = pcall(self.callbacks.onResult, item)
        if not okc then logger.warn("KindleUI: extraction callback failed:", err) end
    end
end

function Job:_consume(data)
    self.buf = self.buf .. data
    while true do
        local nl = self.buf:find("\n", 1, true)
        if not nl then break end
        local line = self.buf:sub(1, nl - 1)
        self.buf = self.buf:sub(nl + 1)
        self:_apply(line)
    end
end

function Job:_readAvailable()
    local n = ffiUtil.getNonBlockingReadSize(self.fd)
    if n and n > 0 then
        local buffer = ffi.new("char[?]", n)
        local got = tonumber(C.read(self.fd, buffer, n))
        if got and got > 0 then
            self:_consume(ffi.string(buffer, got))
        end
    end
end

function Job:_poll()
    if self.cancelled then return end
    self:_readAvailable()
    if ffiUtil.isSubProcessDone(self.pid) then
        -- child exited: drain whatever is left (does not block: write end is closed)
        self:_consume(ffiUtil.readAllFromFD(self.fd))
        self.fd = nil
        self.finished = true
        Cache.save()
        if self.callbacks.onDone then pcall(self.callbacks.onDone, self) end
        return
    end
    UIManager:scheduleIn(POLL_INTERVAL, self.poll)
end

--- Stops the job: kills the child, closes the pipe, stops polling. Idempotent.
function Job:cancel()
    if self.cancelled or self.finished then return end
    self.cancelled = true
    UIManager:unschedule(self.poll)
    ffiUtil.terminateSubProcess(self.pid)
    if self.fd then
        C.close(self.fd)
        self.fd = nil
    end
    Cache.save()
    -- Reap the killed child so it does not linger as a zombie.
    local pid = self.pid
    local function reap()
        if not ffiUtil.isSubProcessDone(pid) then
            UIManager:scheduleIn(1, reap)
        end
    end
    UIManager:scheduleIn(0.5, reap)
end

return Extractor
