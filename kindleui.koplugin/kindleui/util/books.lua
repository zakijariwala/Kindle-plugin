--[[--
Thin adapter over KOReader's own document/library facilities.

Nothing here parses documents or keeps an index: metadata comes from
KOReader's sidecar files (via FileManagerBookInfo / BookList), covers from the
Cover browser plugin's cache (only if that plugin is enabled), and books are
opened through FileManager:openFile / ReaderUI:showReader.

@module kindleui.util.books
]]

local Device = require("device")
local DocumentRegistry = require("document/documentregistry")
local filemanagerutil = require("apps/filemanager/filemanagerutil")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local util = require("util")

local Books = {}

--- The folder KOReader treats as "Home" (the root of the library).
function Books.homeDir()
    return filemanagerutil.getHomeFolder()
end

--- Where received books are stored.
-- On Kindle KOReader's home is usually /mnt/us; books conventionally live in
-- /mnt/us/documents, so use that when it exists.
function Books.destinationDir()
    local home = Books.homeDir()
    if Device:isKindle() then
        local docs = home:gsub("/$", "") .. "/documents"
        if lfs.attributes(docs, "mode") == "directory" then
            return docs
        end
    end
    return home
end

-- Extensions with a registered KOReader document provider.
local function documentExtensions()
    local exts = {}
    for ext in pairs(DocumentRegistry:getExtensions()) do
        exts[ext:lower()] = true
    end
    return exts
end

--- True if KOReader has a document provider for this file name's extension.
function Books.isSupportedName(name)
    local ext = util.getFileNameSuffix(name)
    if not ext or ext == "" then return false end
    return documentExtensions()[ext:lower()] == true
end

--- Human-readable list of supported formats, most common first.
function Books.formatList()
    local exts = documentExtensions()
    local order = { "epub", "pdf", "mobi", "azw3", "azw", "fb2", "cbz", "djvu", "docx", "txt", "html", "rtf" }
    local out = {}
    for _, e in ipairs(order) do
        if exts[e] then table.insert(out, e:upper()) end
    end
    return table.concat(out, ", ") .. " and other formats KOReader supports"
end

--- Lists documents below `root` (skips hidden folders and *.sdr metadata folders).
-- @treturn table array of { path, name, mtime }
function Books.scan(root, max_depth, max_books)
    local exts = documentExtensions()
    local found = {}
    local function walk(dir, depth)
        if #found >= max_books then return end
        local ok, iter, dir_obj = pcall(lfs.dir, dir)
        if not ok then return end
        for f in iter, dir_obj do
            if #found >= max_books then return end
            if f:sub(1, 1) ~= "." then
                local path = dir .. "/" .. f
                local attr = lfs.attributes(path)
                if attr and attr.mode == "directory" then
                    if depth < max_depth and not f:match("%.sdr$") then
                        walk(path, depth + 1)
                    end
                elseif attr and attr.mode == "file" then
                    local ext = util.getFileNameSuffix(f)
                    if ext and exts[ext:lower()] then
                        table.insert(found, { path = path, name = f, mtime = attr.modification })
                    end
                end
            end
        end
    end
    walk((root:gsub("/$", "")), 0)
    return found
end

--- Cheap metadata for a book: never opens the document.
-- @treturn table { title, authors, percent (0..1 or nil), status }
function Books.getInfo(ui, file)
    local info = {}
    local ok, props = pcall(function()
        return ui and ui.bookinfo and ui.bookinfo:getDocProps(file, nil, true)
    end)
    if ok and props then
        info.title = props.display_title or props.title
        info.authors = props.authors
    end
    if not info.title then
        info.title = filemanagerutil.splitFileNameType(file)
    end
    if info.authors then
        info.authors = tostring(info.authors):gsub("\n", ", ")
        if info.authors == "" then info.authors = nil end
    end
    local BookList = require("ui/widget/booklist")
    local ok_bi, book_info = pcall(BookList.getBookInfo, file)
    if ok_bi and book_info and book_info.been_opened then
        info.percent = book_info.percent_finished
        info.status = book_info.status
    end
    return info
end

--- Cover blitbuffer from the Cover browser cache, if that plugin is enabled
-- and has already extracted this book. Never extracts anything itself.
-- The caller owns (and must free) the returned blitbuffer.
function Books.getCachedCover(ui, file)
    if not (ui and ui.coverbrowser) then return nil end
    local ok, BookInfoManager = pcall(require, "bookinfomanager")
    if not ok or not BookInfoManager then return nil end
    local ok_info, bookinfo = pcall(BookInfoManager.getBookInfo, BookInfoManager, file, true)
    if ok_info and bookinfo and bookinfo.cover_bb then
        return bookinfo.cover_bb
    end
    return nil
end

--- Most recently read book that still exists, or nil.
function Books.lastFile()
    local last = G_reader_settings:readSetting("lastfile")
    if last and lfs.attributes(last, "mode") == "file" then
        return last
    end
    return nil
end

--- Map of file -> last read timestamp, from KOReader's reading history.
function Books.historyTimes()
    local times = {}
    local ok, ReadHistory = pcall(require, "readhistory")
    if ok and ReadHistory and ReadHistory.hist then
        for _, item in ipairs(ReadHistory.hist) do
            times[item.file] = item.time
        end
    end
    return times
end

--- Opens a book with KOReader's normal reader.
-- @func[opt] after_open_callback called with the ReaderUI instance once ready
function Books.open(file, after_open_callback)
    logger.info("KindleUI: opening book")
    local FileManager = require("apps/filemanager/filemanager")
    if FileManager.instance then
        FileManager.instance:openFile(file, nil, nil, nil, after_open_callback)
    else
        require("apps/reader/readerui"):showReader(file, nil, nil, nil, after_open_callback)
    end
end

--- Asks KOReader's file browser (if shown) to re-read its folder.
function Books.refreshLibrary(new_file)
    if new_file then
        pcall(function() require("ui/widget/booklist").resetBookInfoCache(new_file) end)
    end
    local FileManager = require("apps/filemanager/filemanager")
    if FileManager.instance then
        pcall(FileManager.instance.onRefresh, FileManager.instance)
    end
end

return Books
