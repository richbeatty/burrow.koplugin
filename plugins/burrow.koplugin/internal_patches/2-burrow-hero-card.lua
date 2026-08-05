local MODULE_KEY = "burrow.internal.2_burrow_hero_card"
local existing_module = package.loaded[MODULE_KEY]
if existing_module then return existing_module end
local Module = { key = MODULE_KEY, phase = "instance", filename = "2-burrow-hero-card.lua" }
package.loaded[MODULE_KEY] = Module

--[[
    Burrow Hero Card

    Adds a Bookshelf-inspired currently-reading card below Burrow's
    existing icon toolbar without replacing Burrow's grid, footer,
    navigation, automatic-series logic, or book tiles.

    The card shows:
      - the most recently opened book still in progress
      - cover art when available
      - title, author, series, metadata description, and reading progress
      - tap anywhere on the card to reopen the book
      - hold anywhere on the card for a formatted details popup

    Remove this file to disable the hero card.
--]]

local logger = require("logger")

local function patchBurrowHero(plugin)
    local BD = require("ui/bidi")
    local Blitbuffer = require("ffi/blitbuffer")
    local BookInfoManager = require("bookinfomanager")
    local BookList = require("ui/widget/booklist")
    local CenterContainer = require("ui/widget/container/centercontainer")
    local CoverMenu = require("covermenu")
    local FileManager = require("apps/filemanager/filemanager")
    local FileManagerBookInfo = require("apps/filemanager/filemanagerbookinfo")
    local Font = require("ui/font")
    local FrameContainer = require("ui/widget/container/framecontainer")
    local Geom = require("ui/geometry")
    local GestureRange = require("ui/gesturerange")
    local HorizontalGroup = require("ui/widget/horizontalgroup")
    local HorizontalSpan = require("ui/widget/horizontalspan")
    local ImageWidget = require("ui/widget/imagewidget")
    local InputContainer = require("ui/widget/container/inputcontainer")
    local Menu = require("ui/widget/menu")
    local OverlapGroup = require("ui/widget/overlapgroup")
    local ProgressWidget = require("ui/widget/progresswidget")
    local ReadHistory = require("readhistory")
    local Screen = require("device").screen
    local Size = require("ui/size")
    local TextBoxWidget = require("ui/widget/textboxwidget")
    local TextViewer = require("ui/widget/textviewer")
    local TextWidget = require("ui/widget/textwidget")
    local UIManager = require("ui/uimanager")
    local VerticalGroup = require("ui/widget/verticalgroup")
    local VerticalSpan = require("ui/widget/verticalspan")
    local Widget = require("ui/widget/widget")
    local burrow_util = require("burrow_util")

    if CoverMenu._burrow_hero_card_patched then
        return
    end
    CoverMenu._burrow_hero_card_patched = true

    -- Keep the hero compact, but give the description and cover a little
    -- more vertical room without taking over the library.
    local HERO_AREA_H = Screen:scaleBySize(236)
    local HERO_SIDE_MARGIN = Screen:scaleBySize(14)
    local HERO_TOP_BOTTOM_MARGIN = Screen:scaleBySize(8)
    local CARD_PADDING = Screen:scaleBySize(10)
    local COVER_SHADOW = Screen:scaleBySize(3)
    local COVER_RADIUS = math.max(4, Screen:scaleBySize(5))
    local CARD_RADIUS = math.max(4, Screen:scaleBySize(5))

    local function safeFace(name, size, fallback)
        local ok, face = pcall(Font.getFace, Font, name, size)
        if ok and face then
            return face
        end
        return Font:getFace(fallback or "infofont", size)
    end

    local function clampPercent(value)
        local percent = tonumber(value) or 0
        if percent > 1 then
            percent = percent / 100
        end
        if percent < 0 then percent = 0 end
        if percent > 1 then percent = 1 end
        return percent
    end

    local function decodeHtmlEntities(text)
        if text == nil then return nil end
        text = tostring(text)
        text = text:gsub("&nbsp;", " ")
        text = text:gsub("&#160;", " ")
        text = text:gsub("&#x[Aa]0;", " ")
        text = text:gsub("&amp;", "&")
        text = text:gsub("&quot;", '"')
        text = text:gsub("&apos;", "'")
        text = text:gsub("&#39;", "'")
        text = text:gsub("&lt;", "<")
        text = text:gsub("&gt;", ">")
        -- Unknown numeric entities are usually stray spacing or control
        -- characters in EPUB metadata. Remove them instead of displaying
        -- their raw codes in the details popup.
        text = text:gsub("&#[xX]?[%da-fA-F]+;", " ")
        return text
    end

    local function cleanDescription(text)
        if not text or text == "" then
            return nil
        end
        text = tostring(text)
        text = text:gsub("<[bB][rR]%s*/?>", "\n")
        text = text:gsub("</[pP]%s*>", "\n\n")
        text = text:gsub("<[lL][iI][^>]*>", "\n- ")
        text = text:gsub("</[lL][iI]%s*>", "")
        text = text:gsub("<[^>]->", "")
        text = decodeHtmlEntities(text)
        text = text:gsub("\r", "")
        text = text:gsub("[ \t]+", " ")
        text = text:gsub(" *\n *", "\n")
        text = text:gsub("\n\n\n+", "\n\n")
        text = text:match("^%s*(.-)%s*$")
        return text ~= "" and text or nil
    end

    local function fallbackTitle(filepath)
        local filename = filepath and filepath:match("([^/]+)$") or "Book"
        return (filename or "Book"):gsub("%.[^.]+$", "")
    end

    local function selectHeroBook()
        pcall(function() ReadHistory:reload(true) end)

        local fallback_file
        local fallback_state

        -- History is already newest first. Prefer a book explicitly marked
        -- Reading, then fall back to the newest unfinished book.
        for _, item in ipairs(ReadHistory.hist or {}) do
            local filepath = item.file
            if filepath and item.select_enabled ~= false and not item.dim then
                local ok, state = pcall(BookList.getBookInfo, filepath)
                if ok and state and state.been_opened then
                    local percent = clampPercent(state.percent_finished)
                    if state.status == "reading" and percent < 1 then
                        return filepath, state
                    end
                    if not fallback_file and state.status ~= "complete" and percent < 1 then
                        fallback_file = filepath
                        fallback_state = state
                    end
                end
            end
        end

        return fallback_file, fallback_state
    end

    local function loadHeroData(filepath, state)
        if not filepath then
            return nil
        end

        local metadata
        local ok = pcall(function()
            metadata = BookInfoManager:getBookInfo(filepath, true)
        end)

        if not ok then
            logger.warn("Burrow hero: failed loading cached metadata for", filepath)
            metadata = nil
        end

        -- Also read KOReader's sidecar metadata. Burrow's cache is the
        -- source for the cover, while sidecar properties can provide extra
        -- publication details for the hold popup.
        local sidecar_props
        local ok_sidecar = pcall(function()
            local settings = BookList.getDocSettings(filepath)
            local props = settings:readSetting("doc_props") or {}
            sidecar_props = FileManagerBookInfo.extendProps(props, filepath)
        end)
        if not ok_sidecar then
            sidecar_props = nil
        end

        -- A recently opened book might not yet be in Burrow's cache.
        if not metadata then
            metadata = sidecar_props
        end

        metadata = metadata or {}
        sidecar_props = sidecar_props or {}

        local function firstValue(...)
            for i = 1, select("#", ...) do
                local value = select(i, ...)
                if value ~= nil and value ~= "" then
                    return value
                end
            end
            return nil
        end

        local percent = clampPercent(state and state.percent_finished)
        if state and state.status == "complete" then
            percent = 1
        end

        return {
            filepath = filepath,
            title = firstValue(metadata.title, metadata.display_title,
                sidecar_props.title, sidecar_props.display_title) or fallbackTitle(filepath),
            authors = firstValue(metadata.authors, sidecar_props.authors),
            series = firstValue(metadata.series, sidecar_props.series),
            series_index = firstValue(metadata.series_index, sidecar_props.series_index),
            description = cleanDescription(firstValue(metadata.description, sidecar_props.description)),
            pages = firstValue(metadata.pages, sidecar_props.pages),
            language = firstValue(metadata.language, sidecar_props.language),
            keywords = firstValue(metadata.keywords, sidecar_props.keywords),
            publisher = firstValue(metadata.publisher, sidecar_props.publisher),
            published = firstValue(metadata.published, metadata.pubdate,
                sidecar_props.published, sidecar_props.pubdate),
            isbn = firstValue(metadata.isbn, sidecar_props.isbn),
            filesize = firstValue(metadata.filesize, sidecar_props.filesize),
            has_cover = metadata.has_cover and metadata.cover_bb ~= nil,
            cover_bb = metadata.cover_bb,
            percent = percent,
            status = state and state.status or "reading",
            cover_fetched = metadata.cover_fetched,
        }
    end

    local function heroSignature(filepath, state)
        if not filepath then
            return "empty"
        end
        local metadata
        pcall(function()
            metadata = BookInfoManager:getBookInfo(filepath, false)
        end)
        metadata = metadata or {}
        return table.concat({
            filepath,
            tostring(state and state.status or ""),
            string.format("%.4f", clampPercent(state and state.percent_finished)),
            tostring(metadata.cover_fetched or ""),
            tostring(metadata.has_cover or ""),
            tostring(metadata.title or ""),
            tostring(metadata.description and #metadata.description or 0),
        }, "|")
    end

    -- Small custom cover card. It clips the image corners with the page
    -- background and paints one clean rounded border. This avoids depending
    -- on external SVG corner masks.
    local RoundedCover = Widget:extend {
        inner = nil,
        width = nil,
        height = nil,
        radius = 0,
        border_size = 0,
    }

    function RoundedCover:init()
        self.dimen = Geom:new { w = self.width, h = self.height }
    end

    function RoundedCover:getSize()
        return self.dimen
    end

    function RoundedCover:free(...)
        if self.inner and self.inner.free then
            self.inner:free(...)
        end
    end

    function RoundedCover:paintTo(bb, x, y)
        local border = self.border_size or 0
        bb:paintRect(x, y, self.width, self.height, Blitbuffer.COLOR_WHITE)
        if self.inner then
            self.inner:paintTo(bb, x + border, y + border)
        end

        local radius = self.radius or 0
        if radius > 0 then
            local radius_sq = radius * radius
            for dy = 0, radius - 1 do
                local cutoff = 0
                local ddy = dy - radius
                while cutoff < radius
                        and (cutoff - radius) * (cutoff - radius) + ddy * ddy > radius_sq do
                    cutoff = cutoff + 1
                end
                if cutoff > 0 then
                    bb:paintRect(x, y + dy, cutoff, 1, Blitbuffer.COLOR_WHITE)
                    bb:paintRect(x + self.width - cutoff, y + dy, cutoff, 1, Blitbuffer.COLOR_WHITE)
                    bb:paintRect(x, y + self.height - dy - 1, cutoff, 1, Blitbuffer.COLOR_WHITE)
                    bb:paintRect(x + self.width - cutoff, y + self.height - dy - 1,
                        cutoff, 1, Blitbuffer.COLOR_WHITE)
                end
            end
        end

        if border > 0 then
            bb:paintBorder(x, y, self.width, self.height,
                border, Blitbuffer.COLOR_DARK_GRAY, radius, true)
        end
    end

    local HeroCard = InputContainer:extend {
        data = nil,
        width = nil,
        height = nil,
    }

    local function buildCover(data, width, height)
        local border = Size.border.thin
        local inner_w = width - 2 * border
        local inner_h = height - 2 * border
        local inner

        if data and data.has_cover and data.cover_bb then
            inner = ImageWidget:new {
                image = data.cover_bb,
                width = inner_w,
                height = inner_h,
                scale_factor = nil,
                stretch_limit_percentage = 100,
            }
        else
            inner = CenterContainer:new {
                dimen = Geom:new { w = inner_w, h = inner_h },
                TextBoxWidget:new {
                    text = BD.auto(data and data.title or "No cover"),
                    face = safeFace(burrow_util.good_serif_bold, 16, "cfont"),
                    width = math.max(1, inner_w - 2 * Size.padding.default),
                    alignment = "center",
                    height = inner_h,
                    height_adjust = true,
                    height_overflow_show_ellipsis = true,
                },
            }
        end

        local cover = RoundedCover:new {
            inner = inner,
            width = width,
            height = height,
            radius = COVER_RADIUS,
            border_size = border,
        }

        local shadow = FrameContainer:new {
            width = width,
            height = height,
            bordersize = 0,
            padding = 0,
            margin = 0,
            radius = COVER_RADIUS,
            background = Blitbuffer.COLOR_GRAY_C,
            Widget:new { dimen = Geom:new { w = width, h = height } },
        }
        shadow.overlap_offset = { COVER_SHADOW, COVER_SHADOW }

        local stack = OverlapGroup:new {
            dimen = Geom:new {
                w = width + COVER_SHADOW,
                h = height + COVER_SHADOW,
            },
            shadow,
            cover,
        }
        return stack
    end

    local function cleanInline(text)
        if text == nil then return nil end
        text = decodeHtmlEntities(text)
        text = tostring(text):gsub("<[^>]->", " ")
        text = text:gsub("\r", ""):gsub("\n+", ", ")
        text = text:gsub("%s+", " "):match("^%s*(.-)%s*$")
        return text ~= "" and text or nil
    end

    local function cleanKeywords(text)
        text = cleanInline(text)
        if not text then return nil end
        text = text:gsub("%s*[;,|]%s*", ", ")
        text = text:gsub(",%s*,+", ", ")
        text = text:gsub("^,%s*", ""):gsub(",%s*$", "")
        return text ~= "" and text or nil
    end

    local function htmlEscape(text)
        if text == nil then return nil end
        text = tostring(text)
        text = text:gsub("&", "&amp;")
        text = text:gsub("<", "&lt;")
        text = text:gsub(">", "&gt;")
        text = text:gsub('"', "&quot;")
        return text
    end

    local function htmlParagraphs(text)
        text = cleanDescription(text)
        if not text then return nil end
        text = htmlEscape(text)
        local paragraphs = {}
        for paragraph in (text .. "\n\n"):gmatch("(.-)\n\n") do
            paragraph = paragraph:gsub("\n", "<br/>")
            if paragraph ~= "" then
                paragraphs[#paragraphs + 1] = "<p>" .. paragraph .. "</p>"
            end
        end
        return table.concat(paragraphs, "")
    end

    local function statusLabel(status)
        local labels = {
            reading = "Reading",
            complete = "Complete",
            abandoned = "Did not finish",
            new = "Not started",
        }
        return labels[status] or cleanInline(status) or "Reading"
    end

    local function formatFileSize(value)
        value = tonumber(value)
        if not value then return nil end
        local units = { "B", "KB", "MB", "GB" }
        local unit = 1
        while value >= 1024 and unit < #units do
            value = value / 1024
            unit = unit + 1
        end
        if unit == 1 then
            return string.format("%d %s", value, units[unit])
        end
        return string.format("%.1f %s", value, units[unit])
    end

    local function buildFullDetailsHtml(data)
        local sections = {}

        local function addRow(rows, label, value)
            value = cleanInline(value)
            if not value then return end
            rows[#rows + 1] = "<p><b>" .. htmlEscape(label) .. "</b><br/>"
                .. htmlEscape(value) .. "</p>"
        end

        local overview = {}
        addRow(overview, "Author", data.authors)
        if data.series and data.series ~= "" then
            local series = cleanInline(data.series)
            if data.series_index and tostring(data.series_index) ~= "" then
                series = series .. "  #" .. tostring(data.series_index)
            end
            addRow(overview, "Series", series)
        end
        addRow(overview, "Publisher", data.publisher)
        addRow(overview, "Published", data.published)
        if #overview > 0 then
            sections[#sections + 1] = "<h2>Book</h2>" .. table.concat(overview)
        end

        local reading = {}
        addRow(reading, "Status", statusLabel(data.status))
        addRow(reading, "Progress",
            string.format("%d%%", math.floor((data.percent or 0) * 100 + 0.5)))
        addRow(reading, "Pages", data.pages)
        if #reading > 0 then
            sections[#sections + 1] = "<h2>Reading</h2>" .. table.concat(reading)
        end

        local description = htmlParagraphs(data.description)
        if not description then
            description = "<p><i>No description is available in this book's metadata.</i></p>"
        end
        sections[#sections + 1] = "<h2>Description</h2>" .. description

        local edition = {}
        addRow(edition, "Language", data.language)
        addRow(edition, "ISBN", data.isbn)
        addRow(edition, "Keywords", cleanKeywords(data.keywords))
        if #edition > 0 then
            sections[#sections + 1] = "<h2>Edition details</h2>" .. table.concat(edition)
        end

        local file_rows = {}
        local filename = data.filepath and data.filepath:match("([^/]+)$")
        local folder = data.filepath and data.filepath:match("^(.*)/[^/]+$")
        addRow(file_rows, "File", filename)
        addRow(file_rows, "Size", formatFileSize(data.filesize))
        addRow(file_rows, "Folder", folder)
        if #file_rows > 0 then
            sections[#sections + 1] = "<h2>File details</h2>" .. table.concat(file_rows)
        end

        return table.concat(sections, "<hr/>")
    end

    function HeroCard:init()
        self.dimen = Geom:new { w = self.width, h = self.height }
        local data = self.data
        local border = Size.border.thin
        local inner_w = self.width - 2 * border - 2 * CARD_PADDING
        local inner_h = self.height - 2 * border - 2 * CARD_PADDING

        local cover_h = inner_h - COVER_SHADOW
        local cover_w = math.floor(cover_h * 2 / 3)
        local cover = buildCover(data, cover_w, cover_h)
        local gap = Screen:scaleBySize(14)
        local text_w = math.max(Screen:scaleBySize(180), inner_w - cover:getSize().w - gap)

        local status_widget = TextWidget:new {
            text = data and "CONTINUE READING" or "YOUR READING",
            face = safeFace(burrow_util.good_sans_bold, 12, "smallinfofont"),
            bold = true,
            fgcolor = Blitbuffer.COLOR_DARK_GRAY,
            max_width = text_w,
        }

        local title_h = Screen:scaleBySize(50)
        local title_widget = TextBoxWidget:new {
            text = BD.auto(data and data.title or "No book currently in progress"),
            face = safeFace(burrow_util.good_serif_bold, 23, "cfont"),
            width = text_w,
            height = title_h,
            height_adjust = true,
            height_overflow_show_ellipsis = true,
        }

        local authors_widget
        if data and data.authors and data.authors ~= "" then
            authors_widget = TextWidget:new {
                text = BD.auto(data.authors:gsub("\n", ", ")),
                face = safeFace(burrow_util.good_sans, 16, "infofont"),
                max_width = text_w,
            }
        end

        local series_widget
        if data and data.series and data.series ~= "" then
            local series_text = data.series
            if data.series_index then
                series_text = series_text .. "  #" .. tostring(data.series_index)
            end
            series_widget = TextWidget:new {
                text = BD.auto(series_text),
                face = safeFace(burrow_util.good_sans_it, 14, "smallinfofont"),
                fgcolor = Blitbuffer.COLOR_DARK_GRAY,
                max_width = text_w,
            }
        end

        local progress_h = Screen:scaleBySize(18)
        local fixed_h = status_widget:getSize().h
            + title_h
            + (authors_widget and authors_widget:getSize().h or 0)
            + (series_widget and series_widget:getSize().h or 0)
            + progress_h
            + Screen:scaleBySize(22)
        local description_h = math.max(Screen:scaleBySize(34), inner_h - fixed_h)

        local description_widget
        if data and data.description then
            description_widget = TextBoxWidget:new {
                text = BD.auto(data.description),
                face = safeFace(burrow_util.good_serif, 14, "infofont"),
                width = text_w,
                height = description_h,
                height_adjust = true,
                height_overflow_show_ellipsis = true,
                fgcolor = Blitbuffer.COLOR_DARK_GRAY,
            }
        else
            description_widget = VerticalSpan:new { width = description_h }
        end

        local progress_row
        if data then
            local percent_widget = TextWidget:new {
                text = string.format("%d%%", math.floor(data.percent * 100 + 0.5)),
                face = safeFace(burrow_util.good_sans_bold, 13, "smallinfofont"),
                bold = true,
            }
            local percent_w = percent_widget:getSize().w
            local progress_w = math.max(Screen:scaleBySize(80), text_w - percent_w - Screen:scaleBySize(10))
            local progress = ProgressWidget:new {
                width = progress_w,
                height = Screen:scaleBySize(8),
                margin_h = 0,
                margin_v = 0,
                bordersize = Size.border.thin,
                radius = Screen:scaleBySize(2),
                bordercolor = Blitbuffer.COLOR_DARK_GRAY,
                bgcolor = Blitbuffer.COLOR_GRAY_E,
                fillcolor = Blitbuffer.COLOR_GRAY_5,
            }
            progress:setPercentage(data.percent)
            progress_row = HorizontalGroup:new {
                align = "center",
                progress,
                HorizontalSpan:new { width = Screen:scaleBySize(10) },
                percent_widget,
            }
        else
            progress_row = TextWidget:new {
                text = "Open a book and it will appear here.",
                face = safeFace(burrow_util.good_sans, 13, "smallinfofont"),
                fgcolor = Blitbuffer.COLOR_DARK_GRAY,
                max_width = text_w,
            }
        end

        local text_column = VerticalGroup:new {
            align = "left",
            status_widget,
            VerticalSpan:new { width = Screen:scaleBySize(2) },
            title_widget,
        }
        if authors_widget then
            table.insert(text_column, authors_widget)
        end
        if series_widget then
            table.insert(text_column, series_widget)
        end
        table.insert(text_column, VerticalSpan:new { width = Screen:scaleBySize(4) })
        table.insert(text_column, description_widget)
        table.insert(text_column, VerticalSpan:new { width = Screen:scaleBySize(5) })
        table.insert(text_column, progress_row)

        local content = HorizontalGroup:new {
            align = "center",
            cover,
            HorizontalSpan:new { width = gap },
            text_column,
        }

        self[1] = FrameContainer:new {
            width = self.width,
            height = self.height,
            margin = 0,
            padding = CARD_PADDING,
            bordersize = border,
            radius = CARD_RADIUS,
            color = Blitbuffer.COLOR_GRAY_6,
            background = Blitbuffer.COLOR_WHITE,
            content,
        }

        if data and data.filepath then
            self.ges_events = {
                TapHero = {
                    GestureRange:new {
                        ges = "tap",
                        range = self.dimen,
                    },
                },
                HoldHero = {
                    GestureRange:new {
                        ges = "hold",
                        range = self.dimen,
                    },
                },
            }
        end
    end

    function HeroCard:onTapHero()
        if self.data and self.data.filepath and FileManager.instance then
            FileManager.instance:openFile(self.data.filepath)
            return true
        end
    end

    function HeroCard:onHoldHero()
        if not self.data then
            return false
        end

        UIManager:show(TextViewer:new {
            title = BD.auto(self.data.title or "Book details"),
            text = buildFullDetailsHtml(self.data),
            text_type = "general",
            text_format = "html",
            alignment = "left",
            title_multilines = true,
            title_shrink_font_to_fit = true,
            show_menu = false,
            add_default_buttons = true,
        })
        return true
    end

    local function buildHeroArea(filepath, state)
        local card_w = Screen:getWidth() - 2 * HERO_SIDE_MARGIN
        local card_h = HERO_AREA_H - 2 * HERO_TOP_BOTTOM_MARGIN
        local data = loadHeroData(filepath, state)
        local card = HeroCard:new {
            data = data,
            width = card_w,
            height = card_h,
        }
        return CenterContainer:new {
            dimen = Geom:new { w = Screen:getWidth(), h = HERO_AREA_H },
            card,
        }
    end

    local function findUpvalueIndex(func, wanted_name)
        local index = 1
        while true do
            local name = debug.getupvalue(func, index)
            if not name then
                return nil
            end
            if name == wanted_name then
                return index
            end
            index = index + 1
        end
    end

    local titlebar_upvalue_index = findUpvalueIndex(CoverMenu.setupLayout, "TitleBar")
    local OriginalTitleBar = titlebar_upvalue_index
        and select(2, debug.getupvalue(CoverMenu.setupLayout, titlebar_upvalue_index))

    if not titlebar_upvalue_index or not OriginalTitleBar then
        logger.warn("Burrow hero: could not find Burrow TitleBar upvalue")
        CoverMenu._burrow_hero_card_patched = nil
        return
    end

    -- Composite wrapper: the untouched Burrow toolbar remains the first
    -- child; the hero is a separate second child below it. This means the
    -- existing grid simply sees a taller titlebar and uses its normal sizing.
    local HeroTitleBar = InputContainer:extend {}

    function HeroTitleBar:init()
        self._toolbar = OriginalTitleBar:new {
            left1_icon = self.left1_icon,
            left1_icon_tap_callback = self.left1_icon_tap_callback,
            left1_icon_hold_callback = self.left1_icon_hold_callback,
            left2_icon = self.left2_icon,
            left2_icon_tap_callback = self.left2_icon_tap_callback,
            left2_icon_hold_callback = self.left2_icon_hold_callback,
            left3_icon = self.left3_icon,
            left3_icon_tap_callback = self.left3_icon_tap_callback,
            left3_icon_hold_callback = self.left3_icon_hold_callback,
            center_icon = self.center_icon,
            center_icon_tap_callback = self.center_icon_tap_callback,
            center_icon_hold_callback = self.center_icon_hold_callback,
            right3_icon = self.right3_icon,
            right3_icon_tap_callback = self.right3_icon_tap_callback,
            right3_icon_hold_callback = self.right3_icon_hold_callback,
            right2_icon = self.right2_icon,
            right2_icon_tap_callback = self.right2_icon_tap_callback,
            right2_icon_hold_callback = self.right2_icon_hold_callback,
            right1_icon = self.right1_icon,
            right1_icon_tap_callback = self.right1_icon_tap_callback,
            right1_icon_hold_callback = self.right1_icon_hold_callback,
            show_parent = self.show_parent,
            title = self.title,
            subtitle = self.subtitle,
        }

        local filepath, state = selectHeroBook()
        self._hero_signature = heroSignature(filepath, state)
        self._hero_area = buildHeroArea(filepath, state)
        self._stack = VerticalGroup:new {
            align = "left",
            self._toolbar,
            self._hero_area,
        }

        -- Mirror Burrow's public button fields so FileManager and any
        -- unrelated titlebar patches still see the same interface.
        self.left1_button = self._toolbar.left1_button
        self.left2_button = self._toolbar.left2_button
        self.left3_button = self._toolbar.left3_button
        self.center_button = self._toolbar.center_button
        self.right3_button = self._toolbar.right3_button
        self.right2_button = self._toolbar.right2_button
        self.right1_button = self._toolbar.right1_button
        self.left_button = self._toolbar.left_button
        self.right_button = self._toolbar.right_button

        self.titlebar_height = self._toolbar:getHeight() + HERO_AREA_H
        self.dimen = Geom:new {
            x = 0,
            y = 0,
            w = Screen:getWidth(),
            h = self.titlebar_height,
        }
        self[1] = self._stack
    end

    function HeroTitleBar:refreshHero(force)
        local filepath, state = selectHeroBook()
        local signature = heroSignature(filepath, state)
        if not force and signature == self._hero_signature then
            return false
        end

        local ok, new_area = pcall(buildHeroArea, filepath, state)
        if not ok or not new_area then
            logger.warn("Burrow hero: refresh failed", tostring(new_area))
            return false
        end

        local old_area = self._hero_area
        self._hero_area = new_area
        self._hero_signature = signature
        self._stack[2] = new_area
        if self._stack.resetLayout then
            self._stack:resetLayout()
        end
        if old_area and old_area.free then
            old_area:free()
        end
        return true
    end

    function HeroTitleBar:getHeight()
        return self.titlebar_height
    end

    function HeroTitleBar:setTitle(...)
        return self._toolbar:setTitle(...)
    end

    function HeroTitleBar:setSubTitle(...)
        return self._toolbar:setSubTitle(...)
    end

    function HeroTitleBar:setLeftIcon(...)
        return self._toolbar:setLeftIcon(...)
    end

    function HeroTitleBar:setRightIcon(...)
        return self._toolbar:setRightIcon(...)
    end

    function HeroTitleBar:generateHorizontalLayout(...)
        return self._toolbar:generateHorizontalLayout(...)
    end

    function HeroTitleBar:generateVerticalLayout(...)
        return self._toolbar:generateVerticalLayout(...)
    end

    function HeroTitleBar:paintTo(bb, x, y)
        self.dimen.x = x
        self.dimen.y = y
        InputContainer.paintTo(self, bb, x, y)
    end

    debug.setupvalue(CoverMenu.setupLayout, titlebar_upvalue_index, HeroTitleBar)

    -- Refresh the hero through Burrow's normal page update. We patch the
    -- Menu method too only when it still points at this exact CoverMenu method,
    -- matching Burrow's own method-installation pattern.
    local original_update_items = CoverMenu.updateItems
    local menu_was_using_covermenu_update = Menu.updateItems == original_update_items

    function CoverMenu:updateItems(...)
        if self.title_bar and self.title_bar.refreshHero then
            pcall(self.title_bar.refreshHero, self.title_bar, false)
        end
        return original_update_items(self, ...)
    end

    if menu_was_using_covermenu_update then
        Menu.updateItems = CoverMenu.updateItems
    end

    logger.info("Burrow hero card patch loaded")
end

Module.apply = patchBurrowHero
return Module
