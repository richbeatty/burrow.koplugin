-- Burrow Cover List folder and automatic-series styling.
--
-- The list renderer historically requested custom directory artwork at only
-- 82% of the available width and placed it directly into the row. This module
-- rebuilds that one list-view widget at the full book-cover allocation and
-- wraps it in the same rounded frame used by book covers.

local Blitbuffer = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local ImageWidget = require("ui/widget/imagewidget")
local Screen = require("device").screen
local Size = require("ui/size")
local BookInfoManager = require("bookinfomanager")
local BurrowMigration = require("burrow_migration")
local burrow_debug = require("burrow_debug")
local burrow_util = require("burrow_util")
local logger = require("logger")
local userpatch = require("userpatch")

local Module = {
    key = "burrow.list_folder_covers",
}

local function findFolderSlot(item)
    local root = item and item._underline_container and item._underline_container[1]
    local left = root and root[1]
    local horizontal = left and left[1]
    if not horizontal or type(horizontal) ~= "table" then
        return nil
    end
    return horizontal, horizontal[1]
end

local function buildFolderCover(item)
    if not item or not item.is_directory or not item.do_cover_image then
        return nil
    end
    if burrow_util.isPathChooser(item) then
        return nil
    end

    local padding_size = Screen:scaleBySize(4)
    local row_height = math.max(1, tonumber(item.height) or 1)
    local max_img_w = math.max(1, row_height - 2 * padding_size)
    local max_img_h = math.max(1, row_height - 2 * padding_size)
    local border_total = Size.border.thin * 2
    local cover_art_w = math.max(1, max_img_w - border_total)
    local cover_art_h = math.max(1, max_img_h - border_total)

    local artwork = burrow_util.getFolderCover(
        item.filepath,
        cover_art_w,
        cover_art_h,
        BurrowMigration.folderCoverPath(item.entry)
    )

    if artwork == nil and not BookInfoManager:getSetting("disable_auto_foldercovers") then
        artwork = burrow_util.getSubfolderCoverImages(
            item.filepath,
            cover_art_w,
            cover_art_h
        )
    end

    if artwork == nil then
        local _, _, scale_factor = BookInfoManager.getCachedCoverSize(
            250,
            500,
            cover_art_w,
            cover_art_h
        )
        artwork = ImageWidget:new {
            file = burrow_util.getPluginDir() .. "/resources/folder.svg",
            alpha = true,
            scale_factor = scale_factor,
            width = cover_art_w,
            height = cover_art_h,
            original_in_nightmode = false,
        }
    end

    local rounded_cover = FrameContainer:new {
        width = cover_art_w + border_total,
        height = cover_art_h + border_total,
        margin = 0,
        padding = 0,
        radius = Size.radius.default,
        bordersize = Size.border.thin,
        color = Blitbuffer.COLOR_GRAY_3,
        artwork,
    }

    local cover_slot = CenterContainer:new {
        dimen = Geom:new { w = row_height, h = row_height },
        margin = 0,
        padding = padding_size,
        color = Blitbuffer.COLOR_WHITE,
        dim = item.file_deleted,
        rounded_cover,
    }
    cover_slot._burrow_rounded_list_folder = true
    return cover_slot
end

local function restyleFolderItem(item)
    local horizontal, existing = findFolderSlot(item)
    if not horizontal or not existing or existing._burrow_rounded_list_folder then
        return
    end

    local replacement = buildFolderCover(item)
    if not replacement then
        return
    end

    horizontal[1] = replacement
    if existing.free then
        existing:free()
    end
    if item.menu then
        item.menu._has_cover_images = true
    end
    item._has_cover_image = true
end

function Module.apply()
    if Module.applied then
        return true
    end

    local ListMenu = require("listmenu")
    local ListMenuItem = userpatch.getUpValue(ListMenu._updateItemsBuildUI, "ListMenuItem")
    if not ListMenuItem then
        logger.warn(burrow_debug.logprefix, "Could not find Cover List item class")
        return false, "Could not find Cover List item class"
    end

    if ListMenuItem._burrow_folder_covers_patched then
        Module.applied = true
        return true
    end
    ListMenuItem._burrow_folder_covers_patched = true

    local original_update = ListMenuItem.update
    function ListMenuItem:update(...)
        local result = original_update(self, ...)
        local ok, err = pcall(restyleFolderItem, self)
        if not ok then
            logger.warn(burrow_debug.logprefix, "Could not style Cover List folder", err)
        end
        return result
    end

    Module.applied = true
    logger.info(burrow_debug.logprefix, "Full-size rounded Cover List folders loaded")
    return true
end

return Module
