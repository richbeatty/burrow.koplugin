local Event = require("ui/event")
local Device = require("device")
local UIManager = require("ui/uimanager")
local logger = require("logger")

local RotationFix = {}

function RotationFix.apply()
    if UIManager._burrow_quick_rotation_v5 then
        return true
    end
    UIManager._burrow_quick_rotation_v5 = true

    local Screen = Device.screen
    local original_broadcast = UIManager.broadcastEvent

    local function calledFromBurrowQuickSettings()
        local info = debug.getinfo(3, "S")
        local source = info and tostring(info.source or "") or ""
        return source:find("2-quick-settings.lua", 1, true) ~= nil
    end

    local function quickSettingsOpensFirst()
        local quick_settings = package.loaded["burrow.internal.2_quick_settings"]
        if not (quick_settings and quick_settings.applied) then
            return false
        end

        local config = G_reader_settings:readSetting("rounded_quick_settings_panel")
        if type(config) == "table" and config.open_on_start == false then
            return false
        end
        return true
    end

    local function calledFromReaderMenu()
        -- ReaderMenu dispatches ShowConfigMenu through ReaderUI, so it may be
        -- several Lua frames below ReaderConfig:onShowConfigMenu().
        for level = 2, 24 do
            local info = debug.getinfo(level, "S")
            if not info then break end
            local source = tostring(info.source or "")
            if source:find("apps/reader/modules/readermenu.lua", 1, true) then
                return true
            end
        end
        return false
    end

    -- KOReader normally opens ReaderConfig underneath ReaderMenu whenever
    -- show_bottom_menu is enabled. That makes sense for KOReader's stock reader
    -- menu, but Burrow's Quick Settings is intended to be a standalone top panel.
    --
    -- Suppress only the automatic ReaderMenu -> ReaderConfig opening when
    -- Burrow Quick Settings is actually loaded and configured to open first.
    -- Direct Text-control requests still use ReaderConfig normally.
    local ReaderConfig = require("apps/reader/modules/readerconfig")
    if not ReaderConfig._burrow_quick_settings_top_only then
        ReaderConfig._burrow_quick_settings_top_only = true
        local original_show_config = ReaderConfig.onShowConfigMenu

        function ReaderConfig:onShowConfigMenu(...)
            if quickSettingsOpensFirst() and calledFromReaderMenu() then
                logger.dbg(
                    "[Burrow] Suppressed automatic bottom ReaderConfig under Quick Settings"
                )
                return true
            end
            return original_show_config(self, ...)
        end
    end

    local function showBurrowTextControlsSafely()
        local ok, ReaderUI = pcall(require, "apps/reader/readerui")
        local reader = ok and ReaderUI.instance or nil
        if not reader or not reader.config then
            return false
        end

        -- Close the reader top menu through KOReader's own controller so its
        -- menu_container bookkeeping is cleared correctly.
        if reader.menu
            and reader.menu.menu_container
            and type(reader.menu.onCloseReaderMenu) == "function"
        then
            local close_ok, close_err = pcall(
                reader.menu.onCloseReaderMenu,
                reader.menu
            )
            if not close_ok then
                logger.warn(
                    "[Burrow] Could not close ReaderMenu before Text controls",
                    close_err
                )
            end
        end

        -- Compatibility path: if a config dialog is already present (for
        -- example after changing settings or when Burrow's top-only rule does
        -- not apply), simply leave it in place rather than creating a duplicate.
        if reader.config.config_dialog then
            logger.dbg("[Burrow] Reusing existing ReaderConfig dialog")
            return true
        end

        -- In the normal Burrow path the bottom config panel was intentionally
        -- not created when Quick Settings opened. Create exactly one after the
        -- top ReaderMenu has closed.
        UIManager:nextTick(function()
            local current = ReaderUI.instance
            if current
                and current.config
                and not current.config.config_dialog
                and type(current.config.onShowConfigMenu) == "function"
            then
                logger.dbg("[Burrow] Opening Text controls after Quick Settings close")
                current.config:onShowConfigMenu()
            end
        end)
        return true
    end

    function UIManager:broadcastEvent(event, ...)
        local from_burrow_quick_settings = event
            and calledFromBurrowQuickSettings()

        -- Text controls are special. Do not broadcast ShowConfigMenu blindly:
        -- close Burrow's top panel cleanly, then reuse or create one ReaderConfig.
        if from_burrow_quick_settings
            and event.handler == "onShowConfigMenu"
            and showBurrowTextControlsSafely()
        then
            return true
        end

        local burrow_rotate = from_burrow_quick_settings
            and event.handler == "onSwapRotation"

        if burrow_rotate then
            -- Cycle through all four physical orientations instead of KOReader's
            -- paired portrait/landscape SwapRotation behavior.
            event = Event:new("IterateRotation")

            -- Keep this orientation when moving between File Manager and Reader.
            G_reader_settings:makeTrue("lock_rotation")
        end

        local result = original_broadcast(self, event, ...)

        if burrow_rotate then
            -- Persist the actual post-rotation mode as Burrow's startup rotation.
            -- KOReader normally skips fm_rotation_mode at startup when
            -- lock_rotation is enabled, so Burrow also restores this value below.
            local mode = Screen:getRotationMode()
            G_reader_settings:saveSetting("fm_rotation_mode", mode)
            if type(G_reader_settings.flush) == "function" then
                G_reader_settings:flush()
            end
            logger.dbg("[Burrow] Saved Quick Settings rotation", mode)
        end

        return result
    end

    -- KOReader's FileManager:setRotationMode() intentionally does nothing when
    -- lock_rotation is true. That is correct while switching views, but on a
    -- fresh KOReader process it means the saved fm_rotation_mode is never
    -- reapplied. Restore it once after Burrow starts so a full KOReader restart
    -- comes back on the same physical side chosen from Quick Settings.
    local saved_mode = tonumber(G_reader_settings:readSetting("fm_rotation_mode"))
    if G_reader_settings:isTrue("lock_rotation") and saved_mode ~= nil then
        saved_mode = saved_mode % 4
        UIManager:nextTick(function()
            if Screen:getRotationMode() ~= saved_mode then
                original_broadcast(UIManager, Event:new("SetRotationMode", saved_mode))
                logger.dbg("[Burrow] Restored saved startup rotation", saved_mode)
            end
        end)
    end

    return true
end

return RotationFix
