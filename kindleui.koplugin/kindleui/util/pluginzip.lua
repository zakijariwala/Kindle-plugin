--[[--
Understanding a plugin .zip before anything is installed.

Pure Lua (no KOReader dependencies): works on a list of archive entries
`{ path = "a/b.lua", mode = "file"|"directory"|"link"|..., size = n }`, so it
is unit-tested without KOReader (tests/test_pluginzip.lua).

What it decides:
  * where the plugin folder is inside the zip (any depth), under which name;
  * which entries to extract: only that folder, minus junk (macOS/Windows
    metadata, .git), never anything outside it;
  * whether the zip is acceptable at all: no absolute or ".." paths, no
    symbolic links / devices, within size and file-count limits;
  * the plugin's display name and description, read from _meta.lua *as text*
    (never executed before the user confirms).

@module kindleui.util.pluginzip
]]

local PluginZip = {
    MAX_UNPACKED_BYTES = 50 * 1024 * 1024,
    MAX_FILES = 5000,
}

-- Junk that is skipped inside the plugin folder (never extracted).
local JUNK_COMPONENTS = {
    ["__MACOSX"] = true, [".DS_Store"] = true, ["Thumbs.db"] = true,
    ["desktop.ini"] = true, [".git"] = true, [".github"] = true,
}

--- True if any component of `rel` is junk (or an AppleDouble "._x" file).
function PluginZip.isJunk(rel)
    for part in rel:gmatch("[^/]+") do
        if JUNK_COMPONENTS[part] or part:sub(1, 2) == "._" then return true end
    end
    return false
end

--- A path we refuse outright: absolute, Windows drive, "..", or backslashes.
function PluginZip.isUnsafePath(path)
    if path:sub(1, 1) == "/" or path:match("^%a:") or path:find("\\", 1, true) then return true end
    for part in path:gmatch("[^/]+") do
        if part == ".." then return true end
    end
    return false
end

--- Valid plugin folder name: "<name>.koplugin", plain characters, not hidden.
function PluginZip.validName(name)
    return type(name) == "string" and name:match("^[%w][%w_%-%.]*%.koplugin$") ~= nil
end

local function dirname(path)
    return path:match("^(.*)/[^/]*$") or ""
end

local function basename(path)
    return path:match("([^/]+)/?$") or path
end

--- Finds the plugin folder(s) in a zip.
-- A folder qualifies when it directly contains main.lua and _meta.lua and is
--   * named "<name>.koplugin"            (the usual layout), or
--   * named "<name>.koplugin-<branch>"   (GitHub "Download ZIP" of a repo
--                                         itself named <name>.koplugin), or
--   * the zip's only top folder / root, when the zip file itself is named
--     "<name>.koplugin.zip".
-- @param entries array of { path, mode, size }
-- @string zip_name the uploaded file name (for the last case)
-- @treturn table array of { root = "prefix/in/zip", name = "<name>.koplugin" }
function PluginZip.findPlugins(entries, zip_name)
    local files = {}
    for __, e in ipairs(entries) do
        if e.mode == "file" then files[e.path] = true end
    end
    local found, seen = {}, {}
    for path in pairs(files) do
        if basename(path) == "main.lua" then
            local root = dirname(path)
            local prefix = root == "" and "" or (root .. "/")
            if files[prefix .. "_meta.lua"] and not seen[root] and not PluginZip.isJunk(root) then
                local folder = basename(root)
                local name
                if folder:match("%.koplugin$") then
                    name = folder
                else
                    name = folder:match("^(.+%.koplugin)%-[%w%._%-]+$")
                end
                if not name and zip_name and (root == "" or not root:find("/")) then
                    name = zip_name:match("^(.+%.koplugin)%.zip$")
                end
                if name and PluginZip.validName(name) then
                    seen[root] = true
                    table.insert(found, { root = root, name = name })
                end
            end
        end
    end
    table.sort(found, function(a, b) return a.root < b.root end)
    return found
end

--- Checks the whole archive and lists what to extract for one plugin root.
-- @treturn table|nil { { path = entry path, rel = path inside plugin, mode }, ... }
-- @treturn string|nil error key: "unsafe_path" | "link" | "too_big" | "too_many" | "empty"
function PluginZip.plan(entries, root)
    local prefix = root == "" and "" or (root .. "/")
    local out, bytes = {}, 0
    for __, e in ipairs(entries) do
        -- Refuse archives with dangerous entries anywhere, not just in the plugin.
        if PluginZip.isUnsafePath(e.path) then return nil, "unsafe_path" end
        if e.mode ~= "file" and e.mode ~= "directory" then return nil, "link" end
        if e.path:sub(1, #prefix) == prefix then
            local rel = e.path:sub(#prefix + 1):gsub("/$", "")
            if rel ~= "" and not PluginZip.isJunk(rel) then
                table.insert(out, { path = e.path, rel = rel, mode = e.mode })
                bytes = bytes + (tonumber(e.size) or 0)
            end
        end
    end
    if #out == 0 then return nil, "empty" end
    if #out > PluginZip.MAX_FILES then return nil, "too_many" end
    if bytes > PluginZip.MAX_UNPACKED_BYTES then return nil, "too_big" end
    return out, nil, bytes
end

-- Reads a Lua string literal starting at position i: "..", '..' or [[..]] / [==[..]==].
local function readLiteral(text, i)
    local q = text:sub(i, i)
    if q == '"' or q == "'" then
        local j, buf = i + 1, {}
        while j <= #text do
            local c = text:sub(j, j)
            if c == "\\" then
                local n = text:sub(j + 1, j + 1)
                buf[#buf + 1] = ({ n = "\n", t = "\t", ["\\"] = "\\", ['"'] = '"', ["'"] = "'" })[n] or n
                j = j + 2
            elseif c == q then
                return table.concat(buf)
            else
                buf[#buf + 1] = c
                j = j + 1
            end
        end
        return nil
    end
    local eq = text:match("^%[(=*)%[", i)
    if eq then
        local open_end = i + #eq + 1
        local close = "]" .. eq .. "]"
        local s = text:find(close, open_end + 1, true)
        if not s then return nil end
        local body = text:sub(open_end + 1, s - 1)
        return (body:gsub("^\n", ""))
    end
    return nil
end

--- Extracts `key = _("...")` / `key = "..."` / `key = _([[...]])` from _meta.lua
-- source text, without running it.
function PluginZip.metaField(text, key)
    local s, e = text:find("[%s{,]" .. key .. "%s*=%s*")
    if not s then
        s, e = text:find("^" .. key .. "%s*=%s*")
        if not s then return nil end
    end
    local i = e + 1
    local gettext = text:match("^_%s*%(%s*", i)
    if gettext then i = i + #gettext end
    local value = readLiteral(text, i)
    if value then value = value:gsub("%s+", " "):gsub("^ ", ""):gsub(" $", "") end
    return value ~= "" and value or nil
end

--- Built-in plugin names from KOReader's pluginloader.lua source (its
-- BUILTIN_PLUGINS table), so this stays right across KOReader versions.
-- @treturn table set of names, or nil if the table could not be found
function PluginZip.parseBuiltins(source)
    local block = source and source:match("BUILTIN_PLUGINS%s*=%s*(%b{})")
    if not block then return nil end
    local set, n = {}, 0
    for name in block:gmatch('%[%s*"([^"]+)"%s*%]%s*=%s*true') do
        set[name] = true
        n = n + 1
    end
    return n > 0 and set or nil
end

return PluginZip
