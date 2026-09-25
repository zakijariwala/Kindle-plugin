--[[--
Small persistent cache for the Library and Home screens.

Why: without it, every Library open parses each book's KOReader sidecar
(metadata.<ext>.lua) to get title, author and progress: 100 books means 100
Lua files read and evaluated. With it, an unchanged library costs one cache
file read plus a couple of `stat()` calls per book (the book itself, and the
sidecar's modification time). A sidecar is re-read only when KOReader has
written it since (i.e. the book was read or its status changed).

Covers: thumbnails are extracted by this plugin itself, once per book, so the
Cover browser plugin is not needed. Each thumbnail is stored like Cover browser
stores its own (a zstd-compressed raw blitbuffer), one small file per book,
so showing a page of covers needs no image decoding.

Storage:
    <settings>/kindleui_library.lua        entries (LuaSettings)
    <settings>/kindleui_covers/<md5>.bbz   thumbnails

@module kindleui.util.librarycache
]]

local Blitbuffer = require("ffi/blitbuffer")
local DataStorage = require("datastorage")
local DocSettings = require("docsettings")
local LuaSettings = require("luasettings")
local ffi = require("ffi")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local md5 = require("ffi/sha2").md5
local util = require("util")

local C = ffi.C
pcall(ffi.cdef, "void free(void *);") -- already declared by koreader-base in practice

local SCHEMA = 1
local COVER_MAGIC = "KUIC1" -- header: magic, w, h, bb type, stride (text line) then zstd data

local Cache = {
    entries = nil,   -- path -> entry
    dirty = false,
    settings = nil,
}

local function coverDir()
    return DataStorage:getSettingsDir() .. "/kindleui_covers"
end

function Cache.load()
    if Cache.entries then return end
    Cache.settings = LuaSettings:open(DataStorage:getSettingsDir() .. "/kindleui_library.lua")
    if Cache.settings:readSetting("schema") ~= SCHEMA then
        Cache.entries = {}
        Cache.dirty = true
    else
        Cache.entries = Cache.settings:readSetting("entries") or {}
    end
end

function Cache.save()
    if not Cache.dirty or not Cache.settings then return end
    Cache.settings:saveSetting("schema", SCHEMA)
    Cache.settings:saveSetting("entries", Cache.entries)
    Cache.settings:flush()
    Cache.dirty = false
end

local function sidecarMtime(path)
    local sidecar = DocSettings:findSidecarFile(path)
    if not sidecar then return false end
    return lfs.attributes(sidecar, "modification") or false
end

-- Re-reads title/author/progress from KOReader's own metadata for one book.
local function readSidecarInfo(ui, entry, path)
    local BookList = require("ui/widget/booklist")
    BookList.resetBookInfoCache(path) -- force a fresh read of the changed sidecar
    local ok_bi, book_info = pcall(BookList.getBookInfo, path)
    if ok_bi and book_info and book_info.been_opened then
        entry.percent = book_info.percent_finished
        entry.status = book_info.status
    else
        entry.percent, entry.status = nil, nil
    end
    local ok, props = pcall(function()
        return ui and ui.bookinfo and ui.bookinfo:getDocProps(path, nil, true)
    end)
    if ok and props and props.title then
        entry.title = props.title
        entry.authors = props.authors
    end
end

-- Brings one entry up to date. Returns the entry and whether the sidecar was read.
local function refreshEntry(ui, path, mtime, size)
    local e = Cache.entries[path]
    if not e or e.mtime ~= mtime or e.size ~= size then
        -- new or replaced file: start over (cover and metadata too)
        if e and e.cover then os.remove(coverDir() .. "/" .. e.cover) end
        e = { mtime = mtime, size = size }
        Cache.entries[path] = e
        Cache.dirty = true
    end
    local sdr = sidecarMtime(path)
    if e.sdr == sdr then
        return e, false
    end
    if sdr then
        readSidecarInfo(ui, e, path)
    else
        e.percent, e.status = nil, nil
    end
    e.sdr = sdr
    Cache.dirty = true
    return e, sdr and true or false
end

--- Fills title/authors/percent/status fields (and `entry`) of scanned books.
-- @param books array from Books.scan ({ path, name, mtime, size })
-- @treturn table stats { books, sidecar_reads, new_entries }
function Cache.annotate(ui, books)
    Cache.load()
    local stats = { books = #books, sidecar_reads = 0, new_entries = 0 }
    local seen = {}
    for __, b in ipairs(books) do
        seen[b.path] = true
        if not Cache.entries[b.path] then stats.new_entries = stats.new_entries + 1 end
        local e, read = refreshEntry(ui, b.path, b.mtime, b.size)
        if read then
            stats.sidecar_reads = stats.sidecar_reads + 1
        end
        b.title = e.title or util.splitFileNameSuffix(b.name)
        b.authors = e.authors
        b.percent = e.percent
        b.status = e.status
        b.entry = e
    end
    -- forget books that are gone (keeps the cache file small)
    for path, e in pairs(Cache.entries) do
        if not seen[path] then
            if e.cover then os.remove(coverDir() .. "/" .. e.cover) end
            Cache.entries[path] = nil
            Cache.dirty = true
        end
    end
    return stats
end

--- Up-to-date entry for a single book (Home's Continue Reading), or nil.
function Cache.getEntry(ui, path)
    Cache.load()
    local attr = lfs.attributes(path)
    if not attr or attr.mode ~= "file" then return nil end
    local e = refreshEntry(ui, path, attr.modification, attr.size)
    Cache.save()
    return e
end

--- The `n` most recently added books known to the cache (newest file time
-- first), skipping `exclude` and files that no longer exist. No folder scan:
-- books copied over USB show up once My Library has been opened.
-- @treturn table array of { path, entry }
function Cache.recent(n, exclude)
    Cache.load()
    local list = {}
    for path, e in pairs(Cache.entries) do
        if path ~= exclude and e.mtime then table.insert(list, { path = path, entry = e }) end
    end
    table.sort(list, function(a, b) return a.entry.mtime > b.entry.mtime end)
    local out = {}
    for __, it in ipairs(list) do
        if #out >= n then break end
        if lfs.attributes(it.path, "mode") == "file" then table.insert(out, it) end
    end
    return out
end

--- Drops everything (Library → Refresh), including thumbnails.
function Cache.clear()
    Cache.load()
    for __, e in pairs(Cache.entries) do
        if e.cover then os.remove(coverDir() .. "/" .. e.cover) end
    end
    Cache.entries = {}
    Cache.dirty = true
    Cache.save()
end

--- Thumbnail size used outside the Library grid (e.g. right after Send Book):
-- about the size of a portrait grid cover, so the grid rarely rescales.
function Cache.thumbSize()
    local Screen = require("device").screen
    local w = math.floor(math.min(Screen:getWidth(), Screen:getHeight()) / 3.6)
    return w, math.floor(w * 1.5)
end

--- True if metadata/cover have not been extracted for this entry yet.
function Cache.needsExtraction(entry)
    return entry and entry.extracted == nil
end

-- True if the image is (almost) a blank page, e.g. a PDF whose first page is
-- empty: a text cover (title + author) is more useful then, as on a Kindle.
local function isBlank(bb)
    local w, h = bb:getWidth(), bb:getHeight()
    local total, light = 0, 0
    for y = 0, h - 1, math.max(1, math.floor(h / 48)) do
        for x = 0, w - 1, math.max(1, math.floor(w / 32)) do
            total = total + 1
            if bb:getPixel(x, y):getColor8().a >= 0xF0 then light = light + 1 end
        end
    end
    return total > 0 and light / total > 0.985
end
Cache.isBlank = isBlank

local function writeCover(bb, file)
    local zstd = require("ffi/zstd")
    local size = bb.stride * bb.h
    local zptr, zsize = zstd.zstd_compress(bb.data, size)
    -- write then rename, so a killed extraction never leaves a half file
    local tmp = file .. ".tmp"
    local f = io.open(tmp, "wb")
    if not f then
        C.free(zptr)
        return false
    end
    f:write(string.format("%s %d %d %d %d\n", COVER_MAGIC, bb.w, bb.h, bb:getType(), tonumber(bb.stride)))
    f:write(ffi.string(zptr, zsize))
    f:close()
    C.free(zptr)
    return os.rename(tmp, file) and true or false
end

--- Opens the book once (metadata only, like Cover browser does) to get its
-- title, authors and cover, and stores a thumbnail of at most max_w x max_h.
-- Only ever called in a child process (see util/extractor.lua): document
-- engines keep memory after a document is closed.
function Cache.extract(path, entry, max_w, max_h)
    entry.extracted = false
    Cache.dirty = true
    local DocumentRegistry = require("document/documentregistry")
    local FileManagerBookInfo = require("apps/filemanager/filemanagerbookinfo")
    local ReaderUI = require("apps/reader/readerui")
    local ok, err = pcall(function()
        local provider = ReaderUI:extendProvider(path, DocumentRegistry:getProvider(path))
        local document = DocumentRegistry:openDocument(path, provider)
        if not document then return end
        local loaded = true
        if document.loadDocument and not document:loadDocument(false) then -- metadata only
            loaded = false
        end
        if loaded then
            local props = FileManagerBookInfo.extendProps(document:getProps(), path)
            if props.title and not entry.title then
                entry.title = props.title
                entry.authors = props.authors
            end
            local cover_bb = FileManagerBookInfo:getCoverImage(document)
            if cover_bb then
                local w, h = cover_bb:getWidth(), cover_bb:getHeight()
                local scale = math.min(max_w / w, max_h / h, 1)
                if scale < 1 then
                    local RenderImage = require("ui/renderimage")
                    cover_bb = RenderImage:scaleBlitBuffer(cover_bb, math.floor(w * scale), math.floor(h * scale), true)
                end
                -- Grayscale is all an E Ink Kindle shows; it also keeps files small.
                if cover_bb:getType() ~= Blitbuffer.TYPE_BB8 then
                    local gray = Blitbuffer.new(cover_bb.w, cover_bb.h, Blitbuffer.TYPE_BB8)
                    gray:blitFrom(cover_bb)
                    cover_bb:free()
                    cover_bb = gray
                end
                if not isBlank(cover_bb) then
                    lfs.mkdir(coverDir())
                    local name = md5(path) .. ".bbz"
                    if writeCover(cover_bb, coverDir() .. "/" .. name) then
                        entry.cover = name
                    end
                end
                cover_bb:free()
            end
            entry.extracted = true
        end
        document:close()
    end)
    if not ok then
        logger.warn("KindleUI: could not extract cover/metadata:", err)
    end
    return entry
end

--- Loads a stored thumbnail. The caller owns (and must free) the blitbuffer.
function Cache.loadCover(entry)
    if not entry or not entry.cover then return nil end
    local f = io.open(coverDir() .. "/" .. entry.cover, "rb")
    if not f then
        entry.cover = nil
        return nil
    end
    local header = f:read("*l")
    local data = f:read("*a")
    f:close()
    local magic, w, h, bbtype, stride = (header or ""):match("^(%S+) (%d+) (%d+) (%d+) (%d+)$")
    if magic ~= COVER_MAGIC or not data or #data == 0 then return nil end
    w, h, bbtype, stride = tonumber(w), tonumber(h), tonumber(bbtype), tonumber(stride)
    local ok, bb = pcall(function()
        local zstd = require("ffi/zstd")
        local buf, size = zstd.zstd_uncompress_ctx(data, #data)
        assert(tonumber(size) == stride * h, "unexpected thumbnail size")
        local cover = Blitbuffer.new(w, h, bbtype, buf, stride, w)
        cover:setAllocated(1) -- free() the zstd buffer with the blitbuffer
        return cover
    end)
    if ok then return bb end
    logger.warn("KindleUI: bad thumbnail", entry.cover, bb)
    return nil
end

return Cache
