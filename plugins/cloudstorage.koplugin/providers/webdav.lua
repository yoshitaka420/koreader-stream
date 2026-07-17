local RemoteDocument = require("document/remotedocument")
local InfoMessage = require("ui/widget/infomessage")
local MultiInputDialog = require("ui/widget/multiinputdialog")
local NetworkMgr = require("ui/network/manager")
local UIManager = require("ui/uimanager")
local datetime = require("datetime")
local ffiUtil = require("ffi/util")
local http = require("socket.http")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local ltn12 = require("ltn12")
local socket = require("socket")
local socket_url = require("socket.url")
local socketutil = require("socketutil")
local util = require("util")
local _ = require("gettext")

local WebDav = {
    name = _("WebDAV"),
    type = "webdav",
    base = nil, -- CloudStorage self, will be filled in Cloud:onShowCloudStorageList()
}

local WebDavApi = {}

local DELETE_RESPONSE_LIMIT = 64 * 1024

local function getOrigin(url)
    local parsed = socket_url.parse(url)
    local scheme = parsed and parsed.scheme and parsed.scheme:lower()
    local host = parsed and parsed.host and parsed.host:lower()
    if (scheme ~= "http" and scheme ~= "https") or not host
            or parsed.user or parsed.password then
        return
    end
    local port = tonumber(parsed.port) or (scheme == "https" and 443 or 80)
    return scheme, host, port
end

local function isSameOrigin(first_url, second_url)
    local first_scheme, first_host, first_port = getOrigin(first_url)
    local second_scheme, second_host, second_port = getOrigin(second_url)
    return first_scheme ~= nil
        and first_scheme == second_scheme
        and first_host == second_host
        and first_port == second_port
end

local function resolveSameOriginUrl(base_url, href)
    if not href then return end
    href = util.htmlEntitiesToUtf8(href)
    local ok, resolved = pcall(socket_url.absolute, base_url, href)
    if ok and resolved and isSameOrigin(base_url, resolved) then
        return resolved
    end
end

-- Trim leading & trailing slashes from string `s` (based on util.trim)
function WebDavApi.trim_slashes(s)
    local from = s:match"^/*()"
    return from > #s and "" or s:match(".*[^/]", from)
end

-- Trim trailing slashes from string `s` (based on util.rtrim)
function WebDavApi.rtrim_slashes(s)
    local n = #s
    while n > 0 and s:find("^/", n) do
        n = n - 1
    end
    return s:sub(1, n)
end

-- Append path to address with a slash separator, trimming any unwanted slashes in the process.
function WebDavApi.getJoinedPath(address, path)
    local path_encoded = util.urlEncode(path, "/") or ""
    -- Strip leading & trailing slashes from `path`
    local sane_path = WebDavApi.trim_slashes(path_encoded)
    -- Strip trailing slashes from `address` for now
    local sane_address = WebDavApi.rtrim_slashes(address)
    -- Join our final URL
    return sane_address .. "/" .. sane_path
end

function WebDavApi.listFolder(address, user, pass, folder_path, include_folders)
    local path = folder_path or ""
    path = WebDavApi.trim_slashes(path)
    address = WebDavApi.rtrim_slashes(address)
    -- Join our final URL, which *must* have a trailing / (it's a URL)
    -- This is where we deviate from getJoinedPath ;).
    local webdav_url = address .. "/" .. util.urlEncode(path, "/")
    if webdav_url:sub(-1) ~= "/" then
        webdav_url = webdav_url .. "/"
    end
    -- Used to detect the "current folder" item.
    -- The server can store the full url or the relative path in it.
    local webdav_url_path = WebDavApi.trim_slashes(util.urlDecode(webdav_url:match("^https?://[^/]*(.*)$") or webdav_url))

    local sink = {}
    local data = [[<?xml version="1.0"?><a:propfind xmlns:a="DAV:"><a:prop><a:resourcetype/><a:getcontentlength/><a:getlastmodified/><a:getetag/></a:prop></a:propfind>]]
    socketutil:set_timeout(socketutil.FILE_BLOCK_TIMEOUT, socketutil.FILE_TOTAL_TIMEOUT)
    local request = {
        url      = webdav_url,
        method   = "PROPFIND",
        headers  = {
            ["Content-Type"]   = "application/xml",
            ["Depth"]          = "1",
            ["Content-Length"] = #data,
        },
        user     = user,
        password = pass,
        source   = ltn12.source.string(data),
        sink     = ltn12.sink.table(sink),
    }
    local code, headers, status = socket.skip(1, http.request(request))
    socketutil:reset_timeout()
    if headers == nil then
        logger.dbg("WebDavApi:listFolder: No response:", status or code)
        return
    elseif not code or code < 200 or code > 299 then
        -- got a response, but it wasn't a success (e.g. auth failure)
        logger.dbg("WebDavApi:listFolder: Request failed:", status or code)
        logger.dbg("WebDavApi:listFolder: Response headers:", headers)
        logger.dbg("WebDavApi:listFolder: Response body:", table.concat(sink))
        return
    end
    local res = table.concat(sink)
    if res == "" then return end

    local item_list = {}
    -- iterate through the <d:response> tags, each containing an entry
    for item in res:gmatch("<[^:]*:response[^>]*>(.-)</[^:]*:response>") do
        --logger.dbg("WebDav catalog item=", item)
        -- <d:href> is the path and filename of the entry.
        local item_href = item:match("<[^:]*:href[^>]*>(.*)</[^:]*:href>")
        local item_fullpath = util.urlDecode(item_href)
        local item_name = ffiUtil.basename(util.htmlEntitiesToUtf8(item_fullpath))
        -- Keep the server-provided resource URI for state-changing requests.
        -- Rebuilding it from the display name fails with aliases and servers
        -- that canonicalize collection paths. Never retain a URI that would
        -- send WebDAV credentials to another origin.
        local dav_url = resolveSameOriginUrl(webdav_url, item_href)
        local is_not_collection = item:find("<[^:]*:resourcetype%s*/>") or
                                  item:find("<[^:]*:resourcetype>%s*</[^:]*:resourcetype>")
        if is_not_collection then
            local extension = (util.getFileNameSuffix(item_name) or ""):lower()
            if extension == "cbz" or extension == "cbr" then
                local file_size = tonumber(item:match("<[^:]*:getcontentlength[^>]*>(%d+)</[^:]*:getcontentlength>"))
                local item_etag = item:match("<[^:]*:getetag[^>]*>(.-)</[^:]*:getetag>")
                if item_etag then
                    item_etag = util.htmlEntitiesToUtf8(item_etag)
                end
                local modification, suffix, mandatory
                if include_folders then
                    local item_modified = item:match("<[^:]*:getlastmodified[^>]*>(.*)</[^:]*:getlastmodified>")
                    modification = item_modified and datetime.stringRFC1123ToSeconds(item_modified)
                    suffix = util.getFileNameSuffix(item_name)
                    mandatory = util.getFriendlySize(file_size)
                end
                table.insert(item_list, {
                    is_file = true,
                    text = item_name,
                    url = path .. "/" .. item_name,
                    filesize = file_size,
                    etag = item_etag,
                    dav_url = dav_url,
                    modification = modification,
                    suffix = suffix,
                    mandatory = mandatory,
                })
            end
        elseif item:find("<[^:]*:collection[^<]*/>") or item:find("<[^:]*:collection>%s*</[^:]*:collection>") then
            if include_folders then
                local is_not_current_dir = WebDavApi.trim_slashes(item_fullpath) ~= webdav_url_path
                if is_not_current_dir then
                    table.insert(item_list, {
                        is_folder = true,
                        text = item_name .. "/",
                        url = path .. "/" .. item_name,
                        dav_url = dav_url,
                    })
                end
            end
        end
    end
    return item_list
end

function WebDavApi.downloadFile(file_url, user, pass, local_path, progress_callback)
    socketutil:set_timeout(socketutil.FILE_BLOCK_TIMEOUT, socketutil.FILE_TOTAL_TIMEOUT)
    logger.dbg("WebDavApi: downloading file: ", file_url)
    local handle = ltn12.sink.file(io.open(local_path, "w"))
    if progress_callback then
        handle = socketutil.chainSinkWithProgressCallback(handle, progress_callback)
    end
    local code, headers, status = socket.skip(1, http.request {
        url      = file_url,
        method   = "GET",
        sink     = handle,
        user     = user,
        password = pass,
    })
    socketutil:reset_timeout()
    if code ~= 200 then
        logger.warn("WebDavApi: cannot download file:", status or code)
        logger.dbg("WebDavApi: Response headers:", headers)
    end
    return code, headers and headers.etag
end

function WebDavApi.uploadFile(file_url, user, pass, local_path, etag)
    socketutil:set_timeout(socketutil.FILE_BLOCK_TIMEOUT, socketutil.FILE_TOTAL_TIMEOUT)
    local code, _, status = socket.skip(1, http.request{
        url      = file_url,
        method   = "PUT",
        source   = ltn12.source.file(io.open(local_path, "r")),
        user     = user,
        password = pass,
        headers  = {
            ["Content-Length"] = lfs.attributes(local_path, "size"),
            ["If-Match"] = etag,
        },
    })
    socketutil:reset_timeout()
    if type(code) == "number" and code >= 200 and code <= 299 then
        code = 200
    else
        logger.warn("WebDavApi: cannot upload file:", status or code)
    end
    return code
end

local function getMultiStatusFailure(body)
    local found
    for code in body:gmatch("HTTP/%d+%.%d+%s+(%d%d%d)") do
        found = true
        code = tonumber(code)
        if not code or code < 200 or code > 299 then return code or "invalid" end
    end
    if not found then return "unparseable" end
end

function WebDavApi.deleteItem(item_url, user, pass, is_folder)
    if not getOrigin(item_url) then
        return nil, "invalid WebDAV DELETE URL"
    end
    socketutil:set_timeout(socketutil.FILE_BLOCK_TIMEOUT, socketutil.FILE_TOTAL_TIMEOUT)
    local request_url = item_url
    local code, headers, status, response_body, response_truncated
    local request_ok, request_error = pcall(function()
        for _ = 1, 4 do
            local sink = {}
            local response_size = 0
            response_truncated = false
            local function responseSink(chunk)
                if chunk then
                    local remaining = DELETE_RESPONSE_LIMIT - response_size
                    if remaining > 0 then
                        table.insert(sink, chunk:sub(1, remaining))
                        response_size = response_size + math.min(#chunk, remaining)
                    end
                    if #chunk > remaining then response_truncated = true end
                end
                return 1
            end
            local request_headers = {
                ["Content-Length"] = 0,
            }
            if is_folder then request_headers.Depth = "infinity" end
            code, headers, status = socket.skip(1, http.request{
                url      = request_url,
                method   = "DELETE",
                headers  = request_headers,
                sink     = responseSink,
                user     = user,
                password = pass,
            })
            response_body = table.concat(sink)

            if code ~= 301 and code ~= 302 and code ~= 307 and code ~= 308 then
                return
            end
            local location = headers and (headers.location or headers.Location)
            local redirected_url = location and socket_url.absolute(request_url, location)
            if not redirected_url or not isSameOrigin(item_url, redirected_url) then
                status = "refused unsafe WebDAV DELETE redirect"
                code = nil
                return
            end
            request_url = redirected_url
        end
        code = nil
        status = "too many WebDAV DELETE redirects"
    end)
    socketutil:reset_timeout()

    if not request_ok then
        logger.warn("WebDavApi: DELETE request failed:", request_error)
        return nil, tostring(request_error)
    end
    -- DELETE is idempotent. A stale listing that now returns Not Found or Gone
    -- has already reached the state the user requested.
    if code == 404 or code == 410 then
        return true, nil, true
    end
    if type(code) == "number" and code >= 200 and code <= 299 then
        if code == 207 then
            local failed_code = response_truncated and "oversized"
                or getMultiStatusFailure(response_body)
            if failed_code then
                local err = type(failed_code) == "number"
                    and "WebDAV multi-status failure: HTTP " .. failed_code
                    or "WebDAV multi-status failure: " .. failed_code .. " response"
                logger.warn("WebDavApi: cannot delete item:", err)
                return nil, err
            end
        end
        return true
    end
    local err = status or code or "network unreachable"
    logger.warn("WebDavApi: cannot delete item:", err)
    return nil, tostring(err)
end

-- WebDav

function WebDav.run(caller_callback)
    if NetworkMgr:willRerunWhenConnected(function() WebDav.run(caller_callback) end) then
        return
    end
    return caller_callback()
end

function WebDav.listFolder(url, include_folders)
    local base = WebDav.base
    -- list or nil
    return WebDavApi.listFolder(base.address, base.username, base.password, url, include_folders)
end

function WebDav.downloadFile(url, local_path, progress_callback)
    local base = WebDav.base
    local path = WebDavApi.getJoinedPath(base.address, url)
    -- code, etag
    return WebDavApi.downloadFile(path, base.username, base.password, local_path, progress_callback)
end

function WebDav.probeRange(url, expected_size)
    local base = WebDav.base
    local path = WebDavApi.getJoinedPath(base.address, url)
    local ok, result = pcall(require("ffi/mupdf").probeRemote, {
        url = path,
        username = base.username,
        password = base.password,
        expected_size = expected_size or 0,
    })
    if not ok then
        return nil, RemoteDocument.userError(result)
    end
    return result
end

function WebDav.uploadFile(url, local_path, etag)
    local base = WebDav.base
    local path = WebDavApi.getJoinedPath(base.address, url)
    path = WebDavApi.getJoinedPath(path, ffiUtil.basename(local_path))
    -- code
    return WebDavApi.uploadFile(path, base.username, base.password, local_path, etag)
end

function WebDav.deleteItem(url, is_folder, dav_url)
    local base = WebDav.base
    local path = dav_url and resolveSameOriginUrl(base.address, dav_url)
    if dav_url and not path then
        return nil, "refused unsafe WebDAV resource URL"
    end
    path = path or WebDavApi.getJoinedPath(base.address, url)
    if is_folder and path:sub(-1) ~= "/" then
        path = path .. "/"
    end
    -- ok, error
    return WebDavApi.deleteItem(path, base.username, base.password, is_folder)
end

-- Keep the provider API used by upstream callers while the focused UI uses
-- the item-aware variant above for both files and WebDAV collections.
WebDav.deleteFile = WebDav.deleteItem

function WebDav.config(server_idx, caller_callback)
    local text_info = _([[Server address must be of the form http(s)://domain.name/path
This can point to a sub-directory of the WebDAV server.
The start folder is appended to the server path.]])
    local item = server_idx and WebDav.base.servers[server_idx] or { type = WebDav.type }
    RemoteDocument.ensureServerId(item)
    local settings_dialog
    settings_dialog = MultiInputDialog:new{
        title = _("WebDAV server settings"),
        fields = {
            {
                text = item.name,
                hint = _("Name"),
            },
            {
                text = item.address,
                hint = _("WebDAV address, for example https://example.com/dav"),
            },
            {
                text = item.username,
                hint = _("Username"),
            },
            {
                text = item.password,
                text_type = "password",
                hint = _("Password"),
            },
            {
                text = item.url,
                hint = _("Start folder, for example /books"),
            },
        },
        buttons = {
            {
                {
                    text = _("Cancel"),
                    id = "close",
                    callback = function()
                        UIManager:close(settings_dialog)
                    end,
                },
                {
                    text = _("Info"),
                    callback = function()
                        UIManager:show(InfoMessage:new{ text = text_info })
                    end,
                },
                {
                    text = _("Save"),
                    callback = function()
                        local fields = settings_dialog:getFields()
                        -- make sure the URL is a valid path
                        if fields[5] ~= "" then
                            if not fields[5]:match('^/') then
                                fields[5] = '/' .. fields[5]
                            end
                            fields[5] = fields[5]:gsub("/$", "")
                        end
                        item.name     = fields[1]
                        item.address  = fields[2]
                        item.username = fields[3]
                        item.password = fields[4]
                        item.url      = fields[5]
                        RemoteDocument.ensureServerId(item)
                        UIManager:close(settings_dialog)
                        caller_callback(item)
                    end,
                },
            },
        },
    }
    UIManager:show(settings_dialog)
    settings_dialog:onShowKeyboard()
end

return WebDav
