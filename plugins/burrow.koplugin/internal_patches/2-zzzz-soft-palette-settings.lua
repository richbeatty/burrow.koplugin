local MODULE_KEY = "burrow.internal.2_zzzz_soft_palette_settings"
local existing_module = package.loaded[MODULE_KEY]
if existing_module then return existing_module end

local Module = {
    key = MODULE_KEY,
    phase = "instance",
    filename = "2-zzzz-soft-palette-settings.lua",
}
package.loaded[MODULE_KEY] = Module

function Module.apply(plugin)
    if Module.applied then return true end
    if not plugin or plugin._burrow_soft_palette_settings_patched then
        Module.applied = true
        return true
    end
    plugin._burrow_soft_palette_settings_patched = true

    local BurrowLoader = require("burrow_loader")
    local BurrowSettings = require("burrow_settings")
    local UIManager = require("ui/uimanager")
    local _ = require("l10n.gettext")

    local original_add_to_main_menu = plugin.addToMainMenu
    function plugin:addToMainMenu(menu_items)
        original_add_to_main_menu(self, menu_items)

        local root = menu_items and menu_items.filemanager_display_mode
        local items = root and root.sub_item_table
        if type(items) ~= "table" then return end

        for _, item in ipairs(items) do
            if item._burrow_soft_palette_appearance then
                return
            end
        end

        local function enabled()
            return BurrowSettings:isFeatureEnabled("soft_palette")
        end

        local appearance = {
            text = _("Appearance"),
            _burrow_soft_palette_appearance = true,
            sub_item_table = {
                {
                    text = _("Use softer black and white"),
                    help_text = _("Use Burrow's softer neutral white and black instead of KOReader's pure white and black. Night mode uses KOReader's native inversion. Restart required."),
                    checked_func = enabled,
                    callback = function()
                        local new_enabled = not enabled()
                        BurrowSettings:setFeatureEnabled("soft_palette", new_enabled)
                        if new_enabled then
                            BurrowLoader:clearQuarantine("soft_palette")
                        end
                        UIManager:askForRestart()
                    end,
                },
            },
        }

        -- Burrow Settings currently begins with Library. Appearance belongs
        -- immediately after it, before Navigation and the functional sections.
        table.insert(items, math.min(2, #items + 1), appearance)
    end

    Module.applied = true
    return true
end

return Module
