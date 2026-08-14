local MODULE_KEY = "burrow.sleep_cover_crop"
local existing_module = package.loaded[MODULE_KEY]
if existing_module then return existing_module end

local Module = {
    key = MODULE_KEY,
}
package.loaded[MODULE_KEY] = Module

local SETTING = "burrow_screensaver_crop_cover_to_fill"

local function makeSettingsItem(_)
    return {
        text = _("Crop sleep-screen book cover to fill"),
        help_text = _("Scale the current book cover proportionally until the sleep screen is completely filled, then crop the excess from the edges. This avoids stretching or distorting the cover."),
        _burrow_sleep_cover_crop_setting = true,
        checked_func = function()
            return G_reader_settings:isTrue(SETTING)
        end,
        callback = function()
            G_reader_settings:saveSetting(
                SETTING,
                not G_reader_settings:isTrue(SETTING)
            )
            if type(G_reader_settings.flush) == "function" then
                G_reader_settings:flush()
            end
        end,
    }
end

local function attachBurrowSettings(plugin)
    if type(plugin) ~= "table"
        or plugin._burrow_sleep_cover_settings_patched
        or type(plugin.addToMainMenu) ~= "function"
    then
        return
    end

    plugin._burrow_sleep_cover_settings_patched = true
    local original_add_to_main_menu = plugin.addToMainMenu
    local _ = require("l10n.gettext")

    function plugin:addToMainMenu(menu_items)
        original_add_to_main_menu(self, menu_items)

        local root = menu_items and menu_items.filemanager_display_mode
        local items = root and root.sub_item_table
        if type(items) ~= "table" then return end

        local appearance
        for _, item in ipairs(items) do
            if type(item) == "table"
                and (item._burrow_soft_palette_appearance or item.text == _("Appearance"))
            then
                appearance = item
                break
            end
        end

        local appearance_items = appearance and appearance.sub_item_table
        if type(appearance_items) ~= "table" then return end

        for _, item in ipairs(appearance_items) do
            if type(item) == "table" and item._burrow_sleep_cover_crop_setting then
                return
            end
        end

        table.insert(appearance_items, makeSettingsItem(_))
    end
end

function Module.apply(plugin)
    -- Use Burrow's existing menu callback rather than modifying KOReader's
    -- native Sleep screen menu. This keeps the setting isolated to
    -- Burrow Settings > Appearance and avoids touching the global menu builder.
    attachBurrowSettings(plugin)

    if Module.applied then return true end

    local ImageWidget = require("ui/widget/imagewidget")
    local Screensaver = require("ui/screensaver")

    if G_reader_settings:readSetting(SETTING) == nil then
        G_reader_settings:saveSetting(SETTING, true)
    end

    if not Screensaver._burrow_crop_book_cover_to_fill_v1 then
        Screensaver._burrow_crop_book_cover_to_fill_v1 = true
        local original_screensaver_show = Screensaver.show

        function Screensaver:show(...)
            if not G_reader_settings:isTrue(SETTING)
                or self.screensaver_type ~= "cover"
                or not self.image
            then
                return original_screensaver_show(self, ...)
            end

            local screensaver = self
            local original_imagewidget_new = ImageWidget.new
            local crop_applied = false

            -- Scope the constructor shim to this Screensaver:show() call and
            -- match the exact cover buffer prepared by Screensaver:setup().
            -- The proportional scale fills the viewport; ImageWidget then
            -- clips the centered overflow instead of stretching the cover.
            function ImageWidget:new(settings)
                if not crop_applied
                    and type(settings) == "table"
                    and settings.image == screensaver.image
                    and tonumber(settings.width)
                    and tonumber(settings.height)
                then
                    local image_w = screensaver.image:getWidth()
                    local image_h = screensaver.image:getHeight()
                    local angle = tonumber(settings.rotation_angle) or 0
                    angle = ((angle % 360) + 360) % 360
                    if angle == 90 or angle == 270 then
                        image_w, image_h = image_h, image_w
                    end

                    if image_w > 0 and image_h > 0 then
                        local cropped = {}
                        for key, value in pairs(settings) do
                            cropped[key] = value
                        end
                        cropped.scale_factor = math.max(
                            cropped.width / image_w,
                            cropped.height / image_h
                        )
                        cropped.stretch_limit_percentage = nil
                        cropped.center_x_ratio = 0.5
                        cropped.center_y_ratio = 0.5
                        settings = cropped
                        crop_applied = true
                    end
                end
                return original_imagewidget_new(self, settings)
            end

            local results = { pcall(original_screensaver_show, self, ...) }
            ImageWidget.new = original_imagewidget_new

            local ok = table.remove(results, 1)
            if not ok then
                error(results[1])
            end
            return unpack(results)
        end
    end

    Module.applied = true
    return true
end

return Module
