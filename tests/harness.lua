-- Tiny test harness (no dependencies) for running plugin modules under LuaJIT.
local H = { passed = 0, failed = 0, tmpdirs = {} }

function H.section(name)
    io.write("\n== ", name, "\n")
end

function H.ok(cond, msg)
    if cond then
        H.passed = H.passed + 1
        io.write("  ok   ", msg, "\n")
    else
        H.failed = H.failed + 1
        io.write("  FAIL ", msg, "\n")
    end
end

function H.eq(got, want, msg)
    H.ok(got == want, msg .. (got == want and "" or (" (got " .. tostring(got) .. ", want " .. tostring(want) .. ")")))
end

function H.tmpdir()
    local p = io.popen("mktemp -d")
    local d = p:read("*l")
    p:close()
    table.insert(H.tmpdirs, d)
    return d
end

function H.listDir(dir)
    local p = io.popen('ls -A "' .. dir .. '"')
    local t = {}
    for l in p:lines() do table.insert(t, l) end
    p:close()
    return t
end

function H.done()
    for _, d in ipairs(H.tmpdirs) do os.execute('rm -rf "' .. d .. '"') end
    io.write(string.format("\n%d passed, %d failed\n", H.passed, H.failed))
    os.exit(H.failed == 0 and 0 or 1)
end

return H
