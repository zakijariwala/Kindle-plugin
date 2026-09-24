-- End-to-end tests of the transfer session: a real LuaSocket server on
-- localhost, driven by a fake UIManager loop, with curl acting as the phone.
local T = require("harness")
local socket = require("socket")
local Session = require("kindleui/transfer/session")

-- Minimal stand-in for KOReader's UIManager (only what Session uses).
local Scheduler = {}
Scheduler.__index = Scheduler
function Scheduler.new() return setmetatable({ zmqs = {}, tasks = {} }, Scheduler) end
function Scheduler:insertZMQ(z) table.insert(self.zmqs, z) return z end
function Scheduler:removeZMQ(z)
    for i = #self.zmqs, 1, -1 do if self.zmqs[i] == z then table.remove(self.zmqs, i) end end
end
function Scheduler:scheduleIn(sec, fn) table.insert(self.tasks, { at = socket.gettime() + sec, fn = fn }) end
function Scheduler:nextTick(fn) self:scheduleIn(0, fn) end
function Scheduler:unschedule(fn)
    for i = #self.tasks, 1, -1 do if self.tasks[i].fn == fn then table.remove(self.tasks, i) end end
end
function Scheduler:step()
    for _, z in ipairs(self.zmqs) do z:waitEvent() end
    local now = socket.gettime()
    local due = {}
    for i = #self.tasks, 1, -1 do
        if self.tasks[i].at <= now then table.insert(due, table.remove(self.tasks, i)) end
    end
    for _, t in ipairs(due) do t.fn() end
    socket.sleep(0.005)
end

local SUPPORTED = { epub = true, pdf = true, mobi = true, txt = true }
local function isSupported(name)
    local ext = name:match("%.([^%.]+)$")
    return ext and SUPPORTED[ext:lower()] or false
end

local function newSession(dest, extra)
    local events = { progress = {}, failed = {}, received = {}, stopped = {}, expired = 0 }
    local sched = Scheduler.new()
    local o = {
        dest_dir = dest,
        is_supported = isSupported,
        scheduler = sched,
        port = 18080,
        timeout = 60,
        max_bytes = 5 * 1024 * 1024,
        callbacks = {
            onProgress = function(name, got, total) table.insert(events.progress, { name, got, total }) end,
            onFailed = function(reason, name) table.insert(events.failed, reason) end,
            onReceived = function(path, name) table.insert(events.received, path) end,
            onStopped = function(reason) table.insert(events.stopped, reason) end,
            onExpired = function() events.expired = events.expired + 1 end,
        },
    }
    for k, v in pairs(extra or {}) do o[k] = v end
    local s = Session:new(o)
    return s, sched, events
end

-- Runs a shell command in the background while pumping the fake main loop.
local run_id = 0
local function curl(sched, args, max_seconds)
    run_id = run_id + 1
    local out = os.tmpname()
    local done = out .. ".done"
    os.execute(string.format("(curl -s -S -m %d -o %s -w '%%{http_code}' %s > %s.code 2>%s.err; touch %s) &",
        max_seconds or 20, out, args, out, out, done))
    local deadline = socket.gettime() + (max_seconds or 20) + 5
    while socket.gettime() < deadline do
        sched:step()
        local f = io.open(done, "r")
        if f then f:close() break end
    end
    for _ = 1, 20 do sched:step() end -- let nextTick tasks run
    local function slurp(p) local f = io.open(p, "rb") if not f then return "" end local d = f:read("*a") f:close() os.remove(p) return d end
    local body, code, err = slurp(out), slurp(out .. ".code"), slurp(out .. ".err")
    os.remove(done)
    return tonumber(code), body, err
end

local function makeFile(dir, name, content)
    local p = dir .. "/" .. name
    local f = io.open(p, "wb") f:write(content) f:close()
    return p
end

local function urlencode(s)
    return (s:gsub("[^%w%-%._~]", function(c) return string.format("%%%02X", c:byte()) end))
end

local src = T.tmpdir()
local epub = makeFile(src, "book.epub", "PK\3\4" .. string.rep("x", 300 * 1024))
local pdf = makeFile(src, "doc.pdf", "%PDF-1.4\n" .. string.rep("y", 1024))
local fake_epub = makeFile(src, "fake.epub", "<html>not a zip</html>")
local big = makeFile(src, "big.pdf", "%PDF-1.4\n" .. string.rep("z", 6 * 1024 * 1024))

-- ---------------------------------------------------------------------------
T.section("session start / page / token")
local dest = T.tmpdir()
local s, sched, ev = newSession(dest)
T.ok(s:start(), "session starts")
T.eq(#sched.zmqs, 1, "server registered with main loop")
local base = "http://127.0.0.1:" .. s.port
local path = s:getPath()
T.ok(path and #path == 33, "URL path is /<32-hex token>")

local code, body = curl(sched, base .. path)
T.eq(code, 200, "GET upload page with valid token")
T.ok(body:find("SEND TO KINDLE", 1, true), "page contains title")
T.ok(body:find(path .. "/upload", 1, true), "page posts to tokenized path")
T.ok(not body:find("https?://%w"), "page references no external URL")

code = curl(sched, base .. "/00000000000000000000000000000000")
T.eq(code, 404, "invalid token rejected")
code = curl(sched, base .. "/")
T.eq(code, 404, "root without token rejected")
code = curl(sched, base .. path:sub(1, -2))
T.eq(code, 404, "truncated token rejected")
code = curl(sched, string.format("-X POST --data-binary @%s '%s/0000/upload?name=a.epub'", epub, base))
T.eq(code, 404, "upload with invalid token rejected")

-- ---------------------------------------------------------------------------
T.section("rejections before any byte is stored")
code, body = curl(sched, string.format("-X POST --data-binary @%s '%s%s/upload?name=%s'", epub, base, path, urlencode("../../evil.epub")))
T.eq(code, 400, "path traversal filename rejected")
code = curl(sched, string.format("-X POST --data-binary @%s '%s%s/upload?name=%s'", epub, base, path, urlencode("/etc/passwd")))
T.eq(code, 400, "absolute path rejected")
code = curl(sched, string.format("-X POST --data-binary @%s '%s%s/upload?name=%s'", epub, base, path, "a%00b.epub"))
T.eq(code, 400, "null byte rejected")
code, body = curl(sched, string.format("-X POST --data-binary @%s '%s%s/upload?name=%s'", epub, base, path, "virus.exe"))
T.eq(code, 415, "unsupported extension rejected")
T.ok(body:find("Unsupported file type", 1, true), "unsupported message sent to phone")
code = curl(sched, string.format("-X POST -H 'Transfer-Encoding: chunked' --data-binary @%s '%s%s/upload?name=a.epub'", epub, base, path))
T.eq(code, 411, "chunked upload without length rejected")
code = curl(sched, string.format("-X POST --data-binary @%s '%s%s/upload?name=big.pdf'", big, base, path))
T.eq(code, 413, "oversized upload rejected")
code = curl(sched, string.format("-X GET '%s%s/upload?name=a.epub'", base, path))
T.eq(code, 405, "GET on upload endpoint rejected")
T.eq(#T.listDir(dest), 0, "destination still empty")

-- ---------------------------------------------------------------------------
T.section("corrupt upload")
code, body = curl(sched, string.format("-X POST --data-binary @%s '%s%s/upload?name=fake.epub'", fake_epub, base, path))
T.eq(code, 422, "fake EPUB rejected after validation")
T.eq(#T.listDir(dest), 0, "no half file left in library")
T.ok(s:isActive(), "session still active after a failed upload")

-- ---------------------------------------------------------------------------
T.section("interrupted upload")
-- Send headers announcing 100000 bytes, then only 10 bytes, then disconnect.
do
    local c = socket.tcp()
    c:settimeout(2)
    assert(c:connect("127.0.0.1", s.port))
    c:send("POST " .. path .. "/upload?name=cut.epub HTTP/1.1\r\nHost: x\r\nContent-Length: 100000\r\n\r\nPK\3\4" .. "012345")
    for _ = 1, 30 do sched:step() end
    local n = 0
    for _, name in ipairs(T.listDir(dest)) do if name:match("^%.kindleui%-upload%-.*%.part$") then n = n + 1 end end
    T.eq(n, 1, "temporary .part file exists while receiving")
    c:close()
    for _ = 1, 30 do sched:step() end
end
T.eq(#T.listDir(dest), 0, "temporary file removed after disconnect")
T.eq(ev.failed[#ev.failed], "cancelled", "UI notified: upload cancelled")
T.ok(s:isActive(), "session survives an interrupted upload")

-- ---------------------------------------------------------------------------
T.section("successful EPUB upload (unicode + spaces)")
local name = "Ünïcödé Bøøk — The Hobbit.epub"
code, body = curl(sched, string.format("-X POST -H 'Content-Type: application/octet-stream' --data-binary @%s '%s%s/upload?name=%s'", epub, base, path, urlencode(name)))
T.eq(code, 200, "upload accepted")
T.ok(body:find("Book sent successfully", 1, true), "success message")
T.eq(#ev.received, 1, "UI notified of received book")
T.eq(ev.received[1], dest .. "/" .. name, "stored under sanitized original name")
local f = io.open(dest .. "/" .. name, "rb")
local stored = f and f:read("*a") f = f and f:close()
local fo = io.open(epub, "rb") local orig = fo:read("*a") fo:close()
T.ok(stored == orig, "stored bytes identical to sent bytes")
T.ok(#ev.progress >= 2, "progress reported")
T.eq(ev.stopped[#ev.stopped], "done", "session stopped after success")
T.eq(#sched.zmqs, 0, "server unregistered from main loop")
T.ok(s.token == nil, "token cleared")
T.ok(s.server == nil, "server released")
local c = socket.tcp() c:settimeout(1)
T.ok(not c:connect("127.0.0.1", s.port), "port closed after session ends")
c:close()

-- ---------------------------------------------------------------------------
T.section("repeat transfer, duplicate names, old token invalid")
local s2, sched2, ev2 = newSession(dest)
T.ok(s2:start(), "new session starts on same port")
T.ok(s2:getPath() ~= path, "new token differs from old one")
base = "http://127.0.0.1:" .. s2.port
code = curl(sched2, base .. path)
T.eq(code, 404, "old QR/token rejected by new session")
code = curl(sched2, string.format("-X POST --data-binary @%s '%s%s/upload?name=%s'", epub, base, s2:getPath(), urlencode(name)))
T.eq(code, 200, "same name uploaded again")
T.eq(ev2.received[1], dest .. "/Ünïcödé Bøøk — The Hobbit (2).epub", "existing book not overwritten")

-- ---------------------------------------------------------------------------
T.section("PDF upload + Expect: 100-continue")
local s3, sched3, ev3 = newSession(dest)
T.ok(s3:start(), "session starts")
base = "http://127.0.0.1:" .. s3.port
code = curl(sched3, string.format("-X POST -H 'Expect: 100-continue' --data-binary @%s '%s%s/upload?name=My%%20Doc.pdf'", pdf, base, s3:getPath()))
T.eq(code, 200, "PDF accepted")
T.eq(ev3.received[1], dest .. "/My Doc.pdf", "PDF stored")

-- ---------------------------------------------------------------------------
T.section("cancel / expiry / disk full")
local s4, sched4, ev4 = newSession(dest)
T.ok(s4:start(), "session starts")
local p4 = s4.port
s4:stop("cancelled")
T.eq(#sched4.zmqs, 0, "cancel unregisters server")
T.eq(#sched4.tasks, 0, "cancel unschedules expiry timer")
c = socket.tcp() c:settimeout(1)
T.ok(not c:connect("127.0.0.1", p4), "cancel closes the port")
c:close()
s4:stop("cancelled")
T.eq(#ev4.stopped, 1, "stop is idempotent")

local s5, sched5, ev5 = newSession(dest, { timeout = 0.3 })
T.ok(s5:start(), "short-lived session starts")
local p5 = s5:getPath()
local t_end = socket.gettime() + 1
while socket.gettime() < t_end do sched5:step() end
T.eq(ev5.expired, 1, "session expired")
T.ok(not s5:isActive() and s5.token == nil, "expired session cleared token")
T.eq(#sched5.zmqs, 0, "expired session stopped server")

local s6, sched6, ev6 = newSession(dest, { free_space = function() return 100 end })
T.ok(s6:start(), "session starts")
code, body = curl(sched6, string.format("-X POST --data-binary @%s '%s%s/upload?name=x.epub'", epub, "http://127.0.0.1:" .. s6.port, s6:getPath()))
T.eq(code, 507, "insufficient storage reported to phone")
T.ok(body:find("Not enough storage", 1, true), "disk full message")
T.eq(ev6.failed[1], "disk_full", "UI notified: disk full")
s6:stop("cancelled")

T.section("no leftovers")
local leftovers = 0
for _, n in ipairs(T.listDir(dest)) do if n:match("%.part$") then leftovers = leftovers + 1 end end
T.eq(leftovers, 0, "no temporary files left behind")

T.done()
