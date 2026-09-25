-- Emulator-only KOReader user patch (never shipped): exercises every screen
-- and action of the plugin in sequence, through its own functions, and logs
--   "KINDLEUI SMOKE ok <step>" / "KINDLEUI SMOKE FAIL <step>: <error>"
-- then "KINDLEUI SMOKE DONE failures=<n>". Errors that happen later (while
-- painting) are caught by tests/e2e/smoke.sh grepping the log.
local UIManager = require("ui/uimanager")
local logger = require("logger")

local failures = 0
local function top() return UIManager:getTopmostVisibleWidget() end
local function closeTop() local w = top() if w then UIManager:close(w) end end
local function plugin()
    local FileManager = require("apps/filemanager/filemanager")
    return FileManager.instance and FileManager.instance.kindleui
end
local function homeFits()
    local home = top()
    assert(home.name == "kindleui_home", "top is " .. tostring(home.name))
    assert(home.used_height <= home.dimen.h, "Home is taller than the screen: " .. home.used_height .. " > " .. home.dimen.h)
    logger.info(string.format("KINDLEUI SMOKE home fit: %d px of %d, more=%d recent=%s compact=%s",
        home.used_height, home.dimen.h, home.fit.more, tostring(home.fit.recent), tostring(home.fit.compact == true)))
end
local function setting(key, value)
    require("kindleui/config").set(key, value)
end

local steps = {
    -- KOReader's first launch opens its quickstart guide: leave it the way a
    -- user does (Home), which must bring up our Home screen.
    { "leave the book", function()
        local ReaderUI = require("apps/reader/readerui")
        if ReaderUI.instance then ReaderUI.instance:onHome() end
    end, 4 },
    { "home shown at startup", function() assert(top() and top().name == "kindleui_home", "top is " .. tostring(top() and top().name)) end },
    { "library grid", function() plugin():showLibrary() assert(top().name == "kindleui_library_grid") end },
    { "grid next page", function() top():onNextPage() end },
    { "grid prev page", function() top():onPrevPage() end },
    { "grid filter reading", function() setting("library_filter", "reading") top():reload() end },
    { "grid search", function() require("kindleui/ui/library").session.search = "book" top():reload() end },
    { "grid clear search + filter", function() require("kindleui/ui/library").session.search = nil setting("library_filter", "all") top():reload() end },
    { "grid prepare all covers", function() top():prepareAll() end, 12 },
    { "grid options dialog", function() require("kindleui/ui/library").showOptions(top(), plugin()) end },
    { "close options", closeTop },
    { "grid: collection filter", function()
        local ReadCollection = require("readcollection")
        if not ReadCollection.coll["Smoke"] then ReadCollection:addCollection("Smoke") end
        local grid = top()
        local picked = { grid.tiles[1].book.path, grid.tiles[2].book.path }
        for __, f in ipairs(picked) do ReadCollection:addItem(f, "Smoke") end
        ReadCollection:write({ Smoke = true })
        local Library = require("kindleui/ui/library")
        local found
        for __, c in ipairs(Library.collections(plugin())) do if c.name == "Smoke" then found = c end end
        assert(found and found.count == 2, "collection not listed with 2 books")
        Library.chooseCollection(grid, plugin())
        assert(top().buttons, "no collection chooser")
        closeTop()
        setting("library_collection", "Smoke")
        grid:reload()
        assert(#grid.books == 2, "books shown: " .. #grid.books)
        assert(Library.subtitle(#grid.books, grid.total_books):find("Smoke", 1, true), "subtitle lacks the collection")
        setting("library_collection", "gone")
        grid:reload()
        assert(#grid.books == grid.total_books, "a missing collection must show all books")
        setting("library_collection", nil)
        grid:reload()
    end },
    { "grid: hold a cover (book menu)", function()
        local grid = top()
        grid:showDetails(grid.tiles[1].book)
        assert(top().buttons, "no book menu")
        local has_coll
        for __, row in ipairs(top().buttons) do
            for __, btn in ipairs(row) do if btn.text == require("gettext")("Collections…") then has_coll = true end end
        end
        assert(has_coll, "no Collections… button")
    end },
    { "close book menu", closeTop },
    { "grid: delete a book from the menu", function()
        local grid = top()
        local book
        for __, t in ipairs(grid.tiles) do if t.book.path:find("Book 060", 1, true) then book = t.book end end
        book = book or grid.tiles[#grid.tiles].book
        _G.kindleui_smoke_deleted = book.path
        grid:showDetails(book)
        local menu = top()
        menu.buttons[#menu.buttons][1].callback() -- Delete book…
        local confirm = top()
        assert(confirm.ok_callback, "no delete confirmation")
        UIManager:close(confirm)
        confirm.ok_callback()
    end, 2 },
    { "deleted book is gone", function()
        local path = _G.kindleui_smoke_deleted
        assert(not require("libs/libkoreader-lfs").attributes(path), "file still there")
        assert(not require("kindleui/util/librarycache").entries[path], "still in the cache")
        for __, t in ipairs(top().tiles) do assert(t.book.path ~= path, "still in the grid") end
    end },
    { "grid: group series", function()
        local grid = top()
        setting("library_group_series", true)
        grid:reload()
        local group
        for __, b in ipairs(grid.books) do if b.is_series and b.series == "Smoke Saga" then group = b end end
        assert(group, "no Smoke Saga group")
        assert(group.count == 3, "group count " .. group.count)
        assert(group.path:find("Book 006", 1, true), "group cover is not volume 1: " .. group.path)
        assert(require("kindleui/ui/library").subtitle(grid.books, grid.total_books):find(tostring(grid.total_books), 1, true), "subtitle count")
        grid:onTile(group)
        assert(#grid.books == 3, "books in series: " .. #grid.books)
        assert(grid.books[1].path:find("Book 006", 1, true) and grid.books[3].path:find("Book 004", 1, true), "reading order")
        grid:onClose()
        assert(top() == grid and not require("kindleui/ui/library").session.series, "close did not leave the series")
        setting("library_group_series", false)
        grid:reload()
    end },
    { "grid: select mode from the book menu", function()
        local grid = top()
        grid:showDetails(grid.tiles[1].book)
        local menu = top()
        local sel_btn
        for __, row in ipairs(menu.buttons) do
            for __, btn in ipairs(row) do if btn.text and btn.text:find("Select", 1, true) then sel_btn = btn end end
        end
        assert(sel_btn, "no Select button in the book menu")
        sel_btn.callback()
        assert(grid.selecting and grid.selection.count == 1, "not selecting with one book")
        grid:onTile(grid.tiles[2].book)
        assert(grid.selection.count == 2, "tap did not tick a second book")
        grid:onTile(grid.tiles[2].book)
        assert(grid.selection.count == 1, "tap did not untick")
    end },
    { "grid: selection actions", function()
        local grid = top()
        require("kindleui/ui/selection").showActions(grid, plugin())
        local dialog = top()
        dialog.buttons[1][1].callback() -- select all on this page
        assert(grid.selection.count == #grid:pageBooks(), "page not selected")
    end },
    { "grid: batch delete two books", function()
        local grid = top()
        grid.selection:clear()
        local victims = {}
        for i = #grid.books, #grid.books - 1, -1 do
            table.insert(victims, grid.books[i].path)
            grid.selection:toggle(grid.books[i].path)
        end
        local before = #grid.books
        require("kindleui/ui/selection").showActions(grid, plugin())
        local dialog = top()
        local del
        for __, row in ipairs(dialog.buttons) do
            for __, btn in ipairs(row) do if btn.text == require("gettext")("Delete…") then del = btn end end
        end
        del.callback()
        local confirm = top()
        assert(confirm.ok_callback and confirm.text:find("2 books", 1, true), "confirm: " .. tostring(confirm.text))
        UIManager:close(confirm)
        confirm.ok_callback()
        assert(#grid.books == before - 2, "books: " .. #grid.books .. " (was " .. before .. ")")
        local lfs = require("libs/libkoreader-lfs")
        for __, p in ipairs(victims) do assert(not lfs.attributes(p), "still on disk: " .. p) end
    end },
    { "grid: leave selection with close", function()
        local grid = top()
        grid:onClose()
        assert(top() == grid and not grid.selecting, "close did not just leave selection")
    end },
    { "close grid", closeTop },
    { "library list", function() setting("library_view", "list") plugin():showLibrary() assert(top().name == "kindleui_library") end },
    { "list sort by title", function() setting("library_sort", "title") top():reload() end },
    { "list: hold a book (book menu)", function()
        local list = top()
        list:onMenuHold(list.item_table[1])
        assert(top().buttons, "no book menu")
    end },
    { "close list book menu", closeTop },
    { "list: select mode", function()
        local list = top()
        list:setSelecting(true)
        list:onMenuChoice(list.item_table[1])
        list:onMenuChoice(list.item_table[2])
        assert(list.selection.count == 2, "list selection: " .. list.selection.count)
        assert(list.item_table[1].text:find("☑", 1, true), "no tick mark")
        list:onLeftButtonTap()
        assert(top().buttons, "no selection actions")
        closeTop()
        list:onClose()
        assert(top() == list and not list.selecting, "close did not just leave selection")
    end },
    { "close list", function() closeTop() setting("library_view", "covers") setting("library_sort", "recent") end },
    { "installed plugins", function() plugin():showPlugins() assert(top().name == "kindleui_plugins") end },
    { "open a plugin menu", function()
        local Plugins = require("kindleui/ui/plugins")
        local entry = Plugins.find(plugin(), "autowarmth") or Plugins.find(plugin(), "calibre")
        assert(entry, "no test plugin found")
        Plugins.open(entry)
    end },
    { "close plugin menu", closeTop },
    { "plugins: selection offers no built-in plugin", function()
        local list = top()
        list:setSelecting(true)
        for __, row in ipairs(list.item_table) do
            assert(not row.select_module, "selectable: " .. tostring(row.text))
        end
        list:onClose()
        assert(top() == list and not list.selecting, "close did not just leave selection")
    end },
    { "pin two plugins", function()
        local Plugins = require("kindleui/ui/plugins")
        Plugins.setPinned("calibre", true)
        Plugins.setPinned("statistics", true)
    end },
    { "close plugins", closeTop },
    { "home refresh (pinned, recent, status)", function() plugin():showHome() homeFits() end },
    { "home: more books being read", function()
        -- Books 001-003 have reading progress (tests/make_library.sh).
        local ReadHistory = require("readhistory")
        local now = os.time()
        for i, f in ipairs({ "/books/shelf3/Book 003.epub", "/books/shelf2/Book 002.epub", "/books/shelf1/Book 001.epub" }) do
            ReadHistory:addItem(f, now + i)
        end
        G_reader_settings:saveSetting("lastfile", "/books/shelf1/Book 001.epub")
        plugin():showHome()
        homeFits()
        local rows = top().more_reading or {}
        assert(#rows >= 1, "no rows (fit level " .. top().fit.more .. ")")
        assert(rows[1].file:find("Book 002", 1, true), "order: " .. rows[1].file)
        if rows[2] then assert(rows[2].file:find("Book 003", 1, true), "order: " .. rows[2].file) end
    end },
    { "book menu from a Home row: mark finished", function()
        local rows = top().more_reading
        local target = rows[#rows].file -- Book 002 or 003
        top():showBookMenu(target, "x")
        local dialog = top()
        assert(dialog.buttons and dialog.buttons[1][3], "status row missing")
        dialog.buttons[1][3].callback() -- Finished
        plugin():showHome()
        for __, r in ipairs(top().more_reading) do assert(r.file ~= target, "finished book still listed") end
        _G.kindleui_smoke_finished = target
    end },
    { "book menu: remove from Continue Reading", function()
        local BookMenu = require("kindleui/ui/bookmenu")
        local last = G_reader_settings:readSetting("lastfile")
        assert(BookMenu.inHistory(last), "last book not in history")
        BookMenu.removeFromHistory(last)
        assert(G_reader_settings:readSetting("lastfile") ~= last, "Continue Reading not moved on")
        assert(not BookMenu.inHistory(last), "still in history")
        plugin():showHome()
        homeFits()
    end },
    { "home: more books being read off", function()
        setting("home_more_reading", false)
        plugin():showHome()
        assert(#(top().more_reading or {}) == 0, "rows shown while off")
        setting("home_more_reading", true)
        plugin():showHome()
    end },
    { "home: time left from Statistics data", function()
        -- Give the Continue Reading book a Statistics row: 50 pages read in
        -- 3000 s, 300 pages → at its progress, (1 - p) * 300 * 60 s left.
        local file = G_reader_settings:readSetting("lastfile")
        local DocSettings = require("docsettings")
        local ds = DocSettings:open(file)
        ds:saveSetting("partial_md5_checksum", "smoke0123456789abcdef0123456789ab")
        ds:flush()
        require("kindleui/util/librarycache").invalidate(file)
        local SQ3 = require("lua-ljsqlite3/init")
        local conn = SQ3.open(require("datastorage"):getSettingsDir() .. "/statistics.sqlite3")
        conn:exec([[CREATE TABLE IF NOT EXISTS book (id integer PRIMARY KEY autoincrement, title text, authors text,
            notes integer, last_open integer, highlights integer, pages integer, series text, language text,
            md5 text, total_read_time integer, total_read_pages integer);]])
        conn:exec("DELETE FROM book WHERE md5 = 'smoke0123456789abcdef0123456789ab';")
        conn:exec("INSERT INTO book (title, authors, pages, md5, total_read_time, total_read_pages, last_open) " ..
            "VALUES ('Smoke', 'Smoke', 300, 'smoke0123456789abcdef0123456789ab', 3000, 50, " .. os.time() .. ");")
        conn:close()
        plugin():showHome()
        local text = top().card_progress or ""
        logger.info("KINDLEUI SMOKE card progress: " .. text)
        assert(text:find("left", 1, true), "no time left on the card: " .. text)
        setting("home_time_left", false)
        plugin():showHome()
        assert(not (top().card_progress or ""):find("left", 1, true), "shown while switched off")
        setting("home_time_left", true)
    end },
    { "quick settings: night mode on and off", function()
        local home = top()
        local function nightButton()
            home:showQuickSettings()
            local dialog = top()
            assert(dialog.buttons, "no quick settings")
            for __, row in ipairs(dialog.buttons) do
                for __, btn in ipairs(row) do
                    if btn.text:find("Night mode", 1, true) then return btn end
                end
            end
            error("no night mode button")
        end
        local before = G_reader_settings:isTrue("night_mode")
        nightButton().callback()
        assert(G_reader_settings:isTrue("night_mode") ~= before, "night mode not toggled")
        nightButton().callback()
        assert(G_reader_settings:isTrue("night_mode") == before, "night mode not restored")
        home:onSwipe(nil, { direction = "south" })
        local panel = top()
        local labels = {}
        for __, row in ipairs(panel.buttons) do for __, btn in ipairs(row) do table.insert(labels, btn.text) end end
        logger.info("KINDLEUI SMOKE quick settings: " .. table.concat(labels, " | "))
        UIManager:close(panel)
        -- The emulator runs KOReader as a desktop (no light, Wi-Fi toggle or
        -- sleep): pretend it has them, to build the full panel once.
        local Device = require("device")
        local saved = { Device.hasFrontlight, Device.hasWifiToggle, Device.canSuspend }
        local yes = function() return true end
        Device.hasFrontlight, Device.hasWifiToggle, Device.canSuspend = yes, yes, yes
        local ok, err = pcall(function()
            home:showQuickSettings()
            local full = top()
            local all = {}
            for __, r in ipairs(full.buttons) do for __, btn in ipairs(r) do table.insert(all, btn.text) end end
            logger.info("KINDLEUI SMOKE quick settings (full): " .. table.concat(all, " | "))
            assert(#all == 5, "expected 5 entries, got " .. #all)
            UIManager:close(full)
        end)
        Device.hasFrontlight, Device.hasWifiToggle, Device.canSuspend = saved[1], saved[2], saved[3]
        assert(ok, err)
    end, 3 },
    { "text size large", function() setting("text_size", "large") plugin():showHome() homeFits() end },
    { "text size small", function() setting("text_size", "small") plugin():showHome() homeFits() end },
    { "text size medium", function() setting("text_size", "medium") plugin():showHome() homeFits() end },
    { "settings menu", function() plugin():showSettings() end },
    { "close settings", closeTop },
    { "send book screen", function() plugin():showTransfer() assert(top().name == "kindleui_transfer") end, 3 },
    { "send book new code", function() top():startSession() end, 2 },
    { "close send book", closeTop },
    { "send plugin screen", function() plugin():showPluginTransfer() assert(top().name == "kindleui_transfer" and top().kind == "plugin") end, 3 },
    { "close send plugin", closeTop },
    { "undo with nothing to undo", function()
        assert(not require("kindleui/util/plugininstaller").canUndo(), "undo offered with no install")
        require("kindleui/ui/plugininstall").confirmUndo()
    end },
    { "close undo message", closeTop },
    { "rotate to the other orientation", function()
        local FileManager = require("apps/filemanager/filemanager")
        local Screen = require("device").screen
        _G.kindleui_smoke_rotation = Screen:getRotationMode()
        FileManager.instance:onSetRotationMode(require("bit").bxor(_G.kindleui_smoke_rotation, 1))
    end, 4 },
    { "home follows the rotation", function()
        local Screen = require("device").screen
        local home = top()
        assert(home.name == "kindleui_home", "top is " .. tostring(home.name))
        assert(home.dimen.w == Screen:getWidth() and home.dimen.h == Screen:getHeight(), "Home kept the old size")
        assert(home.landscape == (Screen:getWidth() > Screen:getHeight()), "wrong layout for the orientation")
        homeFits()
    end },
    { "rotate back", function()
        require("apps/filemanager/filemanager").instance:onSetRotationMode(_G.kindleui_smoke_rotation)
    end, 4 },
    { "home back in the first orientation", function()
        local Screen = require("device").screen
        assert(top().dimen.w == Screen:getWidth(), "Home kept the rotated size")
        homeFits()
    end },
    { "unpin plugins", function()
        local Plugins = require("kindleui/ui/plugins")
        Plugins.setPinned("calibre", false)
        Plugins.setPinned("statistics", false)
        plugin():showHome()
    end },
}

local i = 0
local function nextStep()
    i = i + 1
    local step = steps[i]
    if not step then
        logger.info("KINDLEUI SMOKE DONE failures=" .. failures)
        return
    end
    local ok, err = pcall(step[2])
    if ok then
        logger.info("KINDLEUI SMOKE ok " .. step[1])
    else
        failures = failures + 1
        logger.warn("KINDLEUI SMOKE FAIL " .. step[1] .. ": " .. tostring(err))
    end
    UIManager:scheduleIn(step[3] or 1.5, nextStep)
end
UIManager:scheduleIn(6, nextStep)
