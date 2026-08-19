local MODULE_KEY = "burrow.internal.2_hero_card_grid_alignment"
local existing_module = package.loaded[MODULE_KEY]
if existing_module then return existing_module end

local Module = {
    key = MODULE_KEY,
    phase = "instance",
    filename = "2-hero-card-grid-alignment.lua",
}
package.loaded[MODULE_KEY] = Module

local function patchHeroGridAlignment(plugin)
    local BookInfoManager = require("bookinfomanager")
    local CoverMenu = require("covermenu")
    local Menu = require("ui/widget/menu")
    local Screen = require("device").screen
    local UIManager = require("ui/uimanager")
    local logger = require("logger")

    if CoverMenu._burrow_hero_grid_alignment_v1 then
        return true
    end

    local function round(value)
        if value >= 0 then
            return math.floor(value + 0.5)
        end
        return math.ceil(value - 0.5)
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

    -- The hero module deliberately installs its composite TitleBar into this
    -- upvalue. Retrieve that existing class rather than replacing the titlebar
    -- or rebuilding any of its UI ourselves.
    local titlebar_index = findUpvalueIndex(CoverMenu.setupLayout, "TitleBar")
    local HeroTitleBar = titlebar_index
        and select(2, debug.getupvalue(CoverMenu.setupLayout, titlebar_index))

    if not HeroTitleBar or type(HeroTitleBar.refreshHero) ~= "function" then
        logger.warn("Burrow hero alignment: hero titlebar unavailable; leaving existing geometry unchanged")
        return true
    end

    -- buildHeroArea owns the existing HERO_SIDE_MARGIN upvalue. Updating that
    -- single value lets the existing hero rebuild itself normally, preserving
    -- all current cover, text, progress, tap, hold, and refresh behavior.
    local build_index = findUpvalueIndex(HeroTitleBar.refreshHero, "buildHeroArea")
    local buildHeroArea = build_index
        and select(2, debug.getupvalue(HeroTitleBar.refreshHero, build_index))
    local margin_index = findUpvalueIndex(buildHeroArea, "HERO_SIDE_MARGIN")
    local default_side_margin
    if margin_index then
        local _, value = debug.getupvalue(buildHeroArea, margin_index)
        default_side_margin = value
    end

    if not buildHeroArea or not margin_index or type(default_side_margin) ~= "number" then
        logger.warn("Burrow hero alignment: hero margin upvalue unavailable; leaving existing geometry unchanged")
        return true
    end

    local function widgetWidth(widget)
        if type(widget) ~= "table" then return nil end
        if type(widget.getSize) == "function" then
            local ok, size = pcall(widget.getSize, widget)
            if ok and size and tonumber(size.w) and tonumber(size.w) > 0 then
                return tonumber(size.w)
            end
        end
        if widget.dimen and tonumber(widget.dimen.w) and tonumber(widget.dimen.w) > 0 then
            return tonumber(widget.dimen.w)
        end
        if tonumber(widget.width) and tonumber(widget.width) > 0 then
            return tonumber(widget.width)
        end
    end

    local function findRenderedCoverWidth(widget, seen)
        if type(widget) ~= "table" then return nil end
        seen = seen or {}
        if seen[widget] then return nil end
        seen[widget] = true

        -- The final Burrow cover-layout pass stores the exact frame it resized
        -- on every normal book, physical folder, and virtual series tile.
        local explicit = widget._burrow_primary_cover_frame
            or widget._burrow_cover_size_frame
        local width = widgetWidth(explicit)
        if width then return width end

        for i = 1, #widget do
            width = findRenderedCoverWidth(widget[i], seen)
            if width then return width end
        end
        return nil
    end

    local function normalizeGap(value)
        value = tonumber(value) or 0
        value = math.floor(value + 0.5)
        if value < 0 then value = 0 end
        if value > 30 then value = 30 end
        return value
    end

    local function alignedSideMargin(menu)
        if type(menu) ~= "table" then return default_side_margin end

        local columns = tonumber(menu.nb_cols)
        local item_width = tonumber(menu.item_width)
        local item_margin = tonumber(menu.item_margin)
        if not columns or columns < 2 or not item_width or not item_margin then
            -- One-column and non-grid layouts keep the existing hero geometry.
            -- The current hero is a horizontal cover-and-text card and would be
            -- unusably narrow if forced to the width of a single small cover.
            return default_side_margin
        end

        local cover_width = findRenderedCoverWidth(menu.item_group)
        if not cover_width then
            return default_side_margin
        end

        -- Cover gap reduction shifts whole tiles inward toward the center.
        -- Mirror the exact shift used by the final cover-layout paint wrapper.
        local gap_step = Screen:scaleBySize(normalizeGap(
            BookInfoManager:getSetting("burrow_cover_gap_reduction")
        ))
        local center_column = (columns + 1) / 2
        local first_shift = round((center_column - 1) * gap_step)
        local last_shift = round((center_column - columns) * gap_step)

        -- Centers of the first and last grid tiles are separated by one item
        -- width plus one item margin per column step. Add the exact rendered
        -- cover width, then apply the inward shifts from gap reduction.
        local cover_span = (columns - 1) * (item_width + item_margin)
            + last_shift - first_shift + cover_width

        local screen_width = Screen:getWidth()
        cover_span = math.max(1, math.min(screen_width, round(cover_span)))

        -- Preserve the current horizontal hero on very narrow grids rather than
        -- allowing its cover and text to overlap. Standard multi-column grids
        -- align exactly; narrow layouts retain the existing safe card width.
        local current_card_width = screen_width - 2 * default_side_margin
        local minimum_safe_width = math.min(current_card_width, Screen:scaleBySize(360))
        if cover_span < minimum_safe_width then
            return default_side_margin
        end

        return math.max(0, round((screen_width - cover_span) / 2))
    end

    local original_update_items = CoverMenu.updateItems
    local menu_was_using_covermenu_update = Menu.updateItems == original_update_items

    function CoverMenu:updateItems(...)
        -- Let every existing Burrow layer build the page first. In particular,
        -- this gives the final cover-layout wrapper a chance to expose the exact
        -- rendered cover frame width before we measure anything.
        local result = original_update_items(self, ...)

        local target_margin = alignedSideMargin(self)
        local _, current_margin = debug.getupvalue(buildHeroArea, margin_index)
        if current_margin ~= target_margin then
            debug.setupvalue(buildHeroArea, margin_index, target_margin)
            if self.title_bar and type(self.title_bar.refreshHero) == "function" then
                local ok, changed = pcall(self.title_bar.refreshHero, self.title_bar, true)
                if not ok then
                    -- Restore the known-safe original width immediately. This
                    -- layer is cosmetic and must never strand the library UI.
                    debug.setupvalue(buildHeroArea, margin_index, default_side_margin)
                    logger.warn("Burrow hero alignment: refresh failed; restored default margin", tostring(changed))
                elseif changed and self.show_parent then
                    UIManager:setDirty(self.show_parent, "ui")
                end
            end
        end

        return result
    end

    if menu_was_using_covermenu_update then
        Menu.updateItems = CoverMenu.updateItems
    end

    CoverMenu._burrow_hero_grid_alignment_v1 = true
    logger.info("Burrow hero grid alignment loaded")
    return true
end

Module.apply = patchHeroGridAlignment
return Module
