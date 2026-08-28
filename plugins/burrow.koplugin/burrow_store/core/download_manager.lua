-- Download Manager for OPDS Browser
-- Handles all file download operations, queuing, and progress tracking

local BD = require("ui/bidi")
local ConfirmBox = require("ui/widget/confirmbox")
local DocumentRegistry = require("document/documentregistry")
local InfoMessage = require("ui/widget/infomessage")
local Trapper = require("ui/trapper")
local UIManager = require("ui/uimanager")
local http = require("socket.http")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local ltn12 = require("ltn12")
local socket = require("socket")
local socketutil = require("socketutil")
local url = require("socket.url")
local util = require("util")
local _ = require("gettext")
local N_ = _.ngettext
local T = require("ffi/util").template

local Constants = require("burrow_store.models.constants")
local StateManager = require("burrow_store.core.state_manager")

local DownloadManager = {}

local function getStoreManager(owner)
	if not owner then return nil end
	if owner.opds_settings then
		return owner
	end
	if owner._manager and owner._manager.opds_settings then
		return owner._manager
	end
	if owner._manager and owner._manager._manager and owner._manager._manager.opds_settings then
		return owner._manager._manager
	end
	return nil
end

local function persistDownloadQueue(owner)
	local manager = getStoreManager(owner)
	StateManager.getInstance():markDirty()
	if manager and manager.opds_settings then
		manager.downloads = owner.downloads
		manager.opds_settings:saveSetting("downloads", owner.downloads)
		manager.opds_settings:flush()
	end
end

-- Invalidate only the cached metadata/cover row for a file that Burrow has
-- replaced. Keep this in the parent KOReader process, rather than inside the
-- download subprocesses, so SQLite is never touched by the worker process.
local function invalidateBookInfo(filepath)
	local ok, BookInfoManager = pcall(require, "bookinfomanager")
	if not ok or not BookInfoManager or type(BookInfoManager.deleteBookInfo) ~= "function" then
		logger.warn("DownloadManager: could not load BookInfoManager to invalidate", filepath)
		return false
	end

	local deleted, err = pcall(BookInfoManager.deleteBookInfo, BookInfoManager, filepath)
	if not deleted then
		logger.warn("DownloadManager: could not invalidate cached book info for", filepath, err)
		return false
	end

	logger.dbg("DownloadManager: invalidated cached book info for", filepath)
	return true
end

-- Compact, validate, and de-duplicate a persisted queue. This also repairs
-- sparse Lua tables, which can otherwise leave an item that cannot be cleared
-- reliably through array operations.
function DownloadManager.repairDownloadQueue(owner)
	local queue = type(owner and owner.downloads) == "table" and owner.downloads or {}
	local numeric_keys = {}
	for key in pairs(queue) do
		if type(key) == "number" and key >= 1 and key == math.floor(key) then
			table.insert(numeric_keys, key)
		end
	end
	table.sort(numeric_keys)

	local repaired = {}
	local seen = {}
	for _, key in ipairs(numeric_keys) do
		local item = queue[key]
		if type(item) == "table"
				and type(item.file) == "string" and item.file ~= ""
				and type(item.url) == "string" and item.url ~= "" then
			local identity = item.file .. "\0" .. item.url
			if not seen[identity] then
				seen[identity] = true
				table.insert(repaired, item)
			end
		end
	end

	local changed = #numeric_keys ~= #repaired
	if not changed then
		for index, key in ipairs(numeric_keys) do
			if key ~= index or queue[key] ~= repaired[index] then
				changed = true
				break
			end
		end
	end
	for key in pairs(queue) do
		if type(key) ~= "number" then
			changed = true
			break
		end
	end

	if type(owner.downloads) ~= "table" then
		owner.downloads = queue
		changed = true
	end
	if changed then
		for key in pairs(queue) do
			queue[key] = nil
		end
		for index, item in ipairs(repaired) do
			queue[index] = item
		end
		owner.downloads = queue
		persistDownloadQueue(owner)
	end
	return changed
end

-- Extract filetype from an acquisition link
-- @param link table Acquisition link with href and type
-- @return string|nil File extension or nil if unsupported
local IMAGE_FILETYPES = {
	avif = true,
	bmp = true,
	gif = true,
	jpeg = true,
	jpg = true,
	png = true,
	svg = true,
	webp = true,
}

local function normalizedMimeType(mime_type)
	if type(mime_type) ~= "string" then return nil end
	return mime_type:lower():match("^%s*([^;]+)")
end

local function filetypeFromHref(href)
	if type(href) ~= "string" then return nil end
	local clean_href = href:match("^[^?#]*") or href
	return util.getFileNameSuffix(clean_href)
end

function DownloadManager.isImageLink(link)
	if type(link) ~= "table" then return false end
	local mime_type = normalizedMimeType(link.type)
	if mime_type and mime_type:match("^image/") then
		return true
	end
	local filetype = filetypeFromHref(link.href)
	return filetype and IMAGE_FILETYPES[filetype:lower()] == true or false
end

function DownloadManager.getFiletype(link)
	-- OPDS cover and thumbnail links are often readable by KOReader's image
	-- provider, but they are not book acquisitions. Never offer them as a
	-- downloadable format alongside EPUB, PDF, CBZ, and other documents.
	if DownloadManager.isImageLink(link) then
		return nil
	end

	local filetype = filetypeFromHref(link.href)
	if filetype then
		filetype = filetype:lower()
	end
	if not filetype or not DocumentRegistry:hasProvider("dummy." .. filetype) then
		filetype = nil
	end
	local mime_type = normalizedMimeType(link.type)
	if not filetype and mime_type and DocumentRegistry:hasProvider(nil, mime_type) then
		filetype = DocumentRegistry:mimeToExt(mime_type)
	end
	if filetype and IMAGE_FILETYPES[filetype:lower()] then
		return nil
	end
	return filetype
end

-- Get the current download directory based on context
-- @param browser table OPDSBrowser instance
-- @return string Download directory path
function DownloadManager.getCurrentDownloadDir(browser)
	if browser.sync then
		return browser.settings.sync_dir
	else
		return G_reader_settings:readSetting("download_dir") or G_reader_settings:readSetting("lastdir")
	end
end

-- Build local download path for a file
-- @param browser table OPDSBrowser instance
-- @param filename string|nil Desired filename (nil to use server filename)
-- @param filetype string File extension
-- @param remote_url string URL to download from
-- @return string Local file path
function DownloadManager.getLocalDownloadPath(browser, filename, filetype, remote_url)
	local download_dir = DownloadManager.getCurrentDownloadDir(browser)

	filename = filename and filename .. "." .. filetype:lower()
		or browser:getServerFileName(remote_url, filetype)
	filename = util.getSafeFilename(filename, download_dir)
	filename = (download_dir ~= "/" and download_dir or "") .. '/' .. filename
	return util.fixUtf8(filename, "_")
end

-- Download a file from remote URL to local path
-- @param browser table OPDSBrowser instance
-- @param local_path string Local file path to save to
-- @param remote_url string URL to download from
-- @param username string|nil Optional HTTP auth username
-- @param password string|nil Optional HTTP auth password
-- @param caller_callback function|nil Callback function on success
-- @return boolean True if download succeeded
function DownloadManager.downloadFile(browser, local_path, remote_url, username, password, caller_callback)
	logger.dbg("Downloading file", local_path, "from", remote_url)
	local code, headers, status
	local parsed = url.parse(remote_url)

	if parsed.scheme == "http" or parsed.scheme == "https" then
		socketutil:set_timeout(socketutil.FILE_BLOCK_TIMEOUT, socketutil.FILE_TOTAL_TIMEOUT)
		code, headers, status = socket.skip(1, http.request {
			url      = remote_url,
			headers  = {
				["Accept-Encoding"] = "identity",
			},
			sink     = ltn12.sink.file(io.open(local_path, "w")),
			user     = username,
			password = password,
		})
		socketutil:reset_timeout()
	else
		UIManager:show(InfoMessage:new {
			text = T(_("Invalid protocol:\n%1"), parsed.scheme),
		})
		return false
	end

	if code == 200 then
		logger.dbg("File downloaded to", local_path)
		if caller_callback then
			caller_callback(local_path)
		end
		return true
	elseif code == Constants.HTTP_STATUS.FOUND and remote_url:match("^https") and headers.location:match("^http[^s]") then
		util.removeFile(local_path)
		UIManager:show(InfoMessage:new {
			text = T(_("Insecure HTTPS → HTTP downgrade attempted by redirect from:\n\n'%1'\n\nto\n\n'%2'.\n\nPlease inform the server administrator that many clients disallow this because it could be a downgrade attack."),
				BD.url(remote_url), BD.url(headers.location)),
			icon = "notice-warning",
		})
	else
		util.removeFile(local_path)
		logger.dbg("DownloadManager:downloadFile: Request failed:", status or code)
		logger.dbg("DownloadManager:downloadFile: Response headers:", headers)
		UIManager:show(InfoMessage:new {
			text = T(_("Could not save file to:\n%1\n%2"),
				BD.filepath(local_path),
				status or code or "network unreachable"),
		})
	end

	return false
end

-- Remove queued copies of a file after it has been downloaded directly from
-- a catalog or from the individual queue screen.
function DownloadManager.removeMatchingFromDownloadQueue(browser, local_path, remote_url)
	DownloadManager.repairDownloadQueue(browser)
	local removed = false
	for index = #browser.downloads, 1, -1 do
		local item = browser.downloads[index]
		if item and item.file == local_path and item.url == remote_url then
			table.remove(browser.downloads, index)
			removed = true
		end
	end
	if removed then
		browser.download_list_updated = true
		persistDownloadQueue(browser)
	end
	return removed
end

-- Check if file exists and prompt user, then download
-- @param browser table OPDSBrowser instance
-- @param local_path string Local file path to save to
-- @param remote_url string URL to download from
-- @param username string|nil Optional HTTP auth username
-- @param password string|nil Optional HTTP auth password
-- @param caller_callback function|nil Callback function on success
function DownloadManager.checkDownloadFile(browser, local_path, remote_url, username, password, caller_callback)
	local function download()
		UIManager:scheduleIn(Constants.UI_TIMING.DOWNLOAD_SCHEDULE_DELAY, function()
			DownloadManager.downloadFile(browser, local_path, remote_url, username, password, function(downloaded_path)
				-- Direct Store downloads run in the main process, so invalidate
				-- the replaced pathname before any caller refreshes the library.
				invalidateBookInfo(downloaded_path)
				DownloadManager.removeMatchingFromDownloadQueue(browser, downloaded_path, remote_url)
				if caller_callback then
					caller_callback(downloaded_path)
				end
			end)
		end)
		UIManager:show(InfoMessage:new {
			text = _("Downloading…"),
			timeout = Constants.UI_TIMING.NOTIFICATION_TIMEOUT,
		})
	end

	if lfs.attributes(local_path) then
		UIManager:show(ConfirmBox:new {
			text = T(_("The file %1 already exists. Do you want to overwrite it?"), BD.filepath(local_path)),
			ok_text = _("Overwrite"),
			ok_callback = function()
				download()
			end,
		})
	else
		download()
	end
end

-- Download all items in the download queue
-- @param browser table OPDSBrowser instance
-- @return number Count of successfully downloaded files
function DownloadManager.downloadDownloadList(browser)
	DownloadManager.repairDownloadQueue(browser)
	local info = InfoMessage:new { text = _("Downloading… (tap to cancel)") }
	UIManager:show(info)
	UIManager:forceRePaint()

	local completed, downloaded = Trapper:dismissableRunInSubprocess(function()
		local dl = {}
		for _, item in ipairs(browser.downloads) do
			if DownloadManager.downloadFile(browser, item.file, item.url, item.username, item.password) then
				dl[item.file] = true
			end
		end
		return dl
	end, info)

	if completed then
		UIManager:close(info)
	end

	local dl_count = #browser.downloads
	for i = dl_count, 1, -1 do
		local item = browser.downloads[i]
		if downloaded and downloaded[item.file] then
			invalidateBookInfo(item.file)
			table.remove(browser.downloads, i)
		else -- if subprocess has been interrupted, check for the downloaded file
			local attr = lfs.attributes(item.file)
			if attr then
				if attr.size > 0 then
					-- The file on disk changed even if the worker was interrupted
					-- before returning its success table, so the old metadata row
					-- must no longer be trusted.
					invalidateBookInfo(item.file)
					table.remove(browser.downloads, i)
				else -- incomplete download
					os.remove(item.file)
				end
			end
		end
	end

	dl_count = dl_count - #browser.downloads
	if dl_count > 0 then
		browser:updateDownloadListItemTable()
		browser.download_list_updated = true
		persistDownloadQueue(browser)
		UIManager:show(InfoMessage:new {
			text = T(N_("1 book downloaded", "%1 books downloaded", dl_count), dl_count)
		})
	end

	return dl_count
end

-- Download pending sync items
-- @param browser table OPDSBrowser instance
-- @param dl_list table List of items to download
-- @return table|nil List of duplicate files or nil
function DownloadManager.downloadPendingSyncs(browser, dl_list)
	local function dismissable_download()
		local info = InfoMessage:new { text = _("Downloading… (tap to cancel)") }
		UIManager:show(info)
		UIManager:forceRePaint()

		local completed, downloaded, duplicate_list = Trapper:dismissableRunInSubprocess(function()
			local dl = {}
			local dupe_list = {}
			for _, item in ipairs(dl_list) do
				if browser.sync_server_list[item.catalog] then
					if lfs.attributes(item.file) and not browser.sync_force then
						table.insert(dupe_list, item)
					else
						if DownloadManager.downloadFile(browser, item.file, item.url, item.username, item.password) then
							dl[item.file] = true
						end
					end
				end
			end
			return dl, dupe_list
		end, info)

		if completed then
			UIManager:close(info)
		end

		local dl_count = 0
		local dl_size = #dl_list
		for i = dl_size, 1, -1 do
			local item = dl_list[i]
			if downloaded and downloaded[item.file] then
				invalidateBookInfo(item.file)
				dl_count = dl_count + 1
				table.remove(dl_list, i)
			else -- if subprocess has been interrupted, check for the downloaded file
				local attr = lfs.attributes(item.file)
				if attr then
					if attr.size > 0 then
						-- Forced sync may have replaced an already cached pathname.
						-- Invalidate before the library can reuse the old metadata.
						invalidateBookInfo(item.file)
						table.remove(dl_list, i)
						-- Only count files touched within the freshness window
						if attr.modification > os.time() - Constants.SYNC.DOWNLOAD_FRESHNESS_SECONDS then
							dl_count = dl_count + 1
						end
					else -- incomplete download
						os.remove(item.file)
					end
				end
			end
		end

		local duplicate_count = duplicate_list and #duplicate_list or 0
		dl_count = dl_count - duplicate_count

		-- Make downloaded count timeout if there's a duplicate file prompt
		local timeout = nil
		if duplicate_count > 0 then
			timeout = Constants.UI_TIMING.DUPLICATE_NOTIFICATION_TIMEOUT
		end

		if dl_count > 0 then
			UIManager:show(InfoMessage:new {
				text = T(N_("1 book downloaded", "%1 books downloaded", dl_count), dl_count),
				timeout = timeout,
			})
		end

		StateManager.getInstance():markDirty()
		return duplicate_list
	end

	return dismissable_download()
end

-- Add item to download queue
-- @param browser table OPDSBrowser instance
-- @param download_item table Item with file, url, username, password, info, catalog
function DownloadManager.addToDownloadQueue(browser, download_item)
	DownloadManager.repairDownloadQueue(browser)
	for _, existing in ipairs(browser.downloads) do
		if existing.file == download_item.file and existing.url == download_item.url then
			return false
		end
	end
	table.insert(browser.downloads, download_item)
	persistDownloadQueue(browser)
	return true
end

-- Remove item from download queue
-- @param browser table OPDSBrowser instance
-- @param index number Index of item to remove
function DownloadManager.removeFromDownloadQueue(browser, index)
	DownloadManager.repairDownloadQueue(browser)
	if type(index) ~= "number" or not browser.downloads[index] then
		return false
	end
	table.remove(browser.downloads, index)
	persistDownloadQueue(browser)
	return true
end

-- Clear all items from download queue
-- @param browser table OPDSBrowser instance
function DownloadManager.clearDownloadQueue(browser)
	for key in pairs(browser.downloads) do
		browser.downloads[key] = nil
	end
	browser.download_list_updated = true
	persistDownloadQueue(browser)
end

return DownloadManager
