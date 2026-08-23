local MODULE_KEY = "burrow.internal.2_zzzzz_hero_card_settings"
local existing_module = package.loaded[MODULE_KEY]
if existing_module then return existing_module end

local Module = {
    key = MODULE_KEY,
    phase = "instance",
    filename = "2-zzzzz-hero-card-settings.lua",
}
package.loaded[MODULE_KEY] = Module

-- Add the hero-height control only after Burrow's settings compositor has built
-- its clean Library > View hierarchy. This keeps the control independent of the
-- legacy Cover Browser menu structure.
local function applyHeroCardSettings(plugin)
    if not plugin or plugin._burrow_hero_card_settings_v1 then
        return true
    end
    plugin._burrow_hero_card_settings_v1 = true

    local BookInfoManager = require("bookinfomanager")
    local UIManager = require("ui/uimanager")
    local _ = require("l10n.gettext")
    local T = require("ffi/util").template

    local HEIGHT_SETTING = "burrow_hero_height_percent"
    local DEFAULT_HEIGHT = 100
    local MIN_HEIGHT = 70
    local MAX_HEIGHT = 140

    local function clampInteger(value, default_value, minimum, maximum)
        value = tonumber(value) or default_value
        value = math.floor(value + 0.5)
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

    local original_add_to_main_menu = plugin.addToMainMenu
    function plugin:addToMainMenu(menu_items)
        original_add_to_main_menu(self, menu_items)

        local root = menu_items.filemanager_display_mode
        local library = root and findItem(root.sub_item_table, _("Library"))
        local view = library and findItem(library.sub_item_table, _("View"))
        local items = view and view.sub_item_table
        if not items then return end

        for _, item in ipairs(items) do
            if item._burrow_hero_height_setting then
                return
            end
        end

        -- Keep it beside Cover size / Space between covers because all three
        -- controls describe the visual geometry of the Library home screen.
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

    return true
end

Module.apply = applyHeroCardSettings
return Module
