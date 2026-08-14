local MODULE_KEY = "burrow.sleep_cover_crop"
local existing_module = package.loaded[MODULE_KEY]
if existing_module then return existing_module end

local Module = {
    key = MODULE_KEY,
}
package.loaded[MODULE_KEY] = Module

local SETTING = "burrow_screensaver_crop_cover_to_fill"

function Module.apply()
    if Module.applied then return true end

    local ImageWidget = require("ui/widget/imagewidget")
    local Screensaver = require("ui/screensaver")
    local _ = require("l10n.gettext")

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

    -- Keep this beside KOReader's own stretch/rotation controls:
    -- Sleep screen > Wallpaper > Border fill, rotation, and fit.
    local screensaver_menu = require("ui/elements/screensaver_menu")
    local wallpaper_menu
    for _, item in ipairs(screensaver_menu or {}) do
        if item.text == _("Wallpaper") then
            wallpaper_menu = item
            break
        end
    end

    local fit_menu
    local wallpaper_items = wallpaper_menu and wallpaper_menu.sub_item_table
    if type(wallpaper_items) == "table" then
        for _, item in ipairs(wallpaper_items) do
            if item.text == _("Border fill, rotation, and fit") then
                fit_menu = item
                break
            end
        end
    end

    local fit_items = fit_menu and fit_menu.sub_item_table
    if type(fit_items) == "table" then
        local already_present = false
        for _, item in ipairs(fit_items) do
            if item._burrow_sleep_cover_crop_to_fill then
                already_present = true
                break
            end
        end

        if not already_present then
            local crop_item = {
                text = _("Crop book cover to fill screen"),
                help_text = _("Scale the current book cover proportionally until the sleep screen is completely filled, then crop the excess from the edges. This avoids stretching or distorting the cover."),
                _burrow_sleep_cover_crop_to_fill = true,
                enabled_func = function()
                    return G_reader_settings:readSetting("screensaver_type") == "cover"
                end,
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

            -- The native Stretch control is the only text_func item in this
            -- submenu today. Insert Crop immediately after it, with a safe
            -- fallback to the end if KOReader changes the menu structure.
            local insert_at = #fit_items + 1
            for index, item in ipairs(fit_items) do
                if type(item.text_func) == "function"
                    and type(item.checked_func) == "function"
                    and type(item.callback) == "function"
                then
                    insert_at = index + 1
                    break
                end
            end
            table.insert(fit_items, insert_at, crop_item)
        end
    end

    Module.applied = true
    return true
end

return Module
