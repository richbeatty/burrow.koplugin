local Updater = require("burrow_updater_fix")

local Archiver = require("ffi/archiver")
local Paths = require("burrow_update_paths")
local lfs = require("libs/libkoreader-lfs")
local ltn12 = require("ltn12")
local logger = require("logger")
local sha256 = require("ffi/sha2").sha256
local socket = require("socket")
local socketutil = require("socketutil")
local http = require("socket.http")

local WORK_DIR = assert(Updater.paths and Updater.paths.work, "Burrow updater work path is unavailable")
local STAGING_DIR = WORK_DIR .. "/staging"
local STAGING_PLUGIN_DIR = STAGING_DIR .. "/plugins/burrow.koplugin"
local DOWNLOAD_PATH = WORK_DIR .. "/Burrow-update.zip"
local MANIFEST_PATH = STAGING_DIR .. "/FILES.sha256"
local MAX_ARCHIVE_SIZE = Updater.MAX_ARCHIVE_SIZE or (10 * 1024 * 1024)
local MAX_EXTRACTED_SIZE = 25 * 1024 * 1024
local MAX_EXTRACTED_FILES = 2000
local TRUSTED_RELEASE_PREFIX = "https://github.com/" .. Updater.REPOSITORY .. "/releases/download/"

local function pathMode(path)
    return lfs.attributes(path, "mode")
end

local function mkdirp(path)
    path = tostring(path or ""):gsub("/+$", "")
    if path == "" or path == "." then return true end
    if pathMode(path) == "directory" then return true end

    local parent = Paths.parent(path)
    if parent and parent ~= path and pathMode(parent) ~= "directory" then
        local ok, err = mkdirp(parent)
        if not ok then return nil, err end
    end

    local ok, err = lfs.mkdir(path)
    if ok or pathMode(path) == "directory" then
        return true
    end
    return nil, err or ("could not create directory " .. path)
end

local function removeTree(path)
    local mode = pathMode(path)
    if not mode then return true end
    if mode ~= "directory" then
        local ok, err = os.remove(path)
        if ok or not pathMode(path) then return true end
        return nil, err or ("could not remove file " .. path)
    end

    for name in lfs.dir(path) do
        if name ~= "." and name ~= ".." then
            local ok, err = removeTree(path .. "/" .. name)
            if not ok then return nil, err end
        end
    end
    local ok, err = lfs.rmdir(path)
    if ok or not pathMode(path) then return true end
    return nil, err or ("could not remove directory " .. path)
end

local function readFile(path)
    local file, err = io.open(path, "rb")
    if not file then return nil, err end
    local content = file:read("*a")
    file:close()
    return content
end

local function trustedReleaseUrl(url)
    return type(url) == "string" and url:sub(1, #TRUSTED_RELEASE_PREFIX) == TRUSTED_RELEASE_PREFIX
end

local function httpGetSmall(url, accept)
    if not trustedReleaseUrl(url) then
        return nil, "release asset URL is not a trusted Burrow GitHub URL"
    end

    local sink = {}
    socketutil:set_timeout(socketutil.LARGE_BLOCK_TIMEOUT, socketutil.LARGE_TOTAL_TIMEOUT)
    local ok, code, headers, status = pcall(function()
        return socket.skip(1, http.request {
            url = url,
            method = "GET",
            redirect = true,
            sink = ltn12.sink.table(sink),
            headers = {
                ["Accept"] = accept or "application/octet-stream",
                ["User-Agent"] = "Burrow/" .. tostring(require("burrow_version").VERSION) .. " KOReader",
            },
        })
    end)
    socketutil:reset_timeout()

    if not ok then return nil, tostring(code) end
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
    return content
end

local function downloadFile(url, destination)
    if not trustedReleaseUrl(url) then
        return nil, "release asset URL is not a trusted Burrow GitHub URL"
    end

    local parent = Paths.parent(destination)
    if parent then
        local ok, err = mkdirp(parent)
        if not ok then return nil, err end
    end

    local file, open_err = io.open(destination, "wb")
    if not file then return nil, open_err end

    local block_timeout = socketutil.FILE_BLOCK_TIMEOUT or socketutil.LARGE_BLOCK_TIMEOUT
    local total_timeout = socketutil.FILE_TOTAL_TIMEOUT or socketutil.LARGE_TOTAL_TIMEOUT
    socketutil:set_timeout(block_timeout, total_timeout)
    local ok, code, headers, status = pcall(function()
        return socket.skip(1, http.request {
            url = url,
            method = "GET",
            redirect = true,
            sink = ltn12.sink.file(file),
            headers = {
                ["Accept"] = "application/octet-stream",
                ["User-Agent"] = "Burrow/" .. tostring(require("burrow_version").VERSION) .. " KOReader",
            },
        })
    end)
    socketutil:reset_timeout()
    pcall(function() file:close() end)

    if not ok then
        os.remove(destination)
        return nil, tostring(code)
    end
    code = tonumber(code)
    if not code or code < 200 or code > 299 then
        os.remove(destination)
        return nil, tostring(status or code or "network unavailable")
    end

    local attributes = lfs.attributes(destination)
    local size = attributes and tonumber(attributes.size) or 0
    if size <= 0 then
        os.remove(destination)
        return nil, "the downloaded update is empty"
    end
    if size > MAX_ARCHIVE_SIZE then
        os.remove(destination)
        return nil, "the downloaded update is larger than Burrow allows"
    end
    if headers and headers["content-length"] then
        local expected = tonumber(headers["content-length"])
        if expected and size ~= expected then
            os.remove(destination)
            return nil, "the downloaded update is incomplete"
        end
    end
    return true
end

local function expectedArchiveDigest(release)
    local digest = release and release.zip_asset and release.zip_asset.digest
    if type(digest) == "string" then
        local value = digest:match("^sha256:([0-9a-fA-F]+)$")
        if value and #value == 64 then
            return value:lower()
        end
    end

    local checksum_asset = release and release.checksum_asset
    if not checksum_asset or not checksum_asset.browser_download_url then
        return nil, "the release does not include a SHA-256 checksum"
    end
    local content, err = httpGetSmall(checksum_asset.browser_download_url)
    if not content then return nil, err end
    local value = content:match("^%s*([0-9a-fA-F]+)")
    if not value or #value ~= 64 then
        return nil, "the release checksum is invalid"
    end
    return value:lower()
end

local function archiveFailure(reader, message)
    local err = reader.err or message
    reader:close()
    return nil, err
end

local function extractReleaseArchive(archive_path)
    local reader = Archiver.Reader:new()
    if not reader:open(archive_path) then
        return archiveFailure(reader, "could not open update archive")
    end

    local plugin_prefix = "plugins/burrow.koplugin/"
    local saw_plugin_file = false
    local saw_manifest = false
    local extracted_size = 0
    local extracted_files = 0
    local seen = {}

    for entry in reader:iterate() do
        local normalized, path_err = Paths.normalizeArchivePath(entry.path)
        if not normalized then
            return archiveFailure(reader, "unsafe archive path: " .. tostring(path_err))
        end

        local is_plugin_root = normalized == "plugins/burrow.koplugin"
        local is_plugin_entry = normalized:sub(1, #plugin_prefix) == plugin_prefix
        local is_manifest = normalized == "FILES.sha256"
        local selected = is_plugin_root or is_plugin_entry or is_manifest

        if selected then
            if entry.mode ~= "file" and entry.mode ~= "directory" then
                return archiveFailure(reader, "the update archive contains an unsupported Burrow entry type")
            end

            if entry.mode == "file" then
                if is_plugin_root then
                    return archiveFailure(reader, "the Burrow plugin root is not a directory")
                end
                if seen[normalized] then
                    return archiveFailure(reader, "the update archive contains a duplicate path: " .. normalized)
                end
                seen[normalized] = true

                extracted_files = extracted_files + 1
                extracted_size = extracted_size + (tonumber(entry.size) or 0)
                if extracted_files > MAX_EXTRACTED_FILES then
                    return archiveFailure(reader, "the update archive contains too many files")
                end
                if extracted_size > MAX_EXTRACTED_SIZE then
                    return archiveFailure(reader, "the extracted update is larger than Burrow allows")
                end

                local destination = STAGING_DIR .. "/" .. normalized
                local parent = Paths.parent(destination)
                if parent then
                    local ok, err = mkdirp(parent)
                    if not ok then
                        return archiveFailure(reader, "could not create staging directory: " .. tostring(err))
                    end
                end

                if not reader:extractToPath(entry.path, destination) then
                    return archiveFailure(reader, "could not extract " .. normalized)
                end

                if is_plugin_entry then saw_plugin_file = true end
                if is_manifest then saw_manifest = true end
            end
            -- Directory entries are intentionally ignored. libarchive writes
            -- selected files to explicit destinations after their real parent
            -- directories have been created. This avoids depending on whether a
            -- ZIP includes directory records such as plugins/ or *.koplugin/.
        end
    end

    local iteration_err = reader.err
    reader:close()
    if iteration_err then return nil, iteration_err end
    if not saw_plugin_file or not saw_manifest then
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
                local nested, err = collectFiles(root, child_relative, output)
                if not nested then return nil, err end
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
                if expected[relative] then
                    return nil, "FILES.sha256 contains a duplicate Burrow path: " .. relative
                end
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
    for _, required in ipairs {
        "main.lua",
        "_meta.lua",
        "burrow_version.lua",
        "burrow_updater.lua",
        "burrow_updater_fix.lua",
        "burrow_updater_prepare_fix.lua",
        "burrow_update_paths.lua",
    } do
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

function Updater:_prepareRelease(release)
    os.remove(DOWNLOAD_PATH)
    local removed, remove_err = removeTree(STAGING_DIR)
    if not removed then
        error("Preparation cleanup failed: " .. tostring(remove_err), 0)
    end

    local ok, err = mkdirp(WORK_DIR)
    if not ok then error("Could not create updater work directory: " .. tostring(err), 0) end
    ok, err = mkdirp(STAGING_DIR)
    if not ok then error("Could not create staging directory: " .. tostring(err), 0) end

    local expected_digest, digest_err = expectedArchiveDigest(release)
    if not expected_digest then
        error("Could not obtain release checksum: " .. tostring(digest_err), 0)
    end

    ok, err = downloadFile(release.zip_asset.browser_download_url, DOWNLOAD_PATH)
    if not ok then
        error("Could not download update archive: " .. tostring(err), 0)
    end

    local archive_content, read_err = readFile(DOWNLOAD_PATH)
    if not archive_content then
        error("Could not read downloaded update archive: " .. tostring(read_err), 0)
    end
    if sha256(archive_content):lower() ~= expected_digest then
        archive_content = nil
        error("Downloaded update did not match its SHA-256 checksum", 0)
    end
    archive_content = nil

    ok, err = extractReleaseArchive(DOWNLOAD_PATH)
    if not ok then
        error("Could not extract update archive: " .. tostring(err), 0)
    end

    ok, err = validatePlugin(release.version)
    if not ok then
        error("Staged update validation failed: " .. tostring(err), 0)
    end

    logger.info("[Burrow updater] Prepared and verified Burrow", release.version)
end

Updater._normalizeArchivePathForTest = Paths.normalizeArchivePath

return Updater
