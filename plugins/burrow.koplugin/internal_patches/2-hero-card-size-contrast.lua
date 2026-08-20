local MODULE_KEY = "burrow.internal.2_hero_card_size_contrast"
local existing_module = package.loaded[MODULE_KEY]
if existing_module then return existing_module end

local Module = {
    key = MODULE_KEY,
    phase = "instance",
    filename = "2-hero-card-size-contrast.lua",
}
package.loaded[MODULE_KEY] = Module

-- Burrow Hero Card vertical sizing + e-ink readability.
--
-- This deliberately layers on top of the existing hero implementation instead
-- of replacing the titlebar, grid, or navigation. The selected height is read
-- once at startup. A restart is therefore required after changing the setting,
-- which keeps FileManager geometry stable while it is on screen.

local function patchHeroSizeAndContrast(plugin)
    local BD = require("ui/bidi")
    local Blitbuffer = require("ffi/blitbuffer")
    local BookInfoManager = require("bookinfomanager")
    local CoverMenu = require("covermenu")
    local FrameContainer = require("ui/widget/container/framecontainer")
    local Geom = require("ui/geometry")
    local HorizontalGroup = require("ui/widget/horizontalgroup")
    local HorizontalSpan = require("ui/widget/horizontalspan")
    local ProgressWidget = require("ui/widget/progresswidget")
    local Screen = require("device").screen
    local Size = require("ui/size")
    local TextBoxWidget = require("ui/widget/textboxwidget")
    local TextWidget = require("ui/widget/textwidget")
    local VerticalGroup = require("ui/widget/verticalgroup")
    local VerticalSpan = require("ui/widget/verticalspan")
    local burrow_util = require("burrow_util")
    local logger = require("logger")

    if CoverMenu._burrow_hero_size_contrast_v1 then
        return true
    end

    local HEIGHT_SETTING = "burrow_hero_height_percent"
    local DEFAULT_HEIGHT = 100
    local MIN_HEIGHT = 70
    local MAX_HEIGHT = 140
    local BASE_AREA_H = Screen:scaleBySize(236)

    local function clampInteger(value, default_value, minimum, maximum)
        value = tonumber(value) or default_value
        value = math.floor(value + 0.5)
        return math.max(minimum, math.min(maximum, value))
    end

    local function findUpvalueIndex(func, wanted_name)
        if type(func) ~= "function" then return nil end
        local index = 1
        while true do
            local name = debug.getupvalue(func, index)
            if not name then return nil end
            if name == wanted_name then return index end
            index = index + 1
        end
    end

    local function getUpvalue(func, wanted_name)
        local index = findUpvalueIndex(func, wanted_name)
        if not index then return nil, nil end
        local _, value = debug.getupvalue(func, index)
        return value, index
    end

    -- The hero module installs its composite TitleBar into CoverMenu.setupLayout.
    -- Reuse that class and its existing buildHeroArea closure so width alignment,
    -- hero refreshes, tap/hold behavior, and all surrounding UI remain untouched.
    local HeroTitleBar = select(1, getUpvalue(CoverMenu.setupLayout, "TitleBar"))
    if not HeroTitleBar or type(HeroTitleBar.refreshHero) ~= "function" then
        logger.warn("Burrow hero sizing: hero titlebar unavailable; leaving hero unchanged")
        return true
    end

    local buildHeroArea = select(1, getUpvalue(HeroTitleBar.refreshHero, "buildHeroArea"))
    if type(buildHeroArea) ~= "function" then
        logger.warn("Burrow hero sizing: buildHeroArea unavailable; leaving hero unchanged")
        return true
    end

    local HeroCard = select(1, getUpvalue(buildHeroArea, "HeroCard"))
    local area_height_index = select(2, getUpvalue(buildHeroArea, "HERO_AREA_H"))
    if not HeroCard or type(HeroCard.init) ~= "function" or not area_height_index then
        logger.warn("Burrow hero sizing: hero class or height upvalue unavailable; leaving hero unchanged")
        return true
    end

    local original_init = HeroCard.init
    local buildCover = select(1, getUpvalue(original_init, "buildCover"))
    local safeFace = select(1, getUpvalue(original_init, "safeFace"))
    if type(buildCover) ~= "function" or type(safeFace) ~= "function" then
        logger.warn("Burrow hero sizing: hero helpers unavailable; leaving hero unchanged")
        return true
    end

    local selected_height = clampInteger(
        BookInfoManager:getSetting(HEIGHT_SETTING),
        DEFAULT_HEIGHT,
        MIN_HEIGHT,
        MAX_HEIGHT
    )
    local area_height = math.max(1, math.floor(BASE_AREA_H * selected_height / 100 + 0.5))

    -- HERO_AREA_H is a shared upvalue used by buildHeroArea and HeroTitleBar:init.
    -- Mutating the shared cell before any titlebar instance is constructed keeps
    -- the card, its containing area, and FileManager's titlebar height in lockstep.
    debug.setupvalue(buildHeroArea, area_height_index, area_height)

    local CARD_PADDING = Screen:scaleBySize(10)
    local COVER_SHADOW = Screen:scaleBySize(3)
    local CARD_RADIUS = math.max(4, Screen:scaleBySize(5))
    local TEXT_GAP = Screen:scaleBySize(14)
    local STATUS_GAP = Screen:scaleBySize(2)
    local DESCRIPTION_TOP_GAP = Screen:scaleBySize(4)
    local DESCRIPTION_BOTTOM_GAP = Screen:scaleBySize(5)
    local MIN_DESCRIPTION_H = Screen:scaleBySize(18)

    function HeroCard:init()
        self.dimen = Geom:new { w = self.width, h = self.height }
        local data = self.data
        local border = Size.border.thin
        local inner_w = math.max(1, self.width - 2 * border - 2 * CARD_PADDING)
        local inner_h = math.max(1, self.height - 2 * border - 2 * CARD_PADDING)

        -- The cover remains derived from the card's inner height. Shorter hero
        -- settings therefore shrink it naturally; taller settings grow it while
        -- preserving the exact 2:3 ratio used by the existing hero.
        local min_text_w = Screen:scaleBySize(180)
        local desired_cover_h = math.max(1, inner_h - COVER_SHADOW)
        local max_cover_w_for_text = math.max(1,
            inner_w - TEXT_GAP - min_text_w - COVER_SHADOW
        )
        local max_cover_h_for_text = math.max(1, math.floor(max_cover_w_for_text * 3 / 2))
        local cover_h = math.min(desired_cover_h, max_cover_h_for_text)
        local cover_w = math.max(1, math.floor(cover_h * 2 / 3))
        local cover = buildCover(data, cover_w, cover_h)
        local text_w = math.max(1, inner_w - cover:getSize().w - TEXT_GAP)

        -- E-ink contrast: secondary copy used to be DARK_GRAY, which can look
        -- washed out on Kindle panels. Use black text for the small status line,
        -- series line, and description while retaining size/weight hierarchy.
        local status_widget = TextWidget:new {
            text = data and "CONTINUE READING" or "YOUR READING",
            face = safeFace(burrow_util.good_sans_bold, 12, "smallinfofont"),
            bold = true,
            fgcolor = Blitbuffer.COLOR_BLACK,
            max_width = text_w,
        }

        -- Keep a two-line safety cap for long titles, but height_adjust makes the
        -- widget collapse to the ACTUAL rendered height when one line is enough.
        -- This reclaimed space is handed directly to the description below.
        local title_widget = TextBoxWidget:new {
            text = BD.auto(data and data.title or "No book currently in progress"),
            face = safeFace(burrow_util.good_serif_bold, 23, "cfont"),
            width = text_w,
            height = Screen:scaleBySize(50),
            height_adjust = true,
            height_overflow_show_ellipsis = true,
            fgcolor = Blitbuffer.COLOR_BLACK,
        }

        local authors_widget
        if data and data.authors and data.authors ~= "" then
            authors_widget = TextWidget:new {
                text = BD.auto(data.authors:gsub("\n", ", ")),
                face = safeFace(burrow_util.good_sans, 16, "infofont"),
                fgcolor = Blitbuffer.COLOR_BLACK,
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
                fgcolor = Blitbuffer.COLOR_BLACK,
                max_width = text_w,
            }
        end

        -- Build the progress row BEFORE calculating description height so we use
        -- its real rendered height rather than reserving a guessed block.
        local progress_row
        if data then
            local percent_widget = TextWidget:new {
                text = string.format("%d%%", math.floor(data.percent * 100 + 0.5)),
                face = safeFace(burrow_util.good_sans_bold, 13, "smallinfofont"),
                bold = true,
                fgcolor = Blitbuffer.COLOR_BLACK,
            }
            local percent_w = percent_widget:getSize().w
            local progress_w = math.max(
                Screen:scaleBySize(80),
                text_w - percent_w - Screen:scaleBySize(10)
            )
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
                fgcolor = Blitbuffer.COLOR_BLACK,
                max_width = text_w,
            }
        end

        local fixed_h = status_widget:getSize().h
            + STATUS_GAP
            + title_widget:getSize().h
            + (authors_widget and authors_widget:getSize().h or 0)
            + (series_widget and series_widget:getSize().h or 0)
            + DESCRIPTION_TOP_GAP
            + DESCRIPTION_BOTTOM_GAP
            + progress_row:getSize().h

        local available_description_h = math.max(0, inner_h - fixed_h)
        local description_widget
        if data and data.description and available_description_h >= MIN_DESCRIPTION_H then
            description_widget = TextBoxWidget:new {
                text = BD.auto(data.description),
                face = safeFace(burrow_util.good_serif, 14, "infofont"),
                width = text_w,
                height = available_description_h,
                -- Keep the box at the full remaining height so the progress row
                -- stays anchored to the bottom of the text column.
                height_adjust = false,
                height_overflow_show_ellipsis = true,
                fgcolor = Blitbuffer.COLOR_BLACK,
            }
        else
            -- On the smallest hero sizes, preserve title/author/progress first.
            -- Description is the first content allowed to collapse away.
            description_widget = VerticalSpan:new { width = available_description_h }
        end

        local text_column = VerticalGroup:new {
            align = "left",
            status_widget,
            VerticalSpan:new { width = STATUS_GAP },
            title_widget,
        }
        if authors_widget then
            table.insert(text_column, authors_widget)
        end
        if series_widget then
            table.insert(text_column, series_widget)
        end
        table.insert(text_column, VerticalSpan:new { width = DESCRIPTION_TOP_GAP })
        table.insert(text_column, description_widget)
        table.insert(text_column, VerticalSpan:new { width = DESCRIPTION_BOTTOM_GAP })
        table.insert(text_column, progress_row)

        local content = HorizontalGroup:new {
            align = "center",
            cover,
            HorizontalSpan:new { width = TEXT_GAP },
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

        -- Preserve the exact tap/hold gesture behavior from the original hero.
        -- GestureRange and FileManager are only needed when the hero has a book.
        if data and data.filepath then
            local GestureRange = require("ui/gesturerange")
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

    CoverMenu._burrow_hero_size_contrast_v1 = true
    logger.info("Burrow hero height/contrast loaded", selected_height .. "%")
    return true
end

Module.apply = patchHeroSizeAndContrast
return Module
