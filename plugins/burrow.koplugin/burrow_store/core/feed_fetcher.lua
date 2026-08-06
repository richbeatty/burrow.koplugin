-- Feed Fetcher for OPDS Browser
-- Handles all HTTP requests, caching, and feed parsing

local BD = require("ui/bidi")
local Cache = require("cache")
local InfoMessage = require("ui/widget/infomessage")
local UIManager = require("ui/uimanager")
local http = require("socket.http")
local logger = require("logger")
local ltn12 = require("ltn12")
local socket = require("socket")
local socketutil = require("socketutil")
local _ = require("gettext")
local T = require("ffi/util").template

local OPDSParser = require("burrow_store.core.parser")
local Constants = require("burrow_store.models.constants")
local UrlUtils = require("burrow_store.utils.url_utils")
local FileUtils = require("burrow_store.utils.file_utils")
local Result = require("burrow_store.utils.result")

local FeedFetcher = {}

-- Create the catalog cache
local CatalogCache = Cache:new {
	slots = Constants.CACHE_SLOTS,
}

-- Fetch raw XML feed from URL
-- @param item_url string URL to fetch from
-- @param headers_only boolean If true, only fetch headers (HEAD request)
-- @param username string|nil Optional HTTP auth username
-- @param password string|nil Optional HTTP auth password
-- @return string|table XML content or headers, nil on error
function FeedFetcher.fetchFeed(item_url, headers_only, username, password)
	local sink = {}
	socketutil:set_timeout(socketutil.LARGE_BLOCK_TIMEOUT, socketutil.LARGE_TOTAL_TIMEOUT)
	local request = {
		url      = item_url,
		method   = headers_only and "HEAD" or "GET",
		headers  = {
			["Accept-Encoding"] = "identity",
		},
		sink     = ltn12.sink.table(sink),
		user     = username,
		password = password,
	}
	local code, headers, status = socket.skip(1, http.request(request))
	socketutil:reset_timeout()

	if headers_only then
		return headers
	end

	if code == Constants.HTTP_STATUS.OK then
		local xml = table.concat(sink)
		return xml ~= "" and xml
	end

	-- Handle errors
	local text, icon
	if headers and code == Constants.HTTP_STATUS.MOVED_PERMANENTLY then
		text = T(_("The catalog has been permanently moved. Please update catalog URL to '%1'."),
			BD.url(headers.location))
	elseif headers and code == Constants.HTTP_STATUS.FOUND
		and item_url:match("^https")
		and headers.location:match("^http[^s]") then
		text = T(
			_(
				"Insecure HTTPS → HTTP downgrade attempted by redirect from:\n\n'%1'\n\nto\n\n'%2'.\n\nPlease inform the server administrator that many clients disallow this because it could be a downgrade attack."),
			BD.url(item_url), BD.url(headers.location))
		icon = "notice-warning"
	else
		local error_message = {
			["401"] = _("Authentication required for catalog. Please add a username and password."),
			["403"] = _("Failed to authenticate. Please check your username and password."),
			["404"] = _("Catalog not found."),
			["406"] = _("Cannot get catalog. Server refuses to serve uncompressed content."),
		}
		text = code and error_message[tostring(code)] or
			T(_("Cannot get catalog. Server response status: %1."), status or code)
	end

	UIManager:show(InfoMessage:new {
		text = text,
		icon = icon,
	})
	logger.dbg(string.format("OPDS: Failed to fetch catalog `%s`: %s", item_url, text))

	return nil
end

-- Parse feed with caching support
-- @param item_url string URL to fetch and parse
-- @param username string|nil Optional HTTP auth username
-- @param password string|nil Optional HTTP auth password
-- @param debug_callback function|nil Optional debug logging callback
-- @return table Parsed feed or nil on error
local CATALOG_CACHE_TTL_SECONDS = 300

function FeedFetcher.parseFeed(item_url, username, password, debug_callback)
	-- The old path made a HEAD request before every GET. Most OPDS pages are
	-- small, so that doubled connection and TLS setup time. Cache the parsed feed
	-- briefly by URL and refresh it with a single GET when it expires.
	local hash = "opds|catalog|" .. item_url
	local cached = CatalogCache:check(hash)
	if type(cached) == "table" and cached.catalog and cached.cached_at
			and os.time() - cached.cached_at <= CATALOG_CACHE_TTL_SECONDS then
		if debug_callback then
			debug_callback("Catalog cache hit for", item_url)
		end
		return cached.catalog
	end

	if debug_callback then
		debug_callback("Fetching catalog", item_url)
	end
	local feed = FeedFetcher.fetchFeed(item_url, false, username, password)
	if feed then
		local catalog = OPDSParser:parse(feed)
		if catalog then
			CatalogCache:insert(hash, {
				catalog = catalog,
				cached_at = os.time(),
			})
		end
		return catalog
	end

	-- A stale in-memory feed is more useful than a blank page when a catalog
	-- briefly times out or the device loses connectivity between pages.
	if type(cached) == "table" and cached.catalog then
		if debug_callback then
			debug_callback("Using stale catalog cache for", item_url)
		end
		return cached.catalog
	end
	return nil
end

-- Parse feed with Result-based error handling
-- @param item_url string URL to fetch and parse
-- @param username string|nil Optional HTTP auth username
-- @param password string|nil Optional HTTP auth password
-- @param debug_callback function|nil Optional debug logging callback
-- @return Result Result with parsed feed or error
function FeedFetcher.parseFeedResult(item_url, username, password, debug_callback)
	local result = Result.wrapPcall(FeedFetcher.parseFeed)(item_url, username, password, debug_callback)

	-- Convert nil success to error
	if result:isOk() and result.value == nil then
		return Result.err("Failed to fetch or parse feed")
	end

	return result
end

-- Extract server filename from URL headers
-- @param item_url string URL to check
-- @param filetype string|nil Desired file extension
-- @param username string|nil Optional HTTP auth username
-- @param password string|nil Optional HTTP auth password
-- @return string Filename extracted from server or URL
function FeedFetcher.getServerFileName(item_url, filetype, username, password)
	local headers = FeedFetcher.fetchFeed(item_url, true, username, password)
	local filename

	if headers then
		filename = UrlUtils.parseContentDisposition(headers["content-disposition"])

		if not filename and headers["location"] then
			filename = headers["location"]:gsub(".*/", "")
		end
	end

	if not filename then
		filename = UrlUtils.extractFilename(item_url)
	end

	filename = FileUtils.ensureExtension(filename, filetype)

	return filename
end

-- Get OpenSearch template from descriptor URL
-- @param osd_url string OpenSearch descriptor URL
-- @param search_template_type string Expected template MIME type pattern
-- @param username string|nil Optional HTTP auth username
-- @param password string|nil Optional HTTP auth password
-- @param debug_callback function|nil Optional debug logging callback
-- @return string|nil Search template URL with {searchTerms} placeholder
function FeedFetcher.getSearchTemplate(osd_url, search_template_type, username, password, debug_callback)
	local search_descriptor = FeedFetcher.parseFeed(osd_url, username, password, debug_callback)

	---@diagnostic disable-next-line: undefined-field
	if search_descriptor and search_descriptor.OpenSearchDescription and search_descriptor.OpenSearchDescription.Url then
		---@diagnostic disable-next-line: undefined-field
		for _, candidate in ipairs(search_descriptor.OpenSearchDescription.Url) do
			if candidate.type and candidate.template and candidate.type:find(search_template_type) then
				return candidate.template:gsub("{searchTerms}", "%%s")
			end
		end
	end

	return nil
end

-- Generate item table from URL (wrapper for common pattern)
-- @param item_url string URL to fetch catalog from
-- @param username string|nil Optional HTTP auth username
-- @param password string|nil Optional HTTP auth password
-- @param debug_callback function|nil Optional debug logging callback
-- @param catalog_parser function Function to parse catalog into item table
-- @return table Item table suitable for menu display
function FeedFetcher.genItemTableFromURL(item_url, username, password, debug_callback, catalog_parser)
	local result = FeedFetcher.parseFeedResult(item_url, username, password, debug_callback)

	local catalog = result:unwrapOrElse(function(err)
		logger.info("Cannot get catalog info from", item_url, err)
		UIManager:show(InfoMessage:new {
			text = T(_("Cannot get catalog info from %1"), (item_url and BD.url(item_url) or "nil")),
		})
		return nil
	end)

	-- Call the provided catalog parser function
	-- Pass catalog and the item_url
	return catalog_parser(catalog, item_url)
end

-- Clear the catalog cache
function FeedFetcher.clearCache()
	CatalogCache:clear()
end

-- Get cache statistics
-- @return number, number Used slots, total slots
function FeedFetcher.getCacheStats()
	return CatalogCache:used_size(), CatalogCache.slots
end

return FeedFetcher
