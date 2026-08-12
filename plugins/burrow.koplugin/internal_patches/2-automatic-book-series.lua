local MODULE_KEY = "burrow.internal.2_automatic_book_series"
local existing_module = package.loaded[MODULE_KEY]
if existing_module then return existing_module end
local Module = { key = MODULE_KEY, phase = "instance", filename = "2-automatic-book-series.lua" }
package.loaded[MODULE_KEY] = Module

--[[
    Automatic Book Series v1.0.7

    This patch automatically organizes your books into virtual folders based on 
    book series. If you have multiple books that belong to the same series (e.g., 
    "Harry Potter 1", "Harry Potter 2", etc.), they will be grouped together into 
    a single folder with the series name, making it easier to find and browse 
    related books. No need to use Calibre or create folders manually.

    Note: If there's only one book from a series in the folder, it won't be grouped.
    Also, if all books in the folder belong to the same series, grouping is skipped
    to avoid creating virtual folders inside your existing series folders.

    You can enable/disable this feature from Burrow Settings under Library > Organization.
--]]

local BD = require("ui/bidi")
local Blitbuffer = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local FileChooser = require("ui/widget/filechooser")
local FileManager = require("apps/filemanager/filemanager")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local IconWidget = require("ui/widget/iconwidget")
local ImageWidget = require("ui/widget/imagewidget")
local Size = require("ui/size")
local TextBoxWidget = require("ui/widget/textboxwidget")
local TitleBar = require("ui/widget/titlebar")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local Screen = Device.screen

local logger = require("logger")
local userpatch = require("userpatch")
local _ = require("gettext")

logger.dbg("AutomaticSeries Patch: Loading...")

-- Keep these values in sync with 2--stretched-rounded-covers.lua.
-- Because Burrow centers covers vertically, the caption space is
-- reserved above and below so the title can sit fully beneath the cover.
local caption_height = Screen:scaleBySize(18)
local caption_gap = Screen:scaleBySize(3)
local caption_vertical_reserve = 2 * (caption_height + caption_gap)
local series_cover_aspect_ratio = 2 / 3

-- Icon constants for browser-up-folder compatibility
local Icon = {
    home = "return.library",
    up = BD.mirroredUILayout() and "back.top.rtl" or "back.top",
}

-- Global cache mapping virtual series folder paths to their book items
-- This allows the Burrow plugin to find books for folder cover rendering
local series_items_cache = {}

-- State for persisting virtual folder across refreshes
local current_series_group = nil

-- Cache the Burrow enabled state to avoid repeated settings checks
local is_burrow_enabled = nil

local function normalizePath(path)
    if not path or path == "" then
        return nil
    end
    return path:gsub("[/\\]+$", "")
end

local function getLibraryHome()
    return G_reader_settings:readSetting("home_dir") or Device.home_dir
end

local RETURN_TILE_TOKEN = "__burrow_return_to_library_v3__"
local RETURN_TILE_SETTING = "burrow_return_to_library_enabled"

local function isReturnToLibraryEnabled()
    local value = G_reader_settings:readSetting(RETURN_TILE_SETTING)
    return value == nil or value == true
end

local function isReturnToLibraryItem(item)
    return item
        and item.is_return_to_library == true
        and item._burrow_return_tile_token == RETURN_TILE_TOKEN
        and item.is_file ~= true
end

local function makeReturnToLibraryItem()
    return {
        text = _("Return to Library"),
        is_file = false,
        is_directory = true,
        is_return_to_library = true,
        _burrow_return_tile_token = RETURN_TILE_TOKEN,
        -- Use a unique synthetic path instead of the real home directory.
        -- Burrow may reuse grid slots after returning from the reader;
        -- this keeps the navigation tile from being mistaken for a book.
        path = RETURN_TILE_TOKEN,
        mode = "directory",
        mandatory = "",
        sort_percent = 0,
        percent_finished = 0,
        opened = false,
        attr = { mode = "directory" },
    }
end

-- Keep the Return to Library tile independent from automatic series grouping.
-- This lets manually organized library folders use the same navigation tile.
local function ensureReturnToLibraryItem(item_table, file_chooser)
    if not item_table or not file_chooser then
        return
    end

    -- Remove an existing tile first so refreshes cannot duplicate it and so it
    -- disappears correctly when returning to the configured library home.
    for i = #item_table, 1, -1 do
        if isReturnToLibraryItem(item_table[i]) then
            table.remove(item_table, i)
        end
    end

    if not isReturnToLibraryEnabled() then
        return
    end

    local home_dir = normalizePath(getLibraryHome())
    local current_path = normalizePath(file_chooser.path)
    if not current_path or not home_dir or current_path == home_dir then
        return
    end

    local contains_books = false
    for _, item in ipairs(item_table) do
        if item.is_file or item.is_series_group then
            contains_books = true
            break
        end
    end

    if contains_books then
        table.insert(item_table, makeReturnToLibraryItem())
    end
end

local function automaticSeriesPatch(plugin)
    local MosaicMenu = require("mosaicmenu")
    local MosaicMenuItem = userpatch.getUpValue(MosaicMenu._updateItemsBuildUI, "MosaicMenuItem")
    if not MosaicMenuItem then return end
    local BookInfoManager = userpatch.getUpValue(MosaicMenuItem.update, "BookInfoManager")
    
    if not BookInfoManager then
        logger.warn("AutomaticSeries Patch: BookInfoManager not found")
        return
    end
    
    logger.dbg("AutomaticSeries Patch: Initialized with BookInfoManager")

    -- Expose the cache on the class so other Burrow patches can reliably
    -- recognize a virtual series tile even when KOReader rebuilds a menu entry
    -- without preserving our custom is_series_group and series_items fields.
    MosaicMenuItem._automatic_series_items_cache = series_items_cache

    local function getSeriesItemsForMenuItem(menu_item)
        local entry = menu_item.entry
        if entry and entry.series_items and #entry.series_items > 0 then
            return entry.series_items
        end

        local entry_path = entry and entry.path
        local filepath = entry_path or menu_item.filepath
        if filepath then
            return series_items_cache[filepath]
        end
    end
    
    -- Check if Burrow is enabled by checking if coverbrowser plugin is disabled (Burrow replaces it)
    local function isBurrowEnabled()
        if is_burrow_enabled ~= nil then
            return is_burrow_enabled
        end
        
        local plugins_disabled = G_reader_settings:readSetting("plugins_disabled")
        if type(plugins_disabled) == "table" and plugins_disabled["coverbrowser"] then
            logger.dbg("AutomaticSeries: Burrow enabled (coverbrowser disabled)")
            is_burrow_enabled = true
            return true
        end
        
        logger.dbg("AutomaticSeries: Burrow not detected (coverbrowser enabled)")
        return false
    end
    
    -- Settings
    local setting_name = "automatic_series_grouping_enabled"
    local function isEnabled()
        local setting = BookInfoManager:getSetting(setting_name)
        -- Default to true if nil (not explicitly disabled)
        return setting ~= "N"
    end
    
    local function setEnabled(enabled)
        -- Store "Y" for enabled, "N" for disabled (avoid false->NULL issue)
        BookInfoManager:saveSetting(setting_name, enabled and "Y" or "N")
    end
    
    -- Keep virtual series entries recognizable across every FileManager refresh.
    -- The reader-close path rebuilds the mosaic and may recreate an entry from
    -- its virtual path, so restore the series fields before Burrow draws it.
    local original_MosaicMenuItem_update = MosaicMenuItem.update

    local function renderReturnToLibraryTile(menu_item)
        local tile_w = math.max(1, menu_item.width or 1)
        local tile_h = math.max(1, menu_item.height or 1)
        local caption_h = caption_height
        local icon_area_h = math.max(1, tile_h - caption_h - caption_gap)
        -- Fit the Burrow-owned square icon to the actual available tile area.
        -- The old implementation enforced a large minimum size, which could
        -- overflow short/reused grid slots and make the shared Home icon appear
        -- stretched or clipped after returning from the reader.
        local max_icon_size = math.max(
            Screen:scaleBySize(12),
            math.min(
                Screen:scaleBySize(58),
                math.floor(tile_w * 0.34),
                math.floor(icon_area_h * 0.42)
            )
        )
        local icon_size = max_icon_size
        local icon_padding = math.max(
            Screen:scaleBySize(2),
            math.min(Screen:scaleBySize(10), math.floor(icon_size * 0.22))
        )
        local icon_frame_size = math.min(
            icon_size + (icon_padding * 2),
            tile_w,
            icon_area_h
        )
        icon_size = math.max(
            Screen:scaleBySize(8),
            icon_frame_size - (icon_padding * 2)
        )

        local icon_frame = FrameContainer:new {
            width = icon_frame_size,
            height = icon_frame_size,
            margin = 0,
            padding = icon_padding,
            bordersize = Size.border.thin,
            radius = Screen:scaleBySize(12),
            color = Blitbuffer.COLOR_GRAY_3,
            background = Blitbuffer.COLOR_WHITE,
            IconWidget:new {
                icon = Icon.home,
                width = icon_size,
                height = icon_size,
                -- Keep this tile opaque and uncached. When returning from the
                -- reader, KOReader may repaint only the icon region. A cached
                -- alpha icon can then reveal pixels from the old reader
                -- framebuffer through its transparent area, producing the
                -- miniature-page corruption seen after the back gesture.
                alpha = false,
                file_do_cache = false,
                scale_factor = 0,
            },
        }

        local caption = TextBoxWidget:new {
            text = _("Return to Library"),
            face = Font:getFace("smallinfofont", 12),
            width = math.max(1, tile_w - Screen:scaleBySize(8)),
            height = caption_h,
            height_adjust = true,
            height_overflow_show_ellipsis = true,
            alignment = "center",
        }

        local tile = CenterContainer:new {
            dimen = Geom:new { w = tile_w, h = tile_h },
            VerticalGroup:new {
                CenterContainer:new {
                    dimen = Geom:new { w = tile_w, h = icon_area_h },
                    icon_frame,
                },
                VerticalSpan:new { width = caption_gap },
                caption,
            },
        }

        local previous_tile = menu_item._underline_container[1]
        -- Detach first, then recursively release the previous tile. This keeps
        -- UnderlineContainer from retaining a reference to a freed image widget
        -- while KOReader rebuilds the series screen after closing the reader.
        menu_item._underline_container[1] = nil
        if previous_tile then
            previous_tile:free(true)
        end
        menu_item._underline_container[1] = tile
        menu_item.is_directory = true
        menu_item.bookinfo_found = true
        menu_item.has_description = false
        menu_item.percent_finished = nil
        menu_item.status = nil
        menu_item.filepath = nil
        menu_item._burrow_return_tile_active = true
    end

    function MosaicMenuItem:update(...)
        if isReturnToLibraryItem(self.entry) then
            renderReturnToLibraryTile(self)
            return
        end

        -- Burrow can reuse a grid item after a reader closes. If that slot
        -- previously held the return tile, force one complete normal rebuild so
        -- the old icon cannot remain attached to the newly assigned book.
        local force_rebuild = self._burrow_return_tile_active == true
        if force_rebuild then
            self._burrow_return_tile_active = nil
            self.filepath = self.entry and (self.entry.file or self.entry.path) or nil
        end

        local series_items = getSeriesItemsForMenuItem(self)
        if not series_items or #series_items == 0 then
            if force_rebuild then
                local saved_init_done = self.init_done
                self.init_done = false
                local ok, result = pcall(original_MosaicMenuItem_update, self, ...)
                self.init_done = saved_init_done
                if not ok then error(result) end
                return result
            end
            return original_MosaicMenuItem_update(self, ...)
        end

        if self.entry then
            self.entry.is_series_group = true
            self.entry.is_file = false
            self.entry.is_directory = true
            self.entry.mode = "directory"
            self.entry.series_items = series_items
        end

        -- Burrow normally writes a directory name across the cover and
        -- places the item count at the bottom. Virtual series tiles use the same
        -- clean caption-under-cover layout as books, so suppress both overlays
        -- only while Burrow builds this one tile.
        local saved_mandatory = self.mandatory
        local original_getSetting = BookInfoManager.getSetting
        self.mandatory = ""

        BookInfoManager.getSetting = function(manager, setting_name, ...)
            if setting_name == "show_name_grid_folders" then
                return false
            end
            return original_getSetting(manager, setting_name, ...)
        end

        local saved_init_done
        if force_rebuild then
            saved_init_done = self.init_done
            self.init_done = false
        end

        local ok, result = pcall(original_MosaicMenuItem_update, self, ...)
        if force_rebuild then
            self.init_done = saved_init_done
        end
        BookInfoManager.getSetting = original_getSetting
        self.mandatory = saved_mandatory

        if not ok then
            error(result)
        end
        return result
    end

    -- Give Burrow one full-size cover for a virtual series path. Do not
    -- call the generic _setFolderCover method here. That method belongs to
    -- 2-browser-folder-cover.lua and adds the two folder tabs and round item
    -- count seen after returning from the reader.
    if isBurrowEnabled() then
        local ok, burrow_util = pcall(require, "burrow_util")
        if ok and burrow_util and burrow_util.getSubfolderCoverImages
            and not burrow_util._automatic_series_first_cover_patched then
            burrow_util._automatic_series_first_cover_patched = true
            local original_getSubfolderCoverImages = burrow_util.getSubfolderCoverImages

            burrow_util.getSubfolderCoverImages = function(filepath, max_w, max_h)
                local series_items = series_items_cache[filepath]
                if not series_items or #series_items == 0 then
                    return original_getSubfolderCoverImages(filepath, max_w, max_h)
                end

                for _, book_entry in ipairs(series_items) do
                    if book_entry.path then
                        local bookinfo = BookInfoManager:getBookInfo(book_entry.path, true)
                        if bookinfo
                            and bookinfo.cover_bb
                            and bookinfo.has_cover
                            and bookinfo.cover_fetched
                            and not bookinfo.ignore_cover
                            and bookinfo.cover_w
                            and bookinfo.cover_h
                            and bookinfo.cover_w > 0
                            and bookinfo.cover_h > 0
                        then
                            local cover_h = math.max(
                                Screen:scaleBySize(40),
                                max_h - caption_vertical_reserve
                            )
                            local cover_w = math.min(
                                max_w,
                                math.floor(cover_h * series_cover_aspect_ratio)
                            )
                            cover_h = math.min(
                                cover_h,
                                math.floor(cover_w / series_cover_aspect_ratio)
                            )

                            local scale_to_fill = math.max(
                                cover_w / bookinfo.cover_w,
                                cover_h / bookinfo.cover_h
                            )
                            local image = ImageWidget:new {
                                image = bookinfo.cover_bb,
                                width = cover_w,
                                height = cover_h,
                                scale_factor = scale_to_fill,
                                center_x_ratio = 0.5,
                                center_y_ratio = 0.5,
                            }
                            -- Match the exact outer frame geometry used by normal
                            -- book covers. The image dimensions already use the same
                            -- 2:3 target and caption reserve; adding the same thin
                            -- border makes book, physical-folder, and virtual-series
                            -- covers occupy an identical visual footprint.
                            local cover_border = Size.border.thin
                            local border_total = cover_border * 2
                            return FrameContainer:new {
                                width = cover_w + border_total,
                                height = cover_h + border_total,
                                margin = 0,
                                padding = 0,
                                bordersize = cover_border,
                                color = Blitbuffer.COLOR_GRAY_3,
                                image,
                            }
                        end
                    end
                end

                return nil
            end
            logger.dbg("AutomaticSeries: Installed consistent first-cover renderer")
        end
    end

    -- Helper: check if item is a directory
    local function isDirectory(item)
        return item.is_directory or (item.attr and item.attr.mode == "directory") or item.mode == "directory"
    end
    
    -- Local logic container
    local AutomaticSeries = {}
    
    function AutomaticSeries:processItemTable(item_table, file_chooser)
        -- Defensive check
        if not file_chooser or not item_table then return end
        
        -- Skip grouping in folder chooser dialogs
        if file_chooser.show_current_dir_for_hold then return end

        logger.dbg("AutomaticSeries: Processing Items")
        
        local collate, collate_id = file_chooser:getCollate()
        local reverse = G_reader_settings:isTrue("reverse_collate")
        local sort_func = file_chooser:getSortingFunction(collate, reverse)
        local mixed = G_reader_settings:isTrue("collate_mixed") and collate.can_collate_mixed
        
        -- Check if we are sorting by some form of Name/Title
        local is_name_sort = (collate_id == "strcoll" or collate_id == "natural" or collate_id == "title")
    
        local series_map = {}
        local processed_list = {}
        
        -- Track for single-series detection (to skip grouping if folder already organized)
        local book_count = 0
        local non_series_book_count = 0
        
        for _, item in ipairs(item_table) do
            -- Synthetic navigation tiles are always regenerated at the end.
            if isReturnToLibraryItem(item) then
                -- skip
            -- Handle "go up" items - skip them, we handle navigation separately
            elseif item.is_go_up then
                table.insert(processed_list, item)
            else
                -- Ensure safe sort properties for ALL items (files and directories)
                if not item.sort_percent then item.sort_percent = 0 end
                if not item.percent_finished then item.percent_finished = 0 end
                if not item.opened then item.opened = false end
    
                local is_file = item.is_file
                local series_handled = false

                -- A real book must never retain a synthetic navigation marker,
                -- even if KOReader has reused an entry table during a refresh.
                if is_file then
                    item.is_return_to_library = nil
                    item._burrow_return_tile_token = nil
                end
                
                if is_file and item.path then
                    book_count = book_count + 1

                    local doc_props = item.doc_props or BookInfoManager:getDocProps(item.path)
                    -- Filter out "\u{FFFF}" sentinel used by series/authors/keywords collates for nil values
                    if doc_props and doc_props.series and doc_props.series ~= "\u{FFFF}" then
                        local series_name = doc_props.series

                        -- Cache series_index on item to avoid repeated calls during sorting
                        item._series_index = doc_props.series_index or 0
                        
                        if not series_map[series_name] then
                            -- New Series Group
                            logger.dbg("AutomaticSeries: Found series", series_name)
                            
                            -- Shallow copy attributes
                            local group_attr = {}
                            if item.attr then
                                for k, v in pairs(item.attr) do group_attr[k] = v end
                            end
                            group_attr.mode = "directory" 
    
                            local group_item = {
                                text = series_name,
                                is_file = false,
                                is_directory = true,
                                -- Fake path, but keep base path of first item
                                path = (item.path:match("(.*/)") or item.path) .. series_name, 
                                is_series_group = true,
                                series_items = { item },
                                attr = group_attr,
                                mode = "directory",
                                -- Inherit sort properties from the first book (which determines position)
                                sort_percent = item.sort_percent,
                                percent_finished = item.percent_finished,
                                opened = item.opened,
                                -- Ensure doc_props exists for sorting - use item's or create minimal one
                                doc_props = item.doc_props or {
                                    series = series_name,
                                    series_index = 0,
                                    display_title = series_name,
                                },
                                suffix = item.suffix,
                            }
                            -- Cache this group
                            series_map[series_name] = group_item
                            table.insert(processed_list, group_item)
                            -- Store the list index to allow replacement if ungrouping needed
                            group_item._list_index = #processed_list
                        else
                            -- Existing Series Group
                            table.insert(series_map[series_name].series_items, item)
                        end
                        series_handled = true
                    else
                        non_series_book_count = non_series_book_count + 1
                    end
                end
                
                if not series_handled then
                    table.insert(processed_list, item)
                end
            end
        end
    
        logger.dbg("AutomaticSeries: Done grouping.")
        
        -- Count unique series (break early if more than 1)
        local series_count = 0
        for _ in pairs(series_map) do
            series_count = series_count + 1
            if series_count > 1 then break end
        end
        
        -- Skip applying changes if all books are from the same single series
        -- (folder is already organized by series manually)
        if series_count == 1 and non_series_book_count == 0 and book_count > 0 then
            logger.dbg("AutomaticSeries: Skipping - all books from same series")
            return
        end
    
        -- Update the item count in the text for each series group
        for _, group in pairs(series_map) do
            if #group.series_items == 1 then
                -- Single book in series: Ungroup it!
                -- Replace the group item in the list with the single book item
                if group._list_index and processed_list[group._list_index] == group then
                    local single_book = group.series_items[1]
                    processed_list[group._list_index] = single_book
                end
            else
                -- Set mandatory to show book count with folder icon (displays as badge on right)
                group.mandatory = tostring(#group.series_items) .. " \u{F016}"
                -- Sort the internal list of books by series index (using cached _series_index)
                table.sort(group.series_items, function(a, b)
                    return (a._series_index or 0) < (b._series_index or 0)
                end)
                -- Cache the series items by the virtual folder path for Burrow hook
                if group.path then
                    series_items_cache[group.path] = group.series_items
                end
            end
        end
        
        local final_table = {}
        
        if mixed then
            if is_name_sort then
                local up_item
                local to_sort = {}
                for _, item in ipairs(processed_list) do
                    if item.is_go_up then up_item = item else table.insert(to_sort, item) end
                end
                local ok, err = pcall(table.sort, to_sort, sort_func)
                if not ok then
                    logger.warn("AutomaticSeries: Sort failed, using unsorted list:", err)
                end
                
                if up_item then table.insert(final_table, up_item) end
                for _, item in ipairs(to_sort) do table.insert(final_table, item) end
            else
                final_table = processed_list
            end
        else
            -- Mixed is FALSE: Folders first, then Files.
            
            local dirs = {}
            local files = {}
            local up_item
            
            for _, item in ipairs(processed_list) do
                if item.is_go_up then
                    up_item = item
                elseif isDirectory(item) then
                    table.insert(dirs, item)
                else
                    table.insert(files, item)
                end
            end
            
            -- We must resort 'dirs' to ensure our new Series Groups are sorted correctly among other real folders.
            local ok, err = pcall(table.sort, dirs, sort_func)
            if not ok then
                logger.warn("AutomaticSeries: Sort failed, using unsorted list:", err)
            end
            
            if up_item then table.insert(final_table, up_item) end
            for _, d in ipairs(dirs) do table.insert(final_table, d) end
            for _, f in ipairs(files) do table.insert(final_table, f) end
        end
    
        logger.dbg("AutomaticSeries: Done sorting.")

        -- In a real subfolder containing books, add one final home tile. It is
        -- appended after sorting so it always follows the final book.
        local home_dir = normalizePath(getLibraryHome())
        local current_path = normalizePath(file_chooser.path)
        local contains_books = false
        for _, item in ipairs(final_table) do
            if item.is_file then
                contains_books = true
                break
            end
        end
        if isReturnToLibraryEnabled()
            and contains_books and current_path and home_dir and current_path ~= home_dir
        then
            table.insert(final_table, makeReturnToLibraryItem())
        end
        
        -- Update item_table in place (clear and fill)
        for k in pairs(item_table) do item_table[k] = nil end
        for i, v in ipairs(final_table) do item_table[i] = v end
    end
    
    function AutomaticSeries:openSeriesGroup(file_chooser, group_item)
        -- Safety check
        if not file_chooser then
            return
        end
        
        -- Work from a fresh view table so navigation entries never leak back
        -- into the cached series book list or affect the folder's book count.
        local items = {}
        for _, item in ipairs(group_item.series_items or {}) do
            if not item.is_go_up and not isReturnToLibraryItem(item) then
                table.insert(items, item)
            end
        end
        
        -- Store the real parent path before entering the virtual folder
        local parent_path = file_chooser.path
        
        -- Store the group for state persistence across refreshes
        current_series_group = {
            series_name = group_item.text,
            parent_path = parent_path,
        }

        logger.dbg("AutomaticSeries: Opening series:", group_item.text)
        
        -- Check if go-up item already exists (always at position 1 if present)
        local up_item_already_present = items[1] and items[1].is_go_up
        
        -- Check if browser-up-folder extension provides a toolbar back button
        -- Only respect hide_up_folder setting if _changeLeftIcon exists (the extension is loaded)
        local is_browser_up_folder_enabled = file_chooser._changeLeftIcon ~= nil and G_reader_settings:readSetting("filemanager_hide_up_folder", false)
        local hide_up_folder = is_browser_up_folder_enabled
        
        -- Also hide go-up item if Burrow plugin is enabled (it has its own menubar button)
        if not hide_up_folder and isBurrowEnabled() then
            hide_up_folder = true
        end
        
        -- Always add go-up item in virtual folders if not already present
        -- (regardless of whether parent folder had one - virtual folders always need navigation)
        if not up_item_already_present then
            local up_item = {
                text = BD.mirroredUILayout() and BD.ltr("../ \u{2B06}") or "\u{2B06} ../",
                is_directory = true,
                path = parent_path,
                is_go_up = true,
            }
            -- Only add to items list if browser-up-folder is NOT hiding them
            if not hide_up_folder then
                table.insert(items, 1, up_item)
            end
        end
        
        -- The return tile is the final item when Burrow navigation enables it.
        if isReturnToLibraryEnabled() then
            table.insert(items, makeReturnToLibraryItem())
        end

        -- Tag this table as a virtual series view
        items.is_in_series_view = true
        items.parent_path = parent_path
       
        -- Switch view
        file_chooser:switchItemTable(nil, items, nil, nil, group_item.text)
        
        -- If browser-up-folder extension is hiding the go-up item, show the back icon in toolbar
        if is_browser_up_folder_enabled and not isBurrowEnabled() then
            file_chooser:_changeLeftIcon(Icon.up, function() file_chooser:onFolderUp() end)
        end
    end
    
    -- Helper: Exit virtual folder if currently in one. Returns true if handled.
    local function exitVirtualFolderIfNeeded(file_chooser)
        if file_chooser and file_chooser.item_table and file_chooser.item_table.is_in_series_view then
            local parent_path = file_chooser.item_table.parent_path
            if parent_path then
                logger.dbg("AutomaticSeries: Exiting virtual folder, returning to parent path:", parent_path)
                -- Set a flag so updateItems knows to find and restore focus to the series group item after refresh
                if current_series_group then
                    current_series_group.should_restore_focus = true
                end
                file_chooser:changeToPath(parent_path)
                return true
            end
        end
        return false
    end
    
    -- Hook TitleBar.setSubTitle to prevent "Home" from overwriting series name
    -- This catches ALL attempts to change the subtitle, including during FileManager init
    local old_setSubTitle = TitleBar.setSubTitle
    TitleBar.setSubTitle = function(self, subtitle, no_refresh)
        -- If we're in a virtual series view, block attempts to set subtitle to "Home"
        if current_series_group then
            -- Replace "Home" with series name
            return old_setSubTitle(self, current_series_group.series_name, no_refresh)
        end
        return old_setSubTitle(self, subtitle, no_refresh)
    end
    
    local old_updateItems = FileChooser.updateItems
    local old_onMenuSelect = FileChooser.onMenuSelect
    local old_onFolderUp = FileChooser.onFolderUp
    local old_changeToPath = FileChooser.changeToPath
    local old_refreshPath = FileChooser.refreshPath
    local old_goHome = FileChooser.goHome
    local old_switchItemTable = FileChooser.switchItemTable

    -- Hook switchItemTable to process items BEFORE the original searches for itemmatch
    -- This ensures the correct page is calculated after grouping
    FileChooser.switchItemTable = function(file_chooser, new_title, new_item_table, itemnumber, itemmatch, new_subtitle)
        if new_item_table and not new_item_table.is_in_series_view then
            if isEnabled() then
                AutomaticSeries:processItemTable(new_item_table, file_chooser)
            end
            ensureReturnToLibraryItem(new_item_table, file_chooser)
        end
        
        return old_switchItemTable(file_chooser, new_title, new_item_table, itemnumber, itemmatch, new_subtitle)
    end
    
    -- Hook goHome to handle virtual folder exit properly
    FileChooser.goHome = function(file_chooser)
        -- If we're in a virtual series view, exit it first with proper focus restoration
        if file_chooser.item_table and file_chooser.item_table.is_in_series_view then            
            if current_series_group then
                current_series_group.should_restore_focus = true
            end

            local parent_path = file_chooser.item_table.parent_path
            local home_dir = G_reader_settings:readSetting("home_dir") or require("device").home_dir

            -- If parent was home, just exit virtual folder (don't let original goHome go to page 1)
            if parent_path and home_dir and parent_path == home_dir then
                file_chooser:changeToPath(parent_path)
                return true
            end
        end
        return old_goHome(file_chooser)
    end
    
    -- Hook refreshPath to re-enter virtual folder after refresh (returning from book, sort change, etc.)
    FileChooser.refreshPath = function(file_chooser)
        old_refreshPath(file_chooser)
        -- Re-enter the virtual series folder if we were in one
        if isEnabled() and current_series_group then
            local series_name = current_series_group.series_name
            for _, item in ipairs(file_chooser.item_table) do
                if item.is_series_group and item.text == series_name then
                    AutomaticSeries:openSeriesGroup(file_chooser, item)
                    break
                end
            end
        end
    end
    
    -- Override onFolderUp to handle virtual folder navigation (toolbar up button)
    FileChooser.onFolderUp = function(file_chooser)
        if exitVirtualFolderIfNeeded(file_chooser) then
            return true
        end
        return old_onFolderUp(file_chooser)
    end

    -- Patch for Burrow plugin (if loaded)
    -- Burrow has its own local onFolderUp function that we need to patch
    if isBurrowEnabled() then
        local ok, CoverMenu = pcall(require, "covermenu")
        if ok and CoverMenu and CoverMenu.setupLayout then
            local orig_onFolderUp, onFolderUp_idx = userpatch.getUpValue(CoverMenu.setupLayout, "onFolderUp")
            if orig_onFolderUp then
                local new_onFolderUp = function()
                    local file_chooser = FileManager.instance and FileManager.instance.file_chooser
                    if not exitVirtualFolderIfNeeded(file_chooser) then
                        orig_onFolderUp()
                    end
                end
                userpatch.replaceUpValue(CoverMenu.setupLayout, onFolderUp_idx, new_onFolderUp)
                logger.dbg("AutomaticSeries: Patched Burrow onFolderUp")
            end
        end
    end
    
    -- Override onMenuSelect to handle series group clicks
    FileChooser.onMenuSelect = function(file_chooser, item)
        -- The final navigation tile always jumps directly to the configured
        -- Burrow home library, not merely to the parent directory.
        if isReturnToLibraryItem(item) then
            current_series_group = nil
            local home_dir = getLibraryHome()
            if home_dir then
                file_chooser:changeToPath(home_dir)
                return true
            end
            return old_goHome(file_chooser)
        end

        -- Handle series group click - open the virtual folder
        if isEnabled() and item.is_series_group then
            AutomaticSeries:openSeriesGroup(file_chooser, item)
            return true
        end
        
        return old_onMenuSelect(file_chooser, item)
    end
    
    -- Override changeToPath to clear virtual folder state and redirect ".." navigation
    FileChooser.changeToPath = function(file_chooser, path, ...)
        -- If we're in a virtual series view and path contains "..", redirect to real parent
        if file_chooser.item_table and file_chooser.item_table.is_in_series_view then
            local parent_path = file_chooser.item_table.parent_path
            if parent_path and path and (path:match("/%.%.") or path:match("^%.%.")) then
                path = parent_path
            end
            -- Set flag to restore focus to the series group item
            if current_series_group then
                current_series_group.should_restore_focus = true
            end
            -- Don't clear current_series_group when exiting virtual folder - updateItems needs it
        else
            -- Only clear for non-virtual-folder navigation
            current_series_group = nil
        end

        return old_changeToPath(file_chooser, path, ...)
    end
    
    FileChooser.updateItems = function(file_chooser, ...)
        if file_chooser.item_table and not file_chooser.item_table.is_in_series_view then
            ensureReturnToLibraryItem(file_chooser.item_table, file_chooser)
        end

        if not isEnabled() then
            current_series_group = nil
            return old_updateItems(file_chooser, ...)
        end
        
        if not file_chooser.item_table or #file_chooser.item_table == 0 then
            return old_updateItems(file_chooser, ...)
        end
        
        -- Prevent recursive grouping inside a virtual series folder
        if file_chooser.item_table.is_in_series_view then
            return old_updateItems(file_chooser, ...)
        end
        -- Handle focus restoration when returning to parent after exiting virtual folder
        if current_series_group and current_series_group.should_restore_focus
           and file_chooser.item_table and #file_chooser.item_table > 0 then
            logger.dbg("AutomaticSeries: Looking for series to restore focus:", current_series_group.series_name)
            for index, item in ipairs(file_chooser.item_table) do
                if item.is_series_group and item.text == current_series_group.series_name then
                    logger.dbg("AutomaticSeries: Found series group at index:", index)
                    local page = math.ceil(index / file_chooser.perpage)
                    local select_number = ((index - 1) % file_chooser.perpage) + 1
                    file_chooser.page = page
                    file_chooser.path_items[file_chooser.path] = index
                    current_series_group = nil
                    return old_updateItems(file_chooser, select_number)
                end
            end
            current_series_group = nil
        end
        
        return old_updateItems(file_chooser, ...)
    end
    
    -- Configuration now lives in Burrow Settings > Library > Organization.
    -- Do not inject a Burrow-only switch into KOReader's stock File Browser menu.

end

Module.apply = automaticSeriesPatch
return Module
