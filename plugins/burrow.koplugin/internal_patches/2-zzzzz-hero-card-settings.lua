local MODULE_KEY = "burrow.internal.2_zzzzz_hero_card_settings"
local existing_module = package.loaded[MODULE_KEY]
if existing_module then return existing_module end

local Module = {
    key = MODULE_KEY,
    phase = "instance",
    filename = "2-zzzzz-hero-card-settings.lua",
}
package.loaded[MODULE_KEY] = Module

-- Add the hero controls only after Burrow's settings compositor has built its
-- clean Library > View hierarchy. This keeps them independent of the legacy
-- Cover Browser menu structure.
local function applyHeroCardSettings(plugin)
    if not plugin or plugin._burrow_hero_card_settings_v2 then
        return true
    end
    plugin._burrow_hero_card_settings_v2 = true

    local BookInfoManager = require("bookinfomanager")
    local CoverMenu = require("covermenu")
    local Screen = require("device").screen
    local UIManager = require("ui/uimanager")
    local logger = require("logger")
    local _ = require("l10n.gettext")
    local T = require("ffi/util").template

    local HEIGHT_SETTING = "burrow_hero_height_percent"
    local DEFAULT_HEIGHT = 100
    local MIN_HEIGHT = 70
    local MAX_HEIGHT = 140

    local HERO_BOOK_SPACING_SETTING = "burrow_hero_book_spacing"
    local DEFAULT_HERO_BOOK_SPACING = 0
    -- Match the signed range used by the existing horizontal and vertical
    -- cover-spacing controls so all three spacing controls behave consistently.
    local MIN_HERO_BOOK_SPACING = -30
    local MAX_HERO_BOOK_SPACING = 30

    local function round(value)
        if value >= 0 then
            return math.floor(value + 0.5)
        end
        return math.ceil(value - 0.5)
    end

    local function clampInteger(value, default_value, minimum, maximum)
        value = tonumber(value) or default_value
        value = round(value)
        return math.max(minimum, math.min(maximum, value))
    end

    local function getHeight()
        return clampInteger(
            BookInfoManager:getSetting(HEIGHT_SETTING),
            DEFAULT_HEIGHT,
            MIN_HEIGHT,
            MAX_HEIGHT
        )
    end

    local function getHeroBookSpacing()
        return clampInteger(
            BookInfoManager:getSetting(HERO_BOOK_SPACING_SETTING),
            DEFAULT_HERO_BOOK_SPACING,
            MIN_HERO_BOOK_SPACING,
            MAX_HERO_BOOK_SPACING
        )
    end

    local function scaledSigned(value)
        value = clampInteger(
            value,
            DEFAULT_HERO_BOOK_SPACING,
            MIN_HERO_BOOK_SPACING,
            MAX_HERO_BOOK_SPACING
        )
        if value == 0 then return 0 end
        local scaled = Screen:scaleBySize(math.abs(value))
        return value < 0 and -scaled or scaled
    end

    local function textOf(item)
        if not item then return nil end
        if item.text then return item.text end
        if item.text_func then
            local ok, value = pcall(item.text_func)
            if ok then return value end
        end
        return nil
    end

    local function findItem(items, wanted)
        for _, item in ipairs(items or {}) do
            if textOf(item) == wanted then return item end
        end
        return nil
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

    -- Keep the existing hero, card size, cover grid, and touch geometry intact.
    -- We only adjust the vertical height reported by the composite hero titlebar.
    -- Positive values reserve extra blank room below the card; negative values
    -- reduce the reserved height and bring row one closer to the hero.
    local function installHeroBookSpacing()
        local titlebar_index = findUpvalueIndex(CoverMenu.setupLayout, "TitleBar")
        local HeroTitleBar = titlebar_index
            and select(2, debug.getupvalue(CoverMenu.setupLayout, titlebar_index))

        if not HeroTitleBar or type(HeroTitleBar.init) ~= "function" then
            logger.warn("Burrow hero/book spacing: hero titlebar unavailable; leaving geometry unchanged")
            return
        end
        if HeroTitleBar._burrow_hero_book_spacing_v1 then
            return
        end

        local original_init = HeroTitleBar.init
        function HeroTitleBar:init(...)
            original_init(self, ...)

            local delta = scaledSigned(getHeroBookSpacing())
            if delta == 0 or type(self.titlebar_height) ~= "number" then
                return
            end

            self.titlebar_height = math.max(1, self.titlebar_height + delta)
            if self.dimen then
                self.dimen.h = self.titlebar_height
            end
            self._burrow_hero_book_spacing_delta = delta
        end

        HeroTitleBar._burrow_hero_book_spacing_v1 = true
        logger.info("Burrow hero-to-books spacing loaded", getHeroBookSpacing())
    end

    -- This module is applied after the hero composition modules in Burrow's
    -- manifest, so the wrapper captures the final tested HeroTitleBar init path.
    -- Failure here is cosmetic only and must not interfere with settings/menu UI.
    local spacing_ok, spacing_error = pcall(installHeroBookSpacing)
    if not spacing_ok then
        logger.warn("Burrow hero/book spacing could not be applied", spacing_error)
    end

    local function heightItem()
        return {
            _burrow_hero_height_setting = true,
            text_func = function()
                return T(_("Hero card height: %1%"), getHeight())
            end,
            help_text = _("Adjust the hero card's vertical size. The hero cover scales with the card while text keeps its normal readable size."),
            callback = function()
                local SpinWidget = require("ui/widget/spinwidget")
                UIManager:show(SpinWidget:new {
                    title_text = _("Hero card height"),
                    info_text = _("Makes the hero card shorter or taller. The cover scales proportionally, and the description automatically uses whatever space remains. Restart KOReader after saving."),
                    value = getHeight(),
                    default_value = DEFAULT_HEIGHT,
                    value_min = MIN_HEIGHT,
                    value_max = MAX_HEIGHT,
                    value_step = 5,
                    value_hold_step = 10,
                    unit = "%",
                    ok_text = _("Save"),
                    callback = function(spin)
                        BookInfoManager:saveSetting(
                            HEIGHT_SETTING,
                            clampInteger(spin.value, DEFAULT_HEIGHT, MIN_HEIGHT, MAX_HEIGHT)
                        )
                        UIManager:askForRestart()
                    end,
                })
            end,
        }
    end

    local function heroBookSpacingItem()
        return {
            _burrow_hero_book_spacing_setting = true,
            text_func = function()
                return T(_("Hero to books: %1"), getHeroBookSpacing())
            end,
            help_text = _("Adjust the space between the bottom of the hero card and the first row of library covers."),
            callback = function()
                local SpinWidget = require("ui/widget/spinwidget")
                UIManager:show(SpinWidget:new {
                    title_text = _("Hero to books spacing"),
                    info_text = _("0 keeps Burrow's normal spacing. Negative values bring the first row of books closer to the hero card. Positive values add more space. Hero size, cover size, and touch areas do not change. Restart KOReader after saving."),
                    value = getHeroBookSpacing(),
                    default_value = DEFAULT_HERO_BOOK_SPACING,
                    value_min = MIN_HERO_BOOK_SPACING,
                    value_max = MAX_HERO_BOOK_SPACING,
                    value_step = 2,
                    value_hold_step = 5,
                    ok_text = _("Save"),
                    callback = function(spin)
                        BookInfoManager:saveSetting(
                            HERO_BOOK_SPACING_SETTING,
                            clampInteger(
                                spin.value,
                                DEFAULT_HERO_BOOK_SPACING,
                                MIN_HERO_BOOK_SPACING,
                                MAX_HERO_BOOK_SPACING
                            )
                        )
                        UIManager:askForRestart()
                    end,
                })
            end,
        }
    end

    local original_add_to_main_menu = plugin.addToMainMenu
    function plugin:addToMainMenu(menu_items)
        original_add_to_main_menu(self, menu_items)

        local root = menu_items.filemanager_display_mode
        local library = root and findItem(root.sub_item_table, _("Library"))
        local view = library and findItem(library.sub_item_table, _("View"))
        local items = view and view.sub_item_table
        if not items then return end

        local has_height_item = false
        for _, item in ipairs(items) do
            if item._burrow_hero_height_setting then
                has_height_item = true
                break
            end
        end

        if not has_height_item then
            -- Keep hero height beside the other overall Library geometry controls.
            local insert_at = #items + 1
            for index, item in ipairs(items) do
                local text = textOf(item)
                if type(text) == "string" and text:find(_("Titles under covers"), 1, true) then
                    insert_at = index
                    break
                end
            end
            table.insert(items, insert_at, heightItem())
        end

        -- Put the new control inside Library > View > Cover spacing beside the
        -- established Horizontal and Vertical signed spacing controls.
        local cover_spacing = findItem(items, _("Cover spacing"))
        local spacing_items = cover_spacing and cover_spacing.sub_item_table
        if spacing_items then
            local has_spacing_item = false
            for _, item in ipairs(spacing_items) do
                if item._burrow_hero_book_spacing_setting then
                    has_spacing_item = true
                    break
                end
            end
            if not has_spacing_item then
                table.insert(spacing_items, heroBookSpacingItem())
            end
        end
    end

    return true
end

Module.apply = applyHeroCardSettings
return Module
