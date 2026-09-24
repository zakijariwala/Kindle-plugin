--[[--
Small filesystem helpers used by the transfer layer.

Works both inside KOReader (uses its bundled lfs and ffi/util) and under a
plain LuaJIT interpreter for tests (falls back to io.open probing).

@module kindleui.util.filesystem
]]

local Security = require("kindleui/util/security")

local FS = {}

local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
if not ok_lfs then
    ok_lfs, lfs = pcall(require, "lfs")
end
if not ok_lfs then lfs = nil end

--- Returns the lfs mode of `path` ("file", "directory", ...) or nil.
function FS.mode(path)
    if lfs then
        return lfs.attributes(path, "mode")
    end
    local f = io.open(path, "rb")
    if not f then return nil end
    local code = select(3, f:read(0))
    f:close()
    -- EISDIR (21) when reading a directory
    if code == 21 then return "directory" end
    return "file"
end

function FS.exists(path)
    return FS.mode(path) ~= nil
end

function FS.isDir(path)
    return FS.mode(path) == "directory"
end

--- True if files can be created in `dir` (probes with a hidden temp file).
function FS.isWritableDir(dir)
    local probe = dir .. "/.kindleui-probe"
    local f = io.open(probe, "wb")
    if not f then return false end
    f:close()
    os.remove(probe)
    return true
end

--- Returns the size of a regular file, or nil.
function FS.size(path)
    if lfs then
        return lfs.attributes(path, "size")
    end
    local f = io.open(path, "rb")
    if not f then return nil end
    local size = f:seek("end")
    f:close()
    return size
end

--- Removes a file, ignoring errors. Returns true if it is gone.
function FS.removeQuietly(path)
    if not path then return true end
    os.remove(path)
    return not FS.exists(path)
end

--- Free space (bytes) available to unprivileged users on the filesystem that
-- holds `path`, or nil if unknown.
function FS.freeSpace(path)
    local ok, ffiUtil = pcall(require, "ffi/util")
    if ok and ffiUtil and ffiUtil.df then
        local ok_df, _, _, available = pcall(ffiUtil.df, path)
        if ok_df and available then return tonumber(available) end
    end
    return nil
end

-- Exact name pattern of our upload temp files (see transfer/upload.lua).
FS.TEMP_PATTERN = "^%.kindleui%-upload%-%x+%.part$"

--- Deletes upload temp files left behind by a crash or power loss mid-upload.
-- Only files matching FS.TEMP_PATTERN directly inside `dir` are touched.
-- Must only be called while no transfer session is running.
-- @treturn int number of files removed
function FS.removeStaleUploads(dir)
    if not lfs or not dir then return 0 end
    local ok, iter, dir_obj = pcall(lfs.dir, dir)
    if not ok then return 0 end
    local removed = 0
    for name in iter, dir_obj do
        if name:match(FS.TEMP_PATTERN) then
            local path = dir .. "/" .. name
            if lfs.attributes(path, "mode") == "file" and os.remove(path) then
                removed = removed + 1
            end
        end
    end
    return removed
end

--- Joins a directory and a *single* sanitized component.
-- Refuses anything that is not a plain file name.
function FS.join(dir, name)
    assert(Security.isSafeComponent(name), "unsafe path component")
    if dir:sub(-1) == "/" then
        return dir .. name
    end
    return dir .. "/" .. name
end

--- Returns a path in `dir` for `name` that does not exist yet:
-- "Book.epub", then "Book (2).epub", "Book (3).epub", ...
function FS.uniquePath(dir, name)
    local candidate = FS.join(dir, name)
    if not FS.exists(candidate) then return candidate end
    local base, ext = name:match("^(.*)%.([^%.]+)$")
    if not base then base, ext = name, nil end
    for i = 2, 999 do
        local alt = ext and string.format("%s (%d).%s", base, i, ext) or string.format("%s (%d)", base, i)
        candidate = FS.join(dir, alt)
        if not FS.exists(candidate) then return candidate end
    end
    return nil
end

-- Light "magic number" checks. This is only a first line of defence against
-- obviously wrong/corrupt uploads; KOReader's document engines remain
-- responsible for actually parsing the file.
local ZIP_MAGIC = "PK\3\4"
local MAGIC = {
    epub = function(head) return head:sub(1, 4) == ZIP_MAGIC end,
    cbz  = function(head) return head:sub(1, 4) == ZIP_MAGIC end,
    docx = function(head) return head:sub(1, 4) == ZIP_MAGIC end,
    odt  = function(head) return head:sub(1, 4) == ZIP_MAGIC end,
    zip  = function(head) return head:sub(1, 4) == ZIP_MAGIC end,
    pdf  = function(head) return head:find("%PDF-", 1, true) ~= nil end, -- may follow a few junk bytes
    djvu = function(head) return head:sub(1, 8) == "AT&TFORM" end,
    djv  = function(head) return head:sub(1, 8) == "AT&TFORM" end,
    mobi = function(head) local t = head:sub(61, 68) return t == "BOOKMOBI" or t == "TEXtREAd" end,
    azw  = function(head) local t = head:sub(61, 68) return t == "BOOKMOBI" or t == "TEXtREAd" end,
    azw3 = function(head) local t = head:sub(61, 68) return t == "BOOKMOBI" end,
    prc  = function(head) local t = head:sub(61, 68) return t == "BOOKMOBI" or t == "TEXtREAd" end,
}

--- Checks the leading bytes of `path` against the expected format of `ext`.
-- Unknown extensions are accepted (KOReader decides).
-- @treturn bool
function FS.looksLike(path, ext)
    local check = MAGIC[ext]
    if not check then return true end
    local f = io.open(path, "rb")
    if not f then return false end
    local head = f:read(1024) or ""
    f:close()
    return check(head)
end

return FS
