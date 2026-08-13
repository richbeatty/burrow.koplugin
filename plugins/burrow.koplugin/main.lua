--[[
    Burrow provides a unified library, Store, and reader interface for KOReader.
--]]

local WidgetContainer = require("ui/widget/container/widgetcontainer")
local UIManager = require("ui/uimanager")
local InfoMessage = require("ui/widget/infomessage")
local logger = require("logger")
local _ = require("l10n.gettext")
local burrow_util = require("burrow_util")
local burrow_debug = require("burrow_debug")
local BurrowMigration = require("burrow_migration")
local BurrowCompatibility = require("burrow_compatibility")
local BurrowLoader = require("burrow_loader")
local BurrowSettings = require("burrow_settings")

-- The updater is optional at runtime. A problem in update support must never
-- stop the core Burrow library from loading.
local updater_ok, BurrowUpdater = pcall(require, "burrow_updater_fix")
if not updater_ok then
    logger.warn(burrow_debug.logprefix, "Burrow updater could not be loaded", BurrowUpdater)
end

-- Keep Burrow visible in Plugin Management when a critical prerequisite fails.
local function makeUnavailablePlugin(reason)
    local BurrowUnavailable = WidgetContainer:extend {
        name = "burrow",
        unavailable_reason = reason,
    }

    function BurrowUnavailable:init()
        if not self.ui.document and self.ui.menu then
            self.ui.menu:registerToMainMenu(self)
        end
        UIManager:nextTick(function()
            UIManager:show(InfoMessage:new {
                text = _("Burrow could not start.") .. "\n\n" .. self.unavailable_reason,
                show_icon = false,
                alignment = "center",
                timeout = 30,
            })
        end)
    end

    function BurrowUnavailable:addToMainMenu(menu_items)
        local sub_items = {
            {
                text = _("Burrow could not start"),
                keep_menu_open = true,
                callback = function()
                    UIManager:show(InfoMessage:new {
                        text = self.unavailable_reason,
                        show_icon = false,
                        alignment = "center",
                    })
                end,
            },
        }

        if updater_ok then
            local recovery_ok, recovery_items = pcall(
                BurrowUpdater.recoveryMenuItems,
                BurrowUpdater
            )
            if recovery_ok and type(recovery_items) == "table" then
                for _, item in ipairs(recovery_items) do
                    sub_items[#sub_items + 1] = item
                end
            end
        end

        menu_items.burrow = {
            text = _("Burrow"),
            sub_item_table = sub_items,
            separator = true,
        }
    end

    return BurrowUnavailable
end

logger.info(burrow_debug.logprefix, "Checking Burrow requirements")

local plugins_disabled = G_reader_settings:readSetting("plugins_disabled")
if type(plugins_disabled) ~= "table" then
    plugins_disabled = {}
end

if plugins_disabled.coverbrowser == nil or plugins_disabled.coverbrowser == false then
    return makeUnavailablePlugin(
        _("KOReader's built-in Cover Browser is enabled. Disable Cover Browser in Plugin Management, then restart KOReader.")
    )
end

if not burrow_util.installIcons() then
    return makeUnavailablePlugin(
        _("Burrow could not install or locate its required icons. Check storage permissions, then restart KOReader.")
    )
end

local compatibility = BurrowCompatibility:evaluate(BurrowMigration.isVersionCheckSkipped())
if not compatibility.allowed then
    logger.warn(burrow_debug.logprefix, "KOReader compatibility blocked", compatibility.reason)
    return makeUnavailablePlugin(compatibility.reason)
end
if compatibility.warning then
    logger.warn(burrow_debug.logprefix, compatibility.warning)
end

-- Early optional modules are isolated by feature. Their failure is reported by
-- the loader but does not prevent the core library from starting.
BurrowLoader:loadEarlyModules()

local Burrow = WidgetContainer:extend {
    name = "burrow",
}
Burrow._compatibility = compatibility
Burrow._compatibility_notice = compatibility.warning

-- The core library runtime is kept in a guarded module so KOReader methods are
-- not wrapped more than once.
local core_ok, core_error = BurrowLoader:applyCoreModules(Burrow)
if not core_ok then
    return makeUnavailablePlugin(
        _("Burrow's core library module could not start.") .. "\n\n" .. tostring(core_error)
    )
end

-- Optional visual modules are preflighted and applied by feature group. A
-- failed group is disabled without preventing unrelated Burrow features.
BurrowLoader:applyInstanceModules(Burrow)

-- Older ProjectTitle and folder-cover builds may leave a generated collage in
-- an entry's pt_cover_path/burrow_cover_path field. That is cache artwork, not
-- a user-selected folder cover. Only recognize an actual cover/folder image
-- stored inside the physical folder; otherwise the consistency layer will use
-- the first available book cover.
if not burrow_util._burrow_folder_cover_path_guarded then
    burrow_util._burrow_folder_cover_path_guarded = true
    local original_getFolderCover = burrow_util.getFolderCover
    burrow_util.getFolderCover = function(filepath, max_img_w, max_img_h)
        return original_getFolderCover(
            filepath,
            max_img_w,
            max_img_h,
            burrow_util.findCover(filepath)
        )
    end
end

-- Cover Grid and Cover List build directory artwork through separate widget
-- paths. Apply Burrow's consistency layer after the normal visual modules so
-- physical folders and automatic series use the same final presentation.
if BurrowSettings:isFeatureEnabled("library_visuals") then
    local module_ok, module_or_error = pcall(require, "burrow_list_folder_covers")
    if module_ok and type(module_or_error) == "table" and type(module_or_error.apply) == "function" then
        local apply_ok, applied, apply_error = pcall(module_or_error.apply, Burrow)
        if not apply_ok or applied == false then
            logger.warn(
                burrow_debug.logprefix,
                "Folder and series styling could not be applied",
                apply_ok and apply_error or applied
            )
        end
    else
        logger.warn(
            burrow_debug.logprefix,
            "Folder and series styling could not be loaded",
            module_or_error
        )
    end
end

Burrow._loader_errors = BurrowLoader:getErrors()
Burrow._loader_statuses = BurrowLoader:getStatuses()
Burrow._degraded_features = BurrowLoader:getDegradedFeatures()

if updater_ok then
    local startup_ok, startup_error = pcall(
        BurrowUpdater.startup,
        BurrowUpdater,
        Burrow
    )
    if not startup_ok then
        logger.warn(burrow_debug.logprefix, "Burrow updater startup failed", startup_error)
    end
end

logger.info(
    burrow_debug.logprefix,
    "Loaded Burrow on KOReader",
    compatibility.short,
    compatibility.level
)

return Burrow