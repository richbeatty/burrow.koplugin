local Archiver = require("ffi/archiver")
local ConfirmBox = require("ui/widget/confirmbox")
local DataStorage = require("datastorage")
local Device = require("device")
local InfoMessage = require("ui/widget/infomessage")
local NetworkMgr = require("ui/network/manager")
local UIManager = require("ui/uimanager")
local lfs = require("libs/libkoreader-lfs")
local ltn12 = require("ltn12")
local logger = require("logger")
local rapidjson = require("rapidjson")
local sha256 = require("ffi/sha2").sha256
local socket = require("socket")
local socketutil = require("socketutil")
local http = require("socket.http")
local T = require("ffi/util").template
local _ = require("l10n.gettext")
local BurrowVersion = require("burrow_version")

local BurrowUpdater = {
    REPOSITORY = "richbeatty/burrow.koplugin",
    MAX_ARCHIVE_SIZE = 10 * 1024 * 1024,
    AUTO_CHECK_INTERVAL = 24 * 60 * 60,
    _busy = false,
}

local function getDataRoot()
    if type(DataStorage.getFullDataDir) == "function" then
        return DataStorage:getFullDataDir()
    end
    local data_dir = DataStorage:getDataDir()
    if data_dir:sub(1, 1) == "/" then
        return data_dir
    end
    return lfs.currentdir() .. "/" .. data_dir
end

local DATA_ROOT = getDataRoot():gsub("/+$", "")
local PLUGIN_DIR = DATA_ROOT .. "/plugins/burrow.koplugin"
local WORK_DIR = DATA_ROOT .. "/ota/burrow-updater"
local STAGING_DIR = WORK_DIR .. "/staging"
local STAGING_PLUGIN_DIR = STAGING_DIR .. "/plugins/burrow.koplugin"
local DOWNLOAD_PATH = WORK_DIR .. "/Burrow-update.zip"
local MANIFEST_PATH = STAGING_DIR .. "/FILES.sha256"
local BACKUP_ROOT = WORK_DIR .. "/backup"
local BACKUP_DIR = BACKUP_ROOT .. "/burrow.koplugin"
local ROLLBACK_CURRENT_DIR = WORK_DIR .. "/rollback-current.koplugin"
local STATE_PATH = WORK_DIR .. "/update-state.txt"

local function pathMode(path)
    return lfs.attributes(path, "mode")
end

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
            local child = path .. "/" .. name
            local ok, err = removeTree(child)
            if not ok then return nil, err end
        end
    end
    local ok, err = lfs.rmdir(path)
    if ok or not pathMode(path) then return true end
    return nil, err or "could not remove directory"
end

local function readFile(path)
    local file, err = io.open(path, "rb")
    if not file then return nil, err end
    local content = file:read("*a")
    file:close()
    return content
end

local function writeFile(path, content)
    local parent = path:match("^(.*)/[^/]+$")
    if parent then
        local ok, err = mkdirp(parent)
        if not ok then return nil, err end
    end
    local file, err = io.open(path, "wb")
    if not file then return nil, err end
    local ok, write_err = file:write(content)
    file:close()
    if not ok then return nil, write_err end
    return true
end

local function parseVersion(value)
    value = tostring(value or ""):gsub("^v", "")
    local major, minor, patch, prerelease = value:match("^(%d+)%.(%d+)%.(%d+)%-(.+)$")
    if not major then
        major, minor, patch = value:match("^(%d+)%.(%d+)%.(%d+)$")
        prerelease = nil
    end
    if not major then return nil end
    return {
        original = value,
        major = tonumber(major),
        minor = tonumber(minor),
        patch = tonumber(patch),
        prerelease = prerelease,
    }
end

local function splitIdentifiers(value)
    local parts = {}
    for part in tostring(value or ""):gmatch("[^.]+") do
        parts[#parts + 1] = {
            raw = part,
            numeric = part:match("^%d+$") and tonumber(part) or nil,
        }
    end
    return parts
end

local function compareVersions(left, right)
    local a = parseVersion(left)
    local b = parseVersion(right)
    if not a or not b then return nil end

    for _, key in ipairs({ "major", "minor", "patch" }) do
        if a[key] < b[key] then return -1 end
        if a[key] > b[key] then return 1 end
    end

    if not a.prerelease and not b.prerelease then return 0 end
    if not a.prerelease then return 1 end
    if not b.prerelease then return -1 end

    local aa = splitIdentifiers(a.prerelease)
    local bb = splitIdentifiers(b.prerelease)
    local max_count = math.max(#aa, #bb)
    for i = 1, max_count do
        local av = aa[i]
        local bv = bb[i]
        if not av then return -1 end
        if not bv then return 1 end
        if av.numeric ~= nil and bv.numeric ~= nil then
            if av.numeric < bv.numeric then return -1 end
            if av.numeric > bv.numeric then return 1 end
        elseif av.numeric ~= nil then
            return -1
        elseif bv.numeric ~= nil then
            return 1
        elseif av.raw < bv.raw then
            return -1
        elseif av.raw > bv.raw then
            return 1
        end
    end
    return 0
end

local function normalizeReleaseVersion(tag_name)
    local version = tostring(tag_name or ""):gsub("^v", "")
    if not parseVersion(version) then return nil end
    return version
end

local function getChannel()
    local channel = G_reader_settings:readSetting("burrow_update_channel")
    if channel == "beta" then return "beta" end
    if channel == "stable" then return "stable" end
    local installed = parseVersion(BurrowVersion.VERSION)
    if installed and installed.prerelease then return "beta" end
    return "stable"
end

local function channelLabel(channel)
    return channel == "beta" and _("Beta") or _("Stable")
end

local function httpGet(url, accept)
    local sink = {}
    socketutil:set_timeout(socketutil.LARGE_BLOCK_TIMEOUT, socketutil.LARGE_TOTAL_TIMEOUT)
    local request = {
        url = url,
        method = "GET",
        sink = ltn12.sink.table(sink),
        redirect = true,
        headers = {
            ["Accept"] = accept or "application/vnd.github+json",
            ["User-Agent"] = "Burrow/" .. BurrowVersion.VERSION .. " KOReader",
            ["X-GitHub-Api-Version"] = "2022-11-28",
        },
    }

    local ok, code, headers, status = pcall(function()
        return socket.skip(1, http.request(request))
    end)
    socketutil:reset_timeout()

    if not ok then
        return nil, tostring(code)
    end
    code = tonumber(code)
    if not code or code < 200 or code > 299 then
        return nil, tostring(status or code or "network unavailable")
    end

    local content = table.concat(sink)
    if headers and headers["content-length"] then
        local expected = tonumber(headers["content-length"])
        if expected and #content ~= expected then
            return nil, "incomplete download"
        end
    end
    return content, nil, headers
end

local function decodeJson(content)
    local value, err = rapidjson.decode(content)
    if value == nil then
        return nil, err or "invalid JSON response"
    end
    return value
end

local function findAsset(release, wanted_name)
    for _, asset in ipairs(release.assets or {}) do
        if asset.name == wanted_name then
            return asset
        end
    end
end

local function releaseFromObject(release)
    if type(release) ~= "table" or release.draft == true then return nil end
    local version = normalizeReleaseVersion(release.tag_name)
    if not version then return nil end
    local zip_name = "Burrow-" .. version .. ".zip"
    local zip_asset = findAsset(release, zip_name)
    if not zip_asset or not zip_asset.browser_download_url then return nil end
    if tonumber(zip_asset.size) and tonumber(zip_asset.size) > BurrowUpdater.MAX_ARCHIVE_SIZE then
        return nil
    end
    return {
        version = version,
        tag_name = release.tag_name,
        prerelease = release.prerelease == true,
        name = release.name,
        body = release.body,
        zip_asset = zip_asset,
        checksum_asset = findAsset(release, "Burrow-" .. version .. ".sha256"),
    }
end

local function fetchRelease(channel)
    local base = "https://api.github.com/repos/" .. BurrowUpdater.REPOSITORY
    if channel == "stable" then
        local content, err = httpGet(base .. "/releases/latest")
        if not content then return nil, err end
        local decoded, decode_err = decodeJson(content)
        if not decoded then return nil, decode_err end
        local release = releaseFromObject(decoded)
        if not release then return nil, "the latest stable release package is not usable" end
        local parsed = parseVersion(release.version)
        if release.prerelease or (parsed and parsed.prerelease) then
            return nil, "the latest GitHub release is not a stable Burrow release"
        end
        return release
    end

    local content, err = httpGet(base .. "/releases?per_page=30")
    if not content then return nil, err end
    local decoded, decode_err = decodeJson(content)
    if not decoded then return nil, decode_err end

    local best
    for _, raw_release in ipairs(decoded) do
        local candidate = releaseFromObject(raw_release)
        if candidate then
            if not best then
                best = candidate
            else
                local comparison = compareVersions(candidate.version, best.version)
                if comparison and comparison > 0 then
                    best = candidate
                end
            end
        end
    end
    if not best then return nil, "no usable Burrow release was found" end
    return best
end

local function expectedArchiveDigest(release)
    local digest = release.zip_asset and release.zip_asset.digest
    if type(digest) == "string" then
        local value = digest:match("^sha256:(%x+)$")
        if value and #value == 64 then
            return value:lower()
        end
    end

    local checksum_asset = release.checksum_asset
    if not checksum_asset or not checksum_asset.browser_download_url then
        return nil, "the release does not include a SHA-256 checksum"
    end
    local content, err = httpGet(checksum_asset.browser_download_url, "application/octet-stream")
    if not content then return nil, err end
    local value = content:match("^%s*(%x+)")
    if not value or #value ~= 64 then
        return nil, "the release checksum is invalid"
    end
    return value:lower()
end

local function safeArchivePath(path)
    if type(path) ~= "string" or path == "" then return nil end
    if path:find("\0", 1, true) or path:find("\\", 1, true) then return nil end
    if path:sub(1, 1) == "/" or path:match("^%a:") then return nil end
    path = path:gsub("^%./", "")
    for segment in path:gmatch("[^/]+") do
        if segment == ".." then return nil end
    end
    return path
end

local function extractReleaseArchive(archive_path)
    local reader = Archiver.Reader:new()
    if not reader:open(archive_path) then
        return nil, reader.err or "could not open update archive"
    end

    local entries = {}
    for entry in reader:iterate() do
        local normalized = safeArchivePath(entry.path)
        if not normalized then
            reader:close()
            return nil, "the update archive contains an unsafe path"
        end
        entries[#entries + 1] = {
            path = entry.path,
            normalized = normalized,
            mode = entry.mode,
        }
    end

    local saw_plugin = false
    local saw_manifest = false
    for _, entry in ipairs(entries) do
        local wanted = entry.normalized == "FILES.sha256"
            or entry.normalized == "plugins/burrow.koplugin"
            or entry.normalized:match("^plugins/burrow%.koplugin/")
        if wanted then
            if entry.normalized:match("^plugins/burrow%.koplugin") then
                saw_plugin = true
            end
            if entry.normalized == "FILES.sha256" then
                saw_manifest = true
            end
            if entry.mode ~= "file" and entry.mode ~= "directory" then
                reader:close()
                return nil, "the update archive contains an unsupported plugin entry"
            end

            local destination = STAGING_DIR .. "/" .. entry.normalized
            if entry.mode == "directory" then
                local ok, err = mkdirp(destination)
                if not ok then
                    reader:close()
                    return nil, err
                end
            else
                local parent = destination:match("^(.*)/[^/]+$")
                if parent then
                    local ok, err = mkdirp(parent)
                    if not ok then
                        reader:close()
                        return nil, err
                    end
                end
                local ok = reader:extractToPath(entry.path, destination)
                if not ok then
                    local err = reader.err or "could not extract update archive"
                    reader:close()
                    return nil, err
                end
            end
        end
    end
    reader:close()

    if not saw_plugin or not saw_manifest then
        return nil, "the update archive is missing required Burrow package files"
    end
    return true
end

local function collectFiles(root, relative, output)
    relative = relative or ""
    output = output or {}
    local path = relative == "" and root or root .. "/" .. relative
    if pathMode(path) ~= "directory" then return output end
    for name in lfs.dir(path) do
        if name ~= "." and name ~= ".." then
            local child_relative = relative == "" and name or relative .. "/" .. name
            local child_path = root .. "/" .. child_relative
            local mode = pathMode(child_path)
            if mode == "directory" then
                local nested, nested_err = collectFiles(root, child_relative, output)
                if not nested then return nil, nested_err end
            elseif mode == "file" then
                output[#output + 1] = child_relative
            else
                return nil, "the extracted plugin contains an unsupported file type"
            end
        end
    end
    return output
end

local function verifyManifest()
    local manifest, err = readFile(MANIFEST_PATH)
    if not manifest then return nil, err or "FILES.sha256 is missing" end
    local expected = {}

    for line in manifest:gmatch("[^\r\n]+") do
        local hash, path = line:match("^([0-9a-fA-F]+)%s+(.+)$")
        if hash and #hash == 64 and path then
            path = path:gsub("^%*", ""):gsub("^%./", "")
            local relative = path:match("^plugins/burrow%.koplugin/(.+)$")
            if relative then
                expected[relative] = hash:lower()
            end
        end
    end

    local files, collect_err = collectFiles(STAGING_PLUGIN_DIR)
    if not files then return nil, collect_err end
    if #files == 0 then return nil, "the extracted plugin is empty" end

    local present = {}
    for _, relative in ipairs(files) do
        local wanted = expected[relative]
        if not wanted then
            return nil, "FILES.sha256 does not list " .. relative
        end
        present[relative] = true
        local content, read_err = readFile(STAGING_PLUGIN_DIR .. "/" .. relative)
        if not content then return nil, read_err end
        if sha256(content):lower() ~= wanted then
            return nil, "checksum verification failed for " .. relative
        end
    end
    for relative in pairs(expected) do
        if not present[relative] then
            return nil, "the update archive is missing " .. relative
        end
    end
    return true
end

local function readVersionFromPlugin(plugin_dir)
    local content = readFile(plugin_dir .. "/burrow_version.lua")
    if not content then return nil end
    return content:match("VERSION%s*=%s*\"([^\"]+)\"")
end

local function validatePlugin(expected_version)
    for _, required in ipairs({
        "main.lua",
        "_meta.lua",
        "burrow_version.lua",
        "burrow_updater.lua",
    }) do
        if pathMode(STAGING_PLUGIN_DIR .. "/" .. required) ~= "file" then
            return nil, "the update is missing " .. required
        end
    end

    local packaged_version = readVersionFromPlugin(STAGING_PLUGIN_DIR)
    if packaged_version ~= expected_version then
        return nil, "the package version does not match the GitHub release"
    end

    local manifest_ok, manifest_err = verifyManifest()
    if not manifest_ok then return nil, manifest_err end

    local files, collect_err = collectFiles(STAGING_PLUGIN_DIR)
    if not files then return nil, collect_err end
    for _, relative in ipairs(files) do
        if relative:match("%.lua$") then
            local chunk, compile_err = loadfile(STAGING_PLUGIN_DIR .. "/" .. relative)
            if not chunk then
                return nil, "Lua syntax check failed for " .. relative .. ": " .. tostring(compile_err)
            end
        end
    end
    return true
end

local function writeState(status, previous_version, new_version)
    local content = table.concat({
        "status=" .. tostring(status or ""),
        "previous_version=" .. tostring(previous_version or ""),
        "new_version=" .. tostring(new_version or ""),
        "",
    }, "\n")
    return writeFile(STATE_PATH, content)
end

local function readState()
    local content = readFile(STATE_PATH)
    if not content then return nil end
    local state = {}
    for key, value in content:gmatch("([%w_]+)=([^\r\n]*)") do
        state[key] = value
    end
    return state
end

local function cleanTemporaryFiles()
    os.remove(DOWNLOAD_PATH)
    removeTree(STAGING_DIR)
    removeTree(ROLLBACK_CURRENT_DIR)
end

local function currentVersion()
    return BurrowVersion.VERSION
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

local function friendlyError(err)
    local value = tostring(err or _("Unknown error"))
    return value:gsub("^.-:%d+:%s*", "")
end

function BurrowUpdater:hasBackup()
    return pathMode(BACKUP_DIR .. "/main.lua") == "file"
end

function BurrowUpdater:getBackupVersion()
    if not self:hasBackup() then return nil end
    return readVersionFromPlugin(BACKUP_DIR)
end

function BurrowUpdater:_prepareRelease(release)
    cleanTemporaryFiles()
    local ok, err = mkdirp(WORK_DIR)
    if not ok then error(err) end
    ok, err = mkdirp(STAGING_DIR)
    if not ok then error(err) end

    local expected_digest, digest_err = expectedArchiveDigest(release)
    if not expected_digest then error(digest_err) end

    local archive_content, download_err = httpGet(
        release.zip_asset.browser_download_url,
        "application/octet-stream"
    )
    if not archive_content then error(download_err) end
    if #archive_content > self.MAX_ARCHIVE_SIZE then
        error("the downloaded update is larger than Burrow allows")
    end
    if sha256(archive_content):lower() ~= expected_digest then
        error("the downloaded update did not match its SHA-256 checksum")
    end

    ok, err = writeFile(DOWNLOAD_PATH, archive_content)
    archive_content = nil
    if not ok then error(err) end

    ok, err = extractReleaseArchive(DOWNLOAD_PATH)
    if not ok then error(err) end
    ok, err = validatePlugin(release.version)
    if not ok then error(err) end
end

function BurrowUpdater:_swapInPreparedRelease(release)
    local previous_version = currentVersion()
    local ok, err = mkdirp(BACKUP_ROOT)
    if not ok then error(err) end

    if pathMode(BACKUP_DIR) then
        ok, err = removeTree(BACKUP_DIR)
        if not ok then error("could not remove the previous backup: " .. tostring(err)) end
    end

    local state_ok, state_err = writeState("installing", previous_version, release.version)
    if not state_ok then
        error("could not create update recovery state: " .. tostring(state_err))
    end

    ok, err = os.rename(PLUGIN_DIR, BACKUP_DIR)
    if not ok then
        os.remove(STATE_PATH)
        error("could not back up the current Burrow installation: " .. tostring(err))
    end

    ok, err = os.rename(STAGING_PLUGIN_DIR, PLUGIN_DIR)
    if not ok then
        local restored, restore_err = os.rename(BACKUP_DIR, PLUGIN_DIR)
        os.remove(STATE_PATH)
        if not restored then
            error(
                "the new version could not be installed and the automatic restore also failed. "
                .. "Burrow's backup remains at " .. BACKUP_DIR .. ". "
                .. tostring(restore_err or err)
            )
        end
        error("the new version could not be installed, so the previous version was restored: " .. tostring(err))
    end

    state_ok, state_err = writeState("awaiting_restart", previous_version, release.version)
    if not state_ok then
        logger.warn("[Burrow updater] Could not write restart state:", state_err)
    end

    os.remove(DOWNLOAD_PATH)
    removeTree(STAGING_DIR)
end

function BurrowUpdater:_performUpdate(release)
    self:_prepareRelease(release)
    self:_swapInPreparedRelease(release)
end

function BurrowUpdater:installRelease(release)
    if self._busy then return end
    self._busy = true
    showInfo(T(_("Downloading and verifying Burrow %1..."), release.version), 2)
    Device:setIgnoreInput(true)
    local ok, err = pcall(function()
        self:_performUpdate(release)
    end)
    Device:setIgnoreInput(false)
    self._busy = false

    if not ok then
        logger.warn("[Burrow updater] Update failed:", err)
        cleanTemporaryFiles()
        showError(friendlyError(err))
        return
    end

    showInfo(
        T(_("Burrow %1 has been installed. Restart KOReader to finish the update."), release.version),
        4
    )
    UIManager:scheduleIn(0.3, function()
        UIManager:askForRestart()
    end)
end

function BurrowUpdater:_offerRelease(release, interactive)
    local comparison = compareVersions(release.version, currentVersion())
    if comparison == nil then
        if interactive then showError(_("Burrow could not compare the release version.")) end
        return
    end

    if comparison <= 0 then
        if interactive then
            local channel = channelLabel(getChannel())
            if comparison == 0 then
                showInfo(T(_("Burrow %1 is up to date on the %2 channel."), currentVersion(), channel))
            else
                showInfo(T(_("Burrow %1 is newer than the latest release on the %2 channel."), currentVersion(), channel))
            end
        end
        return
    end

    UIManager:show(ConfirmBox:new {
        text = T(
            _("Burrow %1 is available.\n\nYou currently have Burrow %2.\n\nDownload and install this update?"),
            release.version,
            currentVersion()
        ),
        ok_text = _("Update"),
        ok_callback = function()
            self:installRelease(release)
        end,
    })
end

function BurrowUpdater:_checkForUpdates(interactive)
    if self._busy then return end
    self._busy = true
    if interactive then
        showInfo(_("Checking GitHub for Burrow updates..."), 1)
    end

    Device:setIgnoreInput(true)
    local call_ok, release, err = pcall(fetchRelease, getChannel())
    Device:setIgnoreInput(false)
    self._busy = false

    if not call_ok then
        err = release
        release = nil
    end
    if not release then
        if interactive then
            showError(_("Could not check GitHub for updates.") .. "\n\n" .. tostring(err or ""))
        else
            logger.warn("[Burrow updater] Automatic update check failed:", err)
        end
        return
    end

    G_reader_settings:saveSetting("burrow_update_last_check", os.time())
    self:_offerRelease(release, interactive)
end

function BurrowUpdater:checkForUpdates(interactive)
    interactive = interactive ~= false
    if interactive then
        if NetworkMgr:willRerunWhenOnline(function()
            self:checkForUpdates(true)
        end) then
            return
        end
    elseif not NetworkMgr:isOnline() then
        return
    end
    self:_checkForUpdates(interactive)
end

function BurrowUpdater:restorePreviousVersion()
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
                removeTree(ROLLBACK_CURRENT_DIR)
                local moved, move_err = os.rename(PLUGIN_DIR, ROLLBACK_CURRENT_DIR)
                if not moved then
                    error("could not move the current Burrow installation: " .. tostring(move_err))
                end
                moved, move_err = os.rename(BACKUP_DIR, PLUGIN_DIR)
                if not moved then
                    local restored, restore_err = os.rename(ROLLBACK_CURRENT_DIR, PLUGIN_DIR)
                    if not restored then
                        error(
                            "rollback failed and the current plugin could not be restored automatically: "
                            .. tostring(restore_err or move_err)
                        )
                    end
                    error("the previous Burrow version could not be restored: " .. tostring(move_err))
                end
                removeTree(ROLLBACK_CURRENT_DIR)
                os.remove(STATE_PATH)
                cleanTemporaryFiles()
            end)
            self._busy = false
            if not ok then
                logger.warn("[Burrow updater] Rollback failed:", err)
                showError(friendlyError(err))
                return
            end
            showInfo(T(_("Burrow %1 has been restored. Restart KOReader to finish."), backup_version), 4)
            UIManager:scheduleIn(0.3, function()
                UIManager:askForRestart()
            end)
        end,
    })
end

function BurrowUpdater:_aboutText()
    return T(
        _("Burrow %1\n\nA unified library, Store, and reader interface for KOReader.\n\nInspired by ProjectTitle, OPDS Plus, and the wider KOReader community.\n\nLicensed under GNU AGPL v3."),
        BurrowVersion.DISPLAY_VERSION
    )
end

function BurrowUpdater:aboutMenuItem()
    local updater = self
    local update_items = {
        {
            text = _("Check for Updates"),
            help_text = _("Check GitHub for a newer Burrow release."),
            callback = function()
                updater:checkForUpdates(true)
            end,
        },
        {
            text = _("Automatic update checks"),
            help_text = _("Check for updates at most once per day while KOReader is already online. Burrow will ask before installing anything."),
            checked_func = function()
                return G_reader_settings:isTrue("burrow_auto_update_check")
            end,
            callback = function()
                local enabled = G_reader_settings:isTrue("burrow_auto_update_check")
                G_reader_settings:saveSetting("burrow_auto_update_check", not enabled)
            end,
        },
        {
            text_func = function()
                return T(_("Update channel: %1"), channelLabel(getChannel()))
            end,
            help_text = _("Stable receives normal releases. Beta also receives GitHub prereleases for testing."),
            sub_item_table = {
                {
                    text = _("Stable"),
                    checked_func = function() return getChannel() == "stable" end,
                    callback = function()
                        G_reader_settings:saveSetting("burrow_update_channel", "stable")
                    end,
                },
                {
                    text = _("Beta"),
                    checked_func = function() return getChannel() == "beta" end,
                    callback = function()
                        G_reader_settings:saveSetting("burrow_update_channel", "beta")
                    end,
                },
            },
        },
    }

    if self:hasBackup() then
        update_items[#update_items + 1] = {
            text_func = function()
                local version = updater:getBackupVersion()
                return version and T(_("Restore Burrow %1"), version) or _("Restore previous version")
            end,
            help_text = _("Replace the current plugin with the one previous Burrow version kept by the updater."),
            callback = function()
                updater:restorePreviousVersion()
            end,
        }
    end

    update_items[#update_items + 1] = {
        text = T(_("Version %1"), BurrowVersion.DISPLAY_VERSION),
        keep_menu_open = true,
        callback = function()
            showInfo(updater:_aboutText())
        end,
    }

    return {
        text = _("About Burrow"),
        help_text = _("Version, updates, rollback, license, and acknowledgements."),
        sub_item_table = update_items,
    }
end

local function itemText(item)
    if not item then return nil end
    if item.text then return item.text end
    if item.text_func then
        local ok, value = pcall(item.text_func)
        if ok then return value end
    end
end

function BurrowUpdater:attachMenu(plugin)
    if not plugin or plugin._burrow_updater_menu_patched then return end
    plugin._burrow_updater_menu_patched = true
    local original = plugin.addToMainMenu
    if type(original) ~= "function" then return end
    local updater = self

    function plugin:addToMainMenu(menu_items)
        original(self, menu_items)
        local root = menu_items.filemanager_display_mode
        local items = root and root.sub_item_table
        if not items then return end
        for index, item in ipairs(items) do
            if itemText(item) == _("About Burrow") then
                items[index] = updater:aboutMenuItem()
                return
            end
        end
        items[#items + 1] = updater:aboutMenuItem()
    end
end

function BurrowUpdater:recoveryMenuItems()
    local items = {
        {
            text = _("Check for Updates"),
            callback = function()
                self:checkForUpdates(true)
            end,
        },
    }
    if self:hasBackup() then
        items[#items + 1] = {
            text = _("Restore previous Burrow version"),
            callback = function()
                self:restorePreviousVersion()
            end,
        }
    end
    return items
end

function BurrowUpdater:_finishPendingUpdate()
    local state = readState()
    if not state then
        cleanTemporaryFiles()
        return
    end

    local installed = currentVersion()
    if installed == state.new_version or installed == state.previous_version then
        os.remove(STATE_PATH)
        cleanTemporaryFiles()
        if installed == state.new_version then
            logger.info(
                "[Burrow updater] Update completed successfully:",
                state.previous_version,
                "to",
                state.new_version
            )
        end
    end
end

function BurrowUpdater:_scheduleAutomaticCheck()
    if not G_reader_settings:isTrue("burrow_auto_update_check") then return end
    if not NetworkMgr:isOnline() then return end
    local last_check = tonumber(G_reader_settings:readSetting("burrow_update_last_check")) or 0
    if os.time() - last_check < self.AUTO_CHECK_INTERVAL then return end
    UIManager:scheduleIn(3, function()
        self:checkForUpdates(false)
    end)
end

function BurrowUpdater:startup(plugin)
    self:_finishPendingUpdate()
    self:attachMenu(plugin)
    self:_scheduleAutomaticCheck()
end

BurrowUpdater.paths = {
    plugin = PLUGIN_DIR,
    work = WORK_DIR,
    backup = BACKUP_DIR,
}

return BurrowUpdater
