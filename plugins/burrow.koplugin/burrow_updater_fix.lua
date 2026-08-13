local Updater = require("burrow_updater")

local ConfirmBox = require("ui/widget/confirmbox")
local DataStorage = require("datastorage")
local UIManager = require("ui/uimanager")
local InfoMessage = require("ui/widget/infomessage")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local T = require("ffi/util").template
local _ = require("l10n.gettext")
local BurrowVersion = require("burrow_version")

local function pathMode(path)
    return lfs.attributes(path, "mode")
end

local function absolutePath(path)
    path = tostring(path or ""):gsub("\\", "/")
    if path:sub(1, 1) == "/" then
        return path
    end
    return lfs.currentdir():gsub("/+$", "") .. "/" .. path
end

local function currentPluginDir()
    local info = debug.getinfo(1, "S") or {}
    local source = tostring(info.source or "")
    if source:sub(1, 1) == "@" then
        source = source:sub(2)
    end
    source = absolutePath(source)
    local directory = source:match("^(.*)/[^/]+$")
    if directory and pathMode(directory) == "directory" then
        return directory:gsub("/+$", "")
    end

    local data_root = DataStorage:getFullDataDir() or DataStorage:getDataDir()
    if data_root and data_root:sub(1, 1) ~= "/" then
        data_root = absolutePath(data_root)
    end
    return tostring(data_root):gsub("/+$", "") .. "/plugins/burrow.koplugin"
end

local function dataRoot()
    local root = DataStorage:getFullDataDir() or DataStorage:getDataDir()
    if root and root:sub(1, 1) ~= "/" then
        root = absolutePath(root)
    end
    return tostring(root):gsub("/+$", "")
end

local PLUGIN_DIR = currentPluginDir()
local PLUGIN_PARENT = PLUGIN_DIR:match("^(.*)/[^/]+$")
local WORK_DIR = dataRoot() .. "/ota/burrow-updater"
local STAGING_DIR = WORK_DIR .. "/staging"
local STAGING_PLUGIN_DIR = STAGING_DIR .. "/plugins/burrow.koplugin"
local DOWNLOAD_PATH = WORK_DIR .. "/Burrow-update.zip"
local BACKUP_ROOT = WORK_DIR .. "/backup"
local BACKUP_DIR = BACKUP_ROOT .. "/burrow.koplugin"
local STATE_PATH = WORK_DIR .. "/update-state.txt"
local INCOMING_DIR = PLUGIN_PARENT .. "/burrow.koplugin.update-new"
local PREVIOUS_DIR = PLUGIN_PARENT .. "/burrow.koplugin.update-old"

local function mkdirp(path)
    if pathMode(path) == "directory" then
        return true
    end
    local parent = path:match("^(.*)/[^/]+$")
    if parent and parent ~= "" and parent ~= path then
        local ok, err = mkdirp(parent)
        if not ok then return nil, err end
    end
    local ok, err = lfs.mkdir(path)
    if ok or pathMode(path) == "directory" then
        return true
    end
    return nil, err or "could not create directory"
end

local function removeTree(path)
    local mode = pathMode(path)
    if not mode then return true end
    if mode ~= "directory" then
        local ok, err = os.remove(path)
        if ok or not pathMode(path) then return true end
        return nil, err or "could not remove file"
    end

    for name in lfs.dir(path) do
        if name ~= "." and name ~= ".." then
            local ok, err = removeTree(path .. "/" .. name)
            if not ok then return nil, err end
        end
    end
    local ok, err = lfs.rmdir(path)
    if ok or not pathMode(path) then return true end
    return nil, err or "could not remove directory"
end

local function copyFile(source, destination)
    local input, err = io.open(source, "rb")
    if not input then return nil, err end
    local content = input:read("*a")
    input:close()

    local parent = destination:match("^(.*)/[^/]+$")
    if parent then
        local ok, mkdir_err = mkdirp(parent)
        if not ok then return nil, mkdir_err end
    end

    local output, open_err = io.open(destination, "wb")
    if not output then return nil, open_err end
    local ok, write_err = output:write(content)
    output:close()
    if not ok then return nil, write_err end
    return true
end

local function copyTree(source, destination)
    if pathMode(source) ~= "directory" then
        return nil, "source directory does not exist: " .. tostring(source)
    end

    local ok, err = mkdirp(destination)
    if not ok then return nil, err end

    for name in lfs.dir(source) do
        if name ~= "." and name ~= ".." then
            local src = source .. "/" .. name
            local dst = destination .. "/" .. name
            local mode = pathMode(src)
            if mode == "directory" then
                ok, err = copyTree(src, dst)
            elseif mode == "file" then
                ok, err = copyFile(src, dst)
            else
                return nil, "unsupported file type while copying " .. src
            end
            if not ok then return nil, err end
        end
    end
    return true
end

local function readFile(path)
    local file, err = io.open(path, "rb")
    if not file then return nil, err end
    local content = file:read("*a")
    file:close()
    return content
end

local function readVersion(plugin_dir)
    local content = readFile(plugin_dir .. "/burrow_version.lua")
    if not content then return nil end
    return content:match("VERSION%s*=%s*\"([^\"]+)\"")
end

local function writeState(status, previous_version, new_version)
    local ok, err = mkdirp(WORK_DIR)
    if not ok then return nil, err end
    local file, open_err = io.open(STATE_PATH, "wb")
    if not file then return nil, open_err end
    local content = table.concat({
        "status=" .. tostring(status or ""),
        "previous_version=" .. tostring(previous_version or ""),
        "new_version=" .. tostring(new_version or ""),
        "",
    }, "\n")
    local wrote, write_err = file:write(content)
    file:close()
    if not wrote then return nil, write_err end
    return true
end

local function validateCopy(plugin_dir, expected_version)
    for _, required in ipairs({
        "main.lua",
        "_meta.lua",
        "burrow_version.lua",
        "burrow_updater.lua",
        "burrow_updater_fix.lua",
    }) do
        if pathMode(plugin_dir .. "/" .. required) ~= "file" then
            return nil, "copied plugin is missing " .. required
        end
    end
    if readVersion(plugin_dir) ~= expected_version then
        return nil, "copied plugin version does not match " .. tostring(expected_version)
    end
    return true
end

local function cleanError(err)
    return tostring(err or "unknown error"):gsub("^.-:%d+:%s*", "")
end

local function showInfo(text, timeout)
    UIManager:show(InfoMessage:new {
        text = text,
        show_icon = false,
        alignment = "center",
        timeout = timeout,
    })
end

local function showError(text)
    showInfo(_("Burrow could not update.") .. "\n\n" .. tostring(text))
end

local originalPrepare = Updater._prepareRelease
local originalStartup = Updater.startup

function Updater:_swapInPreparedRelease(release)
    if pathMode(PLUGIN_DIR) ~= "directory" then
        error("running Burrow folder was not found at " .. PLUGIN_DIR, 0)
    end
    if pathMode(STAGING_PLUGIN_DIR) ~= "directory" then
        error("prepared Burrow folder was not found at " .. STAGING_PLUGIN_DIR, 0)
    end

    local previous_version = BurrowVersion.VERSION
    local ok, err = mkdirp(BACKUP_ROOT)
    if not ok then error("could not create backup folder: " .. tostring(err), 0) end

    removeTree(BACKUP_DIR)
    removeTree(INCOMING_DIR)
    removeTree(PREVIOUS_DIR)

    ok, err = copyTree(PLUGIN_DIR, BACKUP_DIR)
    if not ok then
        error("could not copy the current Burrow installation to backup: " .. tostring(err), 0)
    end
    ok, err = validateCopy(BACKUP_DIR, previous_version)
    if not ok then
        error("Burrow backup verification failed: " .. tostring(err), 0)
    end

    ok, err = copyTree(STAGING_PLUGIN_DIR, INCOMING_DIR)
    if not ok then
        error("could not copy the prepared update beside the current plugin: " .. tostring(err), 0)
    end
    ok, err = validateCopy(INCOMING_DIR, release.version)
    if not ok then
        error("prepared update copy verification failed: " .. tostring(err), 0)
    end

    ok, err = writeState("installing", previous_version, release.version)
    if not ok then
        error("could not create update recovery state: " .. tostring(err), 0)
    end

    ok, err = os.rename(PLUGIN_DIR, PREVIOUS_DIR)
    if not ok then
        os.remove(STATE_PATH)
        error("could not move the running Burrow folder aside at " .. PLUGIN_DIR .. ": " .. tostring(err), 0)
    end

    ok, err = os.rename(INCOMING_DIR, PLUGIN_DIR)
    if not ok then
        local restored, restore_err = os.rename(PREVIOUS_DIR, PLUGIN_DIR)
        os.remove(STATE_PATH)
        if not restored then
            error(
                "new Burrow could not be activated and the previous folder could not be restored. "
                .. "Previous folder: " .. PREVIOUS_DIR .. ". "
                .. tostring(restore_err or err),
                0
            )
        end
        error("new Burrow could not be activated, so the previous version was restored: " .. tostring(err), 0)
    end

    local state_ok, state_err = writeState("awaiting_restart", previous_version, release.version)
    if not state_ok then
        logger.warn("[Burrow updater] Could not write restart state:", state_err)
    end

    removeTree(PREVIOUS_DIR)
    os.remove(DOWNLOAD_PATH)
    removeTree(STAGING_DIR)
end

function Updater:_performUpdate(release)
    local prepared, prepare_err = pcall(originalPrepare, self, release)
    if not prepared then
        error("Preparation failed: " .. cleanError(prepare_err), 0)
    end

    local installed, install_err = pcall(self._swapInPreparedRelease, self, release)
    if not installed then
        error("Installation failed: " .. cleanError(install_err), 0)
    end
end

function Updater:restorePreviousVersion()
    if self._busy or not self:hasBackup() then return end
    local backup_version = self:getBackupVersion() or _("previous version")

    UIManager:show(ConfirmBox:new {
        text = T(
            _("Restore Burrow %1?\n\nYour current Burrow plugin will be replaced by the saved previous version."),
            backup_version
        ),
        ok_text = _("Restore"),
        ok_callback = function()
            self._busy = true
            local ok, err = pcall(function()
                removeTree(INCOMING_DIR)
                removeTree(PREVIOUS_DIR)

                local copied, copy_err = copyTree(BACKUP_DIR, INCOMING_DIR)
                if not copied then
                    error("could not prepare the saved Burrow version: " .. tostring(copy_err), 0)
                end
                copied, copy_err = validateCopy(INCOMING_DIR, backup_version)
                if not copied then
                    error("saved Burrow verification failed: " .. tostring(copy_err), 0)
                end

                local moved, move_err = os.rename(PLUGIN_DIR, PREVIOUS_DIR)
                if not moved then
                    error("could not move the current Burrow folder aside: " .. tostring(move_err), 0)
                end

                moved, move_err = os.rename(INCOMING_DIR, PLUGIN_DIR)
                if not moved then
                    local restored, restore_err = os.rename(PREVIOUS_DIR, PLUGIN_DIR)
                    if not restored then
                        error(
                            "rollback failed and the current Burrow folder could not be restored: "
                            .. tostring(restore_err or move_err),
                            0
                        )
                    end
                    error("the saved Burrow version could not be activated: " .. tostring(move_err), 0)
                end

                removeTree(PREVIOUS_DIR)
                os.remove(STATE_PATH)
                os.remove(DOWNLOAD_PATH)
                removeTree(STAGING_DIR)
            end)
            self._busy = false

            if not ok then
                logger.warn("[Burrow updater] Rollback failed:", err)
                showError("Rollback failed: " .. cleanError(err))
                return
            end

            showInfo(T(_("Burrow %1 has been restored. Restart KOReader to finish."), backup_version), 4)
            UIManager:scheduleIn(0.3, function()
                UIManager:askForRestart()
            end)
        end,
    })
end

function Updater:startup(plugin)
    if pathMode(PLUGIN_DIR) == "directory" then
        removeTree(INCOMING_DIR)
        removeTree(PREVIOUS_DIR)
    end
    Updater.paths = Updater.paths or {}
    Updater.paths.plugin = PLUGIN_DIR
    Updater.paths.work = WORK_DIR
    Updater.paths.backup = BACKUP_DIR
    return originalStartup(self, plugin)
end

Updater.paths = Updater.paths or {}
Updater.paths.plugin = PLUGIN_DIR
Updater.paths.work = WORK_DIR
Updater.paths.backup = BACKUP_DIR

logger.info("[Burrow updater] Running plugin path:", PLUGIN_DIR)

return Updater
