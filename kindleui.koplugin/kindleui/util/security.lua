--[[--
Security helpers for the local transfer service.

Pure Lua (no KOReader dependencies) so it can be unit-tested with a plain
LuaJIT interpreter. See tests/test_security.lua.

@module kindleui.util.security
]]

local Security = {}

local RANDOM_SOURCE = "/dev/urandom"

-- Maximum length (in bytes) of a sanitized filename, extension included.
-- VFAT (the Kindle's /mnt/us) allows 255 UCS-2 chars; stay well below.
Security.MAX_FILENAME_BYTES = 180

--- Reads `nbytes` bytes from the kernel CSPRNG.
-- Never falls back to math.random: if the kernel source is unavailable the
-- caller must refuse to start a transfer session.
-- @int nbytes
-- @treturn string|nil raw bytes
-- @treturn string|nil error message
function Security.randomBytes(nbytes, source)
    local f, err = io.open(source or RANDOM_SOURCE, "rb")
    if not f then
        return nil, "cannot open random source: " .. tostring(err)
    end
    local data = f:read(nbytes)
    f:close()
    if not data or #data ~= nbytes then
        return nil, "short read from random source"
    end
    return data
end

--- Generates a hex-encoded random token.
-- 16 bytes = 128 bits of entropy (32 hex characters): unguessable, and short
-- enough to keep the QR code at a low, easily scannable density.
-- @int[opt=16] nbytes
-- @treturn string|nil token
-- @treturn string|nil error message
function Security.randomToken(nbytes, source)
    local raw, err = Security.randomBytes(nbytes or 16, source)
    if not raw then return nil, err end
    return (raw:gsub(".", function(c) return string.format("%02x", c:byte()) end))
end

--- Compares two strings in time independent of where they first differ.
-- @treturn bool
function Security.constantTimeEquals(a, b)
    if type(a) ~= "string" or type(b) ~= "string" then return false end
    if #a ~= #b then return false end
    local diff = 0
    for i = 1, #a do
        -- bit ops are not available in plain Lua 5.1; use arithmetic difference
        local d = a:byte(i) - b:byte(i)
        if d ~= 0 then diff = diff + 1 end
    end
    return diff == 0
end

--- Returns true if `s` is well-formed UTF-8 (no overlongs, no surrogates).
function Security.isValidUtf8(s)
    local i, n = 1, #s
    while i <= n do
        local c = s:byte(i)
        local len
        if c < 0x80 then
            len = 1
        elseif c >= 0xC2 and c <= 0xDF then
            len = 2
        elseif c >= 0xE0 and c <= 0xEF then
            len = 3
        elseif c >= 0xF0 and c <= 0xF4 then
            len = 4
        else
            return false
        end
        if i + len - 1 > n then return false end
        for j = i + 1, i + len - 1 do
            local cc = s:byte(j)
            if cc < 0x80 or cc > 0xBF then return false end
        end
        if len == 3 then
            local c2 = s:byte(i + 1)
            if c == 0xE0 and c2 < 0xA0 then return false end -- overlong
            if c == 0xED and c2 > 0x9F then return false end -- surrogates
        elseif len == 4 then
            local c2 = s:byte(i + 1)
            if c == 0xF0 and c2 < 0x90 then return false end -- overlong
            if c == 0xF4 and c2 > 0x8F then return false end -- > U+10FFFF
        end
        i = i + len
    end
    return true
end

-- Truncates a UTF-8 string to at most `max` bytes without splitting a character.
local function truncateUtf8(s, max)
    if #s <= max then return s end
    local cut = max
    -- step back while the byte after the cut is a continuation byte
    while cut > 0 do
        local nb = s:byte(cut + 1)
        if not nb or nb < 0x80 or nb > 0xBF then break end
        cut = cut - 1
    end
    return s:sub(1, cut)
end

--- Returns the lower-cased extension of a filename (without the dot), or nil.
function Security.getExtension(name)
    if type(name) ~= "string" then return nil end
    local ext = name:match("%.([^%./\\]+)$")
    return ext and ext:lower() or nil
end

--- Sanitizes an untrusted, browser-supplied filename.
--
-- The result is a plain file *name* (never a path) that is safe to join with
-- the destination directory. Anything that looks like a path is rejected
-- rather than "repaired", because a browser never legitimately sends one.
--
-- @string raw untrusted filename
-- @treturn string|nil sanitized name
-- @treturn string|nil rejection reason (machine-readable)
function Security.sanitizeFilename(raw)
    if type(raw) ~= "string" or raw == "" then
        return nil, "empty"
    end
    if raw:find("%z") then
        return nil, "null_byte"
    end
    if raw:find("[/\\]") then
        -- absolute paths, traversal (../) and Windows paths all land here
        return nil, "path_separator"
    end
    if not Security.isValidUtf8(raw) then
        return nil, "invalid_utf8"
    end
    local name = raw
    -- control characters (C0 + DEL) become spaces
    name = name:gsub("[%c\127]", " ")
    -- characters that are invalid on VFAT (Kindle user storage is VFAT)
    name = name:gsub('[:*?"<>|]', "_")
    -- collapse whitespace runs
    name = name:gsub("%s+", " ")
    -- no hidden files, no "." / ".." and no leading/trailing junk
    name = name:gsub("^[%s%.]+", "")
    name = name:gsub("[%s%.]+$", "")
    if name == "" then
        return nil, "empty"
    end
    local ext = Security.getExtension(name)
    if not ext or #ext > 10 then
        return nil, "no_extension"
    end
    if #name > Security.MAX_FILENAME_BYTES then
        local base = name:sub(1, #name - #ext - 1)
        base = truncateUtf8(base, Security.MAX_FILENAME_BYTES - #ext - 1)
        base = base:gsub("[%s%.]+$", "")
        if base == "" then return nil, "empty" end
        name = base .. "." .. ext
    end
    return name
end

--- Returns true if `name` is a single safe path component.
function Security.isSafeComponent(name)
    return type(name) == "string" and name ~= "" and name ~= "." and name ~= ".."
        and not name:find("[/\\%z]")
end

return Security
