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
