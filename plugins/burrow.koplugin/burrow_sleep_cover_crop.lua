local MODULE_KEY = "burrow.sleep_cover_crop"
local existing_module = package.loaded[MODULE_KEY]
if existing_module then return existing_module end

local Module = {
    key = MODULE_KEY,
}
package.loaded[MODULE_KEY] = Module

local SETTING = "burrow_screensaver_crop_cover_to_fill"

local function makeCropItem(_)
    return {
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
end

local function findFitItems(items, _, seen)
    if type(items) ~= "table" then return nil end
    seen = seen or {}
    if seen[items] then return nil end
    seen[items] = true

    for _, item in pairs(items) do
        if type(item) == "table" then
            if item.text == _("Border fill, rotation, and fit")
                and type(item.sub_item_table) == "table"
            then
                return item.sub_item_table
            end
            local nested = findFitItems(item.sub_item_table, _, seen)
            if nested then return nested end
        end
    end
end

local function injectCropItem(menu_items, _)
    local fit_items = findFitItems(menu_items, _)
    if type(fit_items) ~= "table" then return false end

    for _, item in ipairs(fit_items) do
        if item._burrow_sleep_cover_crop_to_fill then
            return true
        end
    end

    local crop_item = makeCropItem(_)

    -- Keep Crop immediately before KOReader's native Rotate option. In current
    -- KOReader this places it directly after Stretch cover to fit screen, while
    -- avoiding assumptions about the Stretch item's dynamic text_func label.
    local insert_at = #fit_items + 1
    for index, item in ipairs(fit_items) do
        if item.text == _("Rotate cover for best fit") then
            insert_at = index
            break
        end
    end
    table.insert(fit_items, insert_at, crop_item)
    return true
end

local function wrapMenuBuilder(class, class_marker, menu_kind, order_module, _)
    if type(class) ~= "table" or class[class_marker] then return end
    if type(class.setUpdateItemTable) ~= "function" then return end

    class[class_marker] = true
    local original_set_update_item_table = class.setUpdateItemTable

    function class:setUpdateItemTable(...)
        local results = { original_set_update_item_table(self, ...) }

        -- KOReader creates the sleep-screen submenu with dofile() each time the
        -- menu is assembled. Inject into that actual live menu tree, then redo
        -- the final sort so the new item is present in tab_item_table too.
        if injectCropItem(self.menu_items, _) then
            local MenuSorter = require("ui/menusorter")
            local order = require(order_module)
            self.tab_item_table = MenuSorter:mergeAndSort(
                menu_kind,
                self.menu_items,
                order
            )
        end

        return unpack(results)
    end
end

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

    -- KOReader does not require() this menu. ReaderMenu and FileManagerMenu each
    -- dofile() frontend/ui/elements/screensaver_menu.lua when their live menu is
    -- built. Patching a separately required copy therefore cannot affect what
    -- the user sees. Wrap those two builders and inject into the real tree.
    local ReaderMenu = require("apps/reader/modules/readermenu")
    local FileManagerMenu = require("apps/filemanager/filemanagermenu")

    wrapMenuBuilder(
        ReaderMenu,
        "_burrow_sleep_cover_crop_menu_v2",
        "reader",
        "ui/elements/reader_menu_order",
        _
    )
    wrapMenuBuilder(
        FileManagerMenu,
        "_burrow_sleep_cover_crop_menu_v2",
        "filemanager",
        "ui/elements/filemanager_menu_order",
        _
    )

    Module.applied = true
    return true
end

return Module
