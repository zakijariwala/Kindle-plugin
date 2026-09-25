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
    local events = { progress = {}, failed = {}, received = {}, stopped = {}, finished = {}, expired = 0 }
    local sched = Scheduler.new()
    local o = {
        dest_dir = dest,
        is_supported = isSupported,
        scheduler = sched,
        port = 18080,
        clock = socket.gettime,
        timeout = 60,
        max_bytes = 5 * 1024 * 1024,
        callbacks = {
            onProgress = function(name, got, total, index, count) table.insert(events.progress, { name, got, total, index, count }) end,
            onFinished = function(paths) table.insert(events.finished, paths) end,
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
T.ok(body:find('"' .. path .. '"', 1, true), "page posts to tokenized path")
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
code, body = curl(sched, string.format("-X POST -H 'Content-Type: application/octet-stream' --data-binary @%s '%s%s/upload?name=%s&index=1&count=1'", epub, base, path, urlencode(name)))
T.eq(code, 200, "upload accepted")
T.eq(#ev.received, 1, "UI notified of received book")
T.eq(ev.received[1], dest .. "/" .. name, "stored under sanitized original name")
local f = io.open(dest .. "/" .. name, "rb")
local stored = f and f:read("*a") f = f and f:close()
local fo = io.open(epub, "rb") local orig = fo:read("*a") fo:close()
T.ok(stored == orig, "stored bytes identical to sent bytes")
T.ok(#ev.progress >= 2, "progress reported")
T.eq(ev.progress[#ev.progress][4], 1, "progress carries book index")
T.ok(s:isActive(), "session stays open for more books until the phone finishes")
code, body = curl(sched, string.format("-X POST '%s%s/finish'", base, path))
T.eq(code, 200, "finish accepted")
T.ok(body:find("Book sent successfully", 1, true), "success message")
T.eq(#ev.finished, 1, "UI notified that the batch finished")
T.eq(ev.finished[1] and #ev.finished[1], 1, "finish reports the received books")
T.eq(ev.stopped[#ev.stopped], "done", "session stopped after finish")
T.eq(#sched.zmqs, 0, "server unregistered from main loop")
T.ok(s.token == nil, "token cleared")
T.ok(s.server == nil, "server released")
local c = socket.tcp() c:settimeout(1)
T.ok(not c:connect("127.0.0.1", s.port), "port closed after session ends")
c:close()

-- ---------------------------------------------------------------------------
T.section("several books in one session, duplicate names, old token invalid")
local s2, sched2, ev2 = newSession(dest)
T.ok(s2:start(), "new session starts on same port")
T.ok(s2:getPath() ~= path, "new token differs from old one")
base = "http://127.0.0.1:" .. s2.port
code = curl(sched2, base .. path)
T.eq(code, 404, "old QR/token rejected by new session")
code = curl(sched2, string.format("-X POST --data-binary @%s '%s%s/upload?name=%s&index=1&count=3'", epub, base, s2:getPath(), urlencode(name)))
T.eq(code, 200, "book 1 of 3 (same name as before)")
code = curl(sched2, string.format("-X POST --data-binary @%s '%s%s/upload?name=nope.exe&index=2&count=3'", epub, base, s2:getPath()))
T.eq(code, 415, "book 2 of 3 rejected")
code = curl(sched2, string.format("-X POST -H 'Expect: 100-continue' --data-binary @%s '%s%s/upload?name=My%%20Doc.pdf&index=3&count=3'", pdf, base, s2:getPath()))
T.eq(code, 200, "book 3 of 3 (PDF, Expect: 100-continue)")
T.ok(s2:isActive(), "rejected book does not end the session")
code = curl(sched2, string.format("-X POST '%s%s/finish'", base, s2:getPath()))
T.eq(code, 200, "finish")
T.eq(ev2.received[1], dest .. "/Ünïcödé Bøøk — The Hobbit (2).epub", "existing book not overwritten")
T.eq(ev2.received[2], dest .. "/My Doc.pdf", "PDF stored")
T.eq(ev2.finished[1] and #ev2.finished[1], 2, "two books reported at finish")
T.eq(ev2.stopped[1], "done", "stopped once finished")

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

local s7, sched7, ev7 = newSession(dest, { timeout = 0.3 })
T.ok(s7:start(), "short-lived session starts")
do
    local c7 = socket.tcp() c7:settimeout(2)
    assert(c7:connect("127.0.0.1", s7.port))
    local total = 4 + 2000
    c7:send("POST " .. s7:getPath() .. "/upload?name=slow.epub HTTP/1.1\r\nHost: x\r\nContent-Length: " .. total .. "\r\n\r\nPK\3\4")
    -- trickle the body for ~1.2 s: four times the idle timeout
    for _ = 1, 12 do
        c7:send(string.rep("s", 150))
        local t = socket.gettime() + 0.1
        while socket.gettime() < t do sched7:step() end
    end
    T.ok(s7:isActive() and ev7.expired == 0, "no expiry while a book is arriving")
    c7:send(string.rep("s", 2000 - 12 * 150))
    local reply = ""
    local t = socket.gettime() + 2
    while socket.gettime() < t and not reply:find("\r\n\r\n") do
        sched7:step()
        local d, _, partial = c7:receive(4096)
        c7:settimeout(0)
        reply = reply .. (d or partial or "")
    end
    c7:close()
    T.ok(reply:find("^HTTP/1.1 200"), "slow upload completes after the nominal expiry")
end
local t7 = socket.gettime() + 1.5
while socket.gettime() < t7 do sched7:step() end
T.eq(ev7.expired, 1, "session expires once idle again")

local s6, sched6, ev6 = newSession(dest, { free_space = function() return 100 end })
T.ok(s6:start(), "session starts")
code, body = curl(sched6, string.format("-X POST --data-binary @%s '%s%s/upload?name=x.epub'", epub, "http://127.0.0.1:" .. s6.port, s6:getPath()))
T.eq(code, 507, "insufficient storage reported to phone")
T.ok(body:find("Not enough storage", 1, true), "disk full message")
T.eq(ev6.failed[1], "disk_full", "UI notified: disk full")
s6:stop("cancelled")

T.section("read-only library folder")
do
    local ro = T.tmpdir()
    os.execute('chmod 555 "' .. ro .. '"')
    local s8 = newSession(ro)
    local ok8, why8 = s8:start()
    if io.open(ro .. "/.w", "wb") then -- running as root: permissions are not enforced
        os.remove(ro .. "/.w")
        io.write("  skip read-only check (running as root)\n")
        if ok8 then s8:stop("cancelled") end
    else
        T.ok(not ok8 and why8 == "dest_readonly", "refuses to start: library folder not writable")
    end
    os.execute('chmod 755 "' .. ro .. '"')
end

T.section("plugin mode: one .zip, plugin wording")
do
    local inc = T.tmpdir()
    local zip = makeFile(src, "greeter.koplugin.zip", "PK\3\4" .. string.rep("p", 2048))
    local not_zip = makeFile(src, "fake.zip", "not a zip at all")
    local s9, sched9, ev9 = newSession(inc, {
        kind = "plugin",
        max_files = 1,
        is_supported = function(n) return n:lower():match("%.zip$") ~= nil end,
    })
    T.ok(s9:start(), "plugin session starts")
    local b9, p9 = "http://127.0.0.1:" .. s9.port, s9:getPath()
    local c9, page9 = curl(sched9, b9 .. p9)
    T.eq(c9, 200, "page served")
    T.ok(page9:find("SEND PLUGIN", 1, true) and page9:find("Choose plugin .zip", 1, true), "plugin wording")
    T.ok(not page9:find('type="file" multiple', 1, true), "one file only")
    local c, msg = curl(sched9, string.format("-X POST --data-binary @%s '%s%s/upload?name=book.epub'", epub, b9, p9))
    T.eq(c, 415, "a book is refused")
    T.eq(msg, Session.PLUGIN_MSG.unsupported, "with the plugin message")
    c, msg = curl(sched9, string.format("-X POST --data-binary @%s '%s%s/upload?name=fake.zip'", not_zip, b9, p9))
    T.eq(c, 422, "a .zip that is not a zip is refused")
    T.eq(msg, Session.PLUGIN_MSG.corrupt, "with the plugin message")
    c = curl(sched9, string.format("-X POST --data-binary @%s '%s%s/upload?name=greeter.koplugin.zip'", zip, b9, p9))
    T.eq(c, 200, "plugin zip received")
    T.eq(ev9.received[1], inc .. "/greeter.koplugin.zip", "stored in the incoming folder")
    c, msg = curl(sched9, string.format("-X POST --data-binary @%s '%s%s/upload?name=again.zip'", zip, b9, p9))
    T.eq(c, 409, "a second file is refused")
    T.eq(msg, Session.PLUGIN_MSG.one_only, "one plugin at a time")
    c, msg = curl(sched9, string.format("-X POST '%s%s/finish'", b9, p9))
    T.eq(c, 200, "finish")
    T.eq(msg, Session.PLUGIN_MSG.done, "phone told to confirm on the Kindle")
    T.eq(ev9.finished[1] and #ev9.finished[1], 1, "one file reported at finish")
end

T.section("no leftovers")
local leftovers = 0
for _, n in ipairs(T.listDir(dest)) do if n:match("%.part$") then leftovers = leftovers + 1 end end
T.eq(leftovers, 0, "no temporary files left behind")

T.done()
