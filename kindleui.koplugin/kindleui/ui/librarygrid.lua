--[[--
Cover grid view of "My Library" (the default view, like a stock Kindle).

Pages of 3 columns (portrait) with a cover, and a one-word progress label
("63%", "New", "Finished") under each. Books whose cover has not been
extracted yet show a plain text cover (title + author) at first; their real
cover is extracted afterwards, *in a child process, only for the page on
screen, only while this screen is open*, and swapped in place. Nothing keeps
running once the Library is closed.

Tap a cover to open the book; hold it for its KOReader book details.
Swipe left/right (or the arrows) to turn pages.

@module kindleui.ui.librarygrid
]]

local Blitbuffer = require("ffi/blitbuffer")
local Button = require("ui/widget/button")
local Cache = require("kindleui/util/librarycache")
local CenterContainer = require("ui/widget/container/centercontainer")
local Common = require("kindleui/ui/common")
local Device = require("device")
local Extractor = require("kindleui/util/extractor")
local FocusManager = require("ui/widget/focusmanager")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local ImageWidget = require("ui/widget/imagewidget")
local Library = require("kindleui/ui/library")
local Perf = require("kindleui/util/perf")
local Size = require("ui/size")
local TextBoxWidget = require("ui/widget/textboxwidget")
local TextWidget = require("ui/widget/textwidget")
local TitleBar = require("ui/widget/titlebar")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local _ = require("gettext")
local T = require("ffi/util").template
local Screen = Device.screen

local FULL_REFRESH_EVERY = 6

local LibraryGrid = FocusManager:extend{
    name = "kindleui_library_grid",
    covers_fullscreen = true,
    plugin = nil,
}

function LibraryGrid:init()
    self.t_open = Perf.start()
    self.dimen = Geom:new{ x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight() }
    if Device:hasKeys() then
        self.key_events.Close = { { Device.input.group.Back } }
        self.key_events.NextPage = { { Device.input.group.PgFwd } }
        self.key_events.PrevPage = { { Device.input.group.PgBack } }
    end
    if Device:isTouchDevice() then
        self.ges_events.Swipe = { GestureRange:new{ ges = "swipe", range = self.dimen } }
    end
    self.tiles = {}
    self:computeLayout()
    self.books, self.total_books = Library.loadBooks(self.plugin)
    -- Come back to the page you were on (for this KOReader session).
    self.page = math.max(1, math.min(Library.session.grid_page or 1, self:pageCount()))
    self:buildPage()
end

function LibraryGrid:computeLayout()
    local w, h = self.dimen.w, self.dimen.h
    local margin = Common.SIDE_MARGIN
    local portrait = h >= w
    -- Like a stock Kindle grid: 3 x 3 in portrait, 5 x 2 in landscape.
    self.cols = portrait and 3 or 5
    self.rows = portrait and 3 or 2
    self.gap = Screen:scaleBySize(14)
    self.inner_w = w - 2 * margin
    self.label_face = Font:getFace("cfont", Common.fs(15))
    self.label_h = self.label_face.size * 2
    self.title_bar = TitleBar:new{
        width = w,
        fullscreen = true,
        title = _("My Library"),
        subtitle = " ", -- a subtitle widget must exist for setSubTitle() to work
        with_bottom_line = true,
        left_icon = "appbar.menu",
        left_icon_tap_callback = function() Library.showOptions(self, self.plugin) end,
        close_callback = function() self:onClose() end,
        show_parent = self,
    }
    self.footer_h = Screen:scaleBySize(56)
    local avail_h = h - self.title_bar:getHeight() - self.footer_h - Screen:scaleBySize(20)
    -- Largest 2:3 cover that fits the cell in both directions.
    local cell_w = math.floor((self.inner_w - (self.cols - 1) * self.gap) / self.cols)
    local cell_h = math.floor((avail_h - self.rows * self.gap) / self.rows) - self.label_h
    self.cover_h = math.min(cell_h, math.floor(cell_w * 1.5))
    self.cover_w = math.floor(self.cover_h * 2 / 3)
    self.tile_w = cell_w
    self.per_page = self.cols * self.rows
end

function LibraryGrid:pageCount()
    return math.max(1, math.ceil(#self.books / self.per_page))
end

-- A plain "text cover" for books without a cover image (yet).
function LibraryGrid:textCover(book)
    return Common.textCover(book.title, book.authors, self.cover_w, self.cover_h)
end

-- Tile content: cover (or text cover) + progress label.
function LibraryGrid:tileContent(book)
    local cover
    local bb = Cache.loadCover(book.entry)
    if bb then
        local image = ImageWidget:new{
            image = bb,
            image_disposable = true,
            width = self.cover_w - 2 * Size.border.thin,
            height = self.cover_h - 2 * Size.border.thin,
            scale_factor = 0,
        }
        table.insert(self.images, image)
        cover = CenterContainer:new{
            dimen = Geom:new{ w = self.cover_w, h = self.cover_h },
            FrameContainer:new{ bordersize = Size.border.thin, padding = 0, image },
        }
    else
        cover = self:textCover(book)
    end
    return VerticalGroup:new{
        align = "center",
        CenterContainer:new{ dimen = Geom:new{ w = self.tile_w, h = self.cover_h }, cover },
        CenterContainer:new{
            dimen = Geom:new{ w = self.tile_w, h = self.label_h },
            TextWidget:new{
                text = Library.progressText(book),
                face = self.label_face,
                max_width = self.tile_w,
                fgcolor = Blitbuffer.COLOR_DARK_GRAY,
            },
        },
    }
end

function LibraryGrid:freeImages()
    for __, image in ipairs(self.images or {}) do
        image:free()
    end
    self.images = {}
end

function LibraryGrid:buildPage()
    self:stopExtraction()
    self:freeImages()
    self.tiles = {}
    self.layout = {}
    local first = (self.page - 1) * self.per_page + 1
    local grid = VerticalGroup:new{ align = "left" }
    if #self.books == 0 then
        table.insert(grid, VerticalSpan:new{ width = Screen:scaleBySize(40) })
        table.insert(grid, TextBoxWidget:new{
            text = Library.emptyText(self.total_books),
            face = Common.face("body"),
            width = self.inner_w,
            alignment = "center",
        })
    end
    for r = 1, self.rows do
        local row = HorizontalGroup:new{ align = "top" }
        local layout_row = {}
        for c = 1, self.cols do
            local idx = first + (r - 1) * self.cols + (c - 1)
            local book = self.books[idx]
            if not book then break end
            if c > 1 then table.insert(row, HorizontalSpan:new{ width = self.gap }) end
            local tile = Common.Tappable:new{
                callback = function() self:openBook(book) end,
                hold_callback = function() self:showDetails(book) end,
                self:tileContent(book),
            }
            tile.book = book
            table.insert(self.tiles, tile)
            table.insert(row, tile)
            table.insert(layout_row, tile)
        end
        if #row == 0 then break end
        table.insert(grid, row)
        table.insert(grid, VerticalSpan:new{ width = self.gap })
        table.insert(self.layout, layout_row)
    end

    local pages = self:pageCount()
    local footer = HorizontalGroup:new{
        align = "center",
        Button:new{
            text = "‹", width = Screen:scaleBySize(80), bordersize = 0, text_font_size = 28,
            enabled = self.page > 1, show_parent = self,
            callback = function() self:onPrevPage() end,
        },
        CenterContainer:new{
            dimen = Geom:new{ w = Screen:scaleBySize(220), h = self.footer_h },
            TextWidget:new{
                text = T(_("Page %1 of %2"), self.page, pages),
                face = Common.face("small"),
            },
        },
        Button:new{
            text = "›", width = Screen:scaleBySize(80), bordersize = 0, text_font_size = 28,
            enabled = self.page < pages, show_parent = self,
            callback = function() self:onNextPage() end,
        },
    }

    local content_h = self.dimen.h - self.title_bar:getHeight() - self.footer_h
    self[1] = FrameContainer:new{
        width = self.dimen.w,
        height = self.dimen.h,
        bordersize = 0,
        padding = 0,
        background = Blitbuffer.COLOR_WHITE,
        VerticalGroup:new{
            align = "center",
            self.title_bar,
            -- NB: FrameContainer:getSize() ignores `width`; a CenterContainer
            -- with an explicit dimen is what actually centres the grid.
            CenterContainer:new{
                dimen = Geom:new{ w = self.dimen.w, h = content_h },
                ignore = "height",
                FrameContainer:new{
                    bordersize = 0,
                    padding = 0,
                    padding_top = Screen:scaleBySize(20),
                    grid,
                },
            },
            CenterContainer:new{
                dimen = Geom:new{ w = self.dimen.w, h = self.footer_h },
                footer,
            },
        },
    }
    self.title_bar:setSubTitle(Library.subtitle(#self.books, self.total_books))
    self:moveFocusTo(1, 1, FocusManager.FOCUS_ONLY_ON_NT)
    -- Start after this page has been painted.
    UIManager:nextTick(function()
        if UIManager:isWidgetShown(self) and not self.extract_job then self:scheduleExtraction() end
    end)
end

-- Cover extraction: visible page only, in a child process, while open --------

function LibraryGrid:scheduleExtraction()
    local items, tile_of = {}, {}
    for __, tile in ipairs(self.tiles) do
        if Cache.needsExtraction(tile.book.entry) then
            table.insert(items, { path = tile.book.path, entry = tile.book.entry, w = self.cover_w, h = self.cover_h })
            tile_of[#items] = tile
        end
    end
    if #items == 0 then return end
    local t0 = Perf.start()
    self.extract_job = Extractor.start(items, {
        onResult = function(item)
            for i, it in ipairs(items) do
                if it == item then
                    local tile = tile_of[i]
                    local book = tile.book
                    book.title = book.entry.title or book.title
                    book.authors = book.entry.authors or book.authors
                    -- Swap the tile's content in place and refresh just that tile.
                    tile[1] = self:tileContent(book)
                    UIManager:setDirty(self, function() return "ui", tile.dimen end)
                end
            end
        end,
        onDone = function(job)
            Perf.log("covers extracted (child process)", t0, { books = job.done })
            self.extract_job = nil
        end,
    })
end

function LibraryGrid:stopExtraction()
    if self.extract_job then
        self.extract_job:cancel()
        self.extract_job = nil
    end
end

-- Actions -----------------------------------------------------------------------

function LibraryGrid:openBook(book)
    UIManager:close(self)
    self.plugin:openBook(book.path)
end

function LibraryGrid:showDetails(book)
    local ui = self.plugin and self.plugin.ui
    if ui and ui.bookinfo then
        ui.bookinfo:show(book.path)
    end
end

function LibraryGrid:reload()
    self.books, self.total_books = Library.loadBooks(self.plugin)
    self.page = math.min(self.page, self:pageCount())
    self:buildPage()
    UIManager:setDirty(self, "partial")
end

function LibraryGrid:goToPage(page)
    if page < 1 or page > self:pageCount() or page == self.page then return end
    self.t_open, self.t_label = Perf.start(), "library page turn (to first paint)"
    self.page = page
    self:buildPage()
    -- E-ink: page turns use a quick partial refresh (no black flash); every
    -- FULL_REFRESH_EVERY turns, one full refresh clears the accumulated ghosting
    -- of cover images (like a stock Kindle does).
    self.turns = (self.turns or 0) + 1
    UIManager:setDirty(self, self.turns % FULL_REFRESH_EVERY == 0 and "full" or "partial")
end

function LibraryGrid:onNextPage() self:goToPage(self.page + 1) return true end
function LibraryGrid:onPrevPage() self:goToPage(self.page - 1) return true end

function LibraryGrid:onSwipe(__, ges)
    local BD = require("ui/bidi")
    local direction = BD.flipDirectionIfMirroredUILayout(ges.direction)
    if direction == "west" then
        self:onNextPage()
    elseif direction == "east" then
        self:onPrevPage()
    elseif direction == "south" then
        self:onClose()
    end
    return true
end

function LibraryGrid:paintTo(bb, x, y)
    FocusManager.paintTo(self, bb, x, y)
    if self.t_open then
        Perf.log(self.t_label or "library open (covers, to first paint)", self.t_open, { books = #self.books })
        self.t_open, self.t_label = nil, nil
    end
end

function LibraryGrid:onShow()
    UIManager:setDirty(self, "full")
    return true
end

function LibraryGrid:onClose()
    UIManager:close(self)
    return true
end

function LibraryGrid:onCloseWidget()
    Library.session.grid_page = self.page
    self:stopExtraction()
    self:freeImages()
    Cache.save()
    if self.plugin then self.plugin:onChildClosed() end
end

-- A book is about to open: get out of the way.
function LibraryGrid:onShowingReader()
    UIManager:close(self)
end

return LibraryGrid
