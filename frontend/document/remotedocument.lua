local DataStorage = require("datastorage")
local DocSettings = require("docsettings")
local ffiUtil = require("ffi/util")
local LuaSettings = require("luasettings")
local lfs = require("libs/libkoreader-lfs")
local md5 = require("ffi/sha2").md5
local random = require("random")
local rapidjson = require("rapidjson")
local util = require("util")
local _ = require("gettext")

local RemoteDocument = {
    descriptor_version = 1,
    descriptor_kind = "koreader-remote-book",
}

-- Reader history canonicalizes paths, while a descriptor created directly
-- from Cloud storage used to be returned as ./remote-books/.... Keep one
-- absolute root so either spelling resolves to the same remote descriptor.
local descriptor_root = DataStorage:getFullDataDir() .. "/remote-books"
local cloud_settings_path = DataStorage:getSettingsDir() .. "/cloudstorage.lua"
local read_state_path = DataStorage:getSettingsDir() .. "/webdav_read_state.lua"
local READ_ITEMS_KEY = "read_items"

local function clamp(value, minimum, maximum, default)
    value = tonumber(value) or default
    return math.max(minimum, math.min(maximum, value))
end

local function safeDisplayName(name, extension)
    name = util.fixUtf8(name or ("Remote book." .. extension), "_")
    name = name:gsub("[/\\%z]", "_")
    if name == "" or name == "." or name == ".." then
        name = "Remote book." .. extension
    end
    if name:lower():sub(-#extension - 1) ~= "." .. extension then
        name = name .. "." .. extension
    end
    return name
end

function RemoteDocument.normalizePath(path)
    assert(type(path) == "string" and path ~= "", "remote path is required")
    local parts = {}
    for part in path:gmatch("[^/]+") do
        if part == ".." then
            table.remove(parts)
        elseif part ~= "." and part ~= "" then
            table.insert(parts, part)
        end
    end
    return "/" .. table.concat(parts, "/")
end

function RemoteDocument.ensureServerId(server)
    if not server.id or server.id == "" then
        server.id = random.uuid(true):lower()
        return true
    end
end

function RemoteDocument.getIdentity(server_id, remote_path)
    assert(type(server_id) == "string" and server_id ~= "", "server ID is required")
    return md5(server_id .. "\0" .. RemoteDocument.normalizePath(remote_path))
end

local function getReadSettings()
    return LuaSettings:open(read_state_path)
end

local function getReadItems(settings)
    local items = settings:readSetting(READ_ITEMS_KEY, {})
    return type(items) == "table" and items or {}
end

function RemoteDocument.getReadStatePath()
    return read_state_path
end

function RemoteDocument.getReadStates(server_id)
    assert(type(server_id) == "string" and server_id ~= "", "server ID is required")
    local states = {}
    for _, item in pairs(getReadItems(getReadSettings())) do
        if type(item) == "table" and item.server_id == server_id
                and type(item.remote_path) == "string" then
            local ok, normalized_path = pcall(RemoteDocument.normalizePath, item.remote_path)
            if ok then
                -- Records written before explicit unread support had no
                -- is_read member and represented the read state implicitly.
                states[normalized_path] = item.is_read ~= false
            end
        end
    end
    return states
end

function RemoteDocument.getReadState(server_id, remote_path)
    assert(type(server_id) == "string" and server_id ~= "", "server ID is required")
    local normalized_path = RemoteDocument.normalizePath(remote_path)
    local identity = RemoteDocument.getIdentity(server_id, normalized_path)
    local item = getReadItems(getReadSettings())[identity]
    if type(item) ~= "table" or item.server_id ~= server_id
            or type(item.remote_path) ~= "string" then
        return
    end
    local ok, item_path = pcall(RemoteDocument.normalizePath, item.remote_path)
    if not ok or item_path ~= normalized_path then return end
    return item.is_read ~= false
end

function RemoteDocument.isRead(server_id, remote_path)
    return RemoteDocument.getReadState(server_id, remote_path) == true
end

function RemoteDocument.setReadState(server_id, remote_path, is_read)
    assert(type(server_id) == "string" and server_id ~= "", "server ID is required")
    assert(type(is_read) == "boolean", "read state must be a boolean")
    local normalized_path = RemoteDocument.normalizePath(remote_path)
    if RemoteDocument.getReadState(server_id, normalized_path) == is_read then
        return true
    end
    local identity = RemoteDocument.getIdentity(server_id, normalized_path)
    local settings = getReadSettings()
    local items = getReadItems(settings)
    items[identity] = {
        server_id = server_id,
        remote_path = normalized_path,
        is_read = is_read,
    }
    settings:saveSetting(READ_ITEMS_KEY, items)
    settings:flush()
    -- LuaSettings:flush() historically does not propagate write errors.
    -- Reopen the file so the UI never reports a durable change that only
    -- existed in this Lua table.
    if RemoteDocument.getReadState(server_id, normalized_path) ~= is_read then
        error("could not save WebDAV read state")
    end
    return true
end

function RemoteDocument.clearReadStates(server_id, remote_path, recursive)
    assert(type(server_id) == "string" and server_id ~= "", "server ID is required")
    local normalized_path = RemoteDocument.normalizePath(remote_path)
    local descendant_prefix = normalized_path == "/" and "/" or normalized_path .. "/"
    local settings = getReadSettings()
    local items = getReadItems(settings)
    local cleared = 0
    for identity, item in pairs(items) do
        if type(item) == "table" and item.server_id == server_id
                and type(item.remote_path) == "string" then
            local ok, item_path = pcall(RemoteDocument.normalizePath, item.remote_path)
            local matches = ok and (item_path == normalized_path
                or (recursive and item_path:sub(1, #descendant_prefix) == descendant_prefix))
            if matches then
                items[identity] = nil
                cleared = cleared + 1
            end
        end
    end
    if cleared > 0 then
        if next(items) then
            settings:saveSetting(READ_ITEMS_KEY, items)
        else
            settings:delSetting(READ_ITEMS_KEY)
        end
        settings:flush()
    end
    return cleared
end

function RemoteDocument.getDescriptorRoot()
    return descriptor_root
end

function RemoteDocument.isStrongETag(etag)
    return type(etag) == "string" and #etag >= 2
        and etag:sub(1, 1) == '"' and etag:sub(-1) == '"'
end

function RemoteDocument.getProbeValidators(probe)
    assert(type(probe) == "table", "remote range probe result is required")
    local etag = RemoteDocument.isStrongETag(probe.etag) and probe.etag or nil
    local last_modified = type(probe.last_modified) == "string"
        and probe.last_modified ~= "" and probe.last_modified or nil
    return etag, last_modified
end

function RemoteDocument.create(descriptor)
    assert(type(descriptor) == "table", "remote descriptor must be a table")
    assert(descriptor.provider == "webdav", "only WebDAV descriptors are supported")
    assert(type(descriptor.server_id) == "string" and descriptor.server_id ~= "", "server ID is required")
    local size = tonumber(descriptor.size)
    assert(size and size > 0 and size < 2^53 and size == math.floor(size),
        "remote size must be a positive exact integer")
    local extension = tostring(descriptor.extension or ""):lower()
    assert(extension == "cbz" or extension == "cbr", "only CBZ and CBR can be streamed")

    local normalized_path = RemoteDocument.normalizePath(descriptor.remote_path)
    local identity = RemoteDocument.getIdentity(descriptor.server_id, normalized_path)
    local directory = descriptor_root .. "/" .. identity
    local path = directory .. "/" .. safeDisplayName(descriptor.display_name, extension)
    local data = {
        version = RemoteDocument.descriptor_version,
        kind = RemoteDocument.descriptor_kind,
        provider = "webdav",
        server_id = descriptor.server_id,
        remote_path = normalized_path,
        display_name = descriptor.display_name,
        size = size,
        etag = descriptor.etag,
        last_modified = descriptor.last_modified,
        extension = extension,
    }
    local encoded, err = rapidjson.encode(data, { pretty = true })
    if not encoded then error(err) end

    -- Reopening a remote book usually recreates the same descriptor. Avoid a
    -- flash write and fsync when neither its serialized bytes nor its decoded
    -- data changed (the latter also covers harmless formatting differences).
    local existing = util.readFromFile(path, "rb")
    if existing then
        local unchanged = existing == encoded
        if not unchanged then
            local decoded_ok, decoded = pcall(rapidjson.decode, existing)
            unchanged = decoded_ok and util.tableEquals(decoded, data)
        end
        if unchanged then
            return path, data
        end
    end

    local ok
    ok, err = util.makePath(directory)
    if not ok and lfs.attributes(directory, "mode") ~= "directory" then error(err) end
    ok, err = util.writeToFile(encoded, path, true)
    if not ok then error(err) end
    return path, data
end

local function canonicalDescriptorPath(path)
    if type(path) ~= "string" or path == "" then return end
    local canonical = ffiUtil.realpath(path)
    if not canonical or canonical:sub(1, #descriptor_root + 1) ~= descriptor_root .. "/" then
        return
    end
    return canonical
end

function RemoteDocument.load(path)
    local canonical = canonicalDescriptorPath(path)
    if not canonical then return end
    local encoded = util.readFromFile(canonical, "rb")
    if not encoded then return end
    local ok, descriptor = pcall(rapidjson.decode, encoded)
    if not ok then return end
    local descriptor_size = type(descriptor) == "table" and tonumber(descriptor.size)
    if type(descriptor) ~= "table"
            or descriptor.kind ~= RemoteDocument.descriptor_kind
            or descriptor.version ~= RemoteDocument.descriptor_version
            or descriptor.provider ~= "webdav"
            or type(descriptor.server_id) ~= "string" or descriptor.server_id == ""
            or type(descriptor.remote_path) ~= "string" or descriptor.remote_path == ""
            or type(descriptor.extension) ~= "string"
            or (descriptor.extension:lower() ~= "cbz" and descriptor.extension:lower() ~= "cbr")
            or not descriptor_size or descriptor_size <= 0 then
        return
    end
    descriptor.size = descriptor_size
    return descriptor
end

function RemoteDocument.isDescriptor(path)
    return RemoteDocument.load(path) ~= nil
end

function RemoteDocument.getDescriptorIdentity(path)
    local descriptor = RemoteDocument.load(path)
    if descriptor then
        return RemoteDocument.getIdentity(descriptor.server_id, descriptor.remote_path)
    end
end

local function joinedUrl(address, path)
    address = tostring(address or ""):gsub("/+$", "")
    path = RemoteDocument.normalizePath(path):gsub("^/+", "")
    return address .. "/" .. util.urlEncode(path, "/")
end

local function findServer(server_id)
    local settings = LuaSettings:open(cloud_settings_path)
    for _, server in ipairs(settings:readSetting("cs_servers", {})) do
        if server.type == "webdav" and server.id == server_id then
            return server, settings
        end
    end
end

function RemoteDocument.buildSource(descriptor, server, settings)
    assert(type(descriptor) == "table", "remote descriptor data is required")
    assert(type(server) == "table" and type(server.address) == "string",
        "WebDAV server settings are required")
    assert(settings and settings.readSetting, "cloud settings are required")
    local cache_mb = clamp(settings:readSetting("webdav_stream_cache_mb"), 8, 64, 32)
    if cache_mb ~= 8 and cache_mb ~= 16 and cache_mb ~= 32 and cache_mb ~= 64 then
        cache_mb = 32
    end
    -- Remote hinting is synchronous: it downloads, decodes and renders every
    -- hinted page. Keep that speculative radio/CPU work opt-in on Kobo.
    local lookahead = clamp(settings:readSetting("webdav_stream_lookahead"), 0, 2, 0)
    local strict = settings:nilOrTrue("webdav_stream_strict")
    local retain_progress = settings:nilOrTrue("webdav_stream_retain_progress")
    local extension = descriptor.extension:lower()
    local strict_limit = 0
    if strict and extension == "cbr" then
        -- Bound archive indexing and each page load independently. This is
        -- deliberately generous for ordinary images while stopping solid RAR
        -- traversal well before a near-complete transfer.
        strict_limit = math.min(64 * 1024 * 1024,
            math.max(16 * 1024 * 1024, math.floor(descriptor.size * 0.25)))
    end
    return {
        provider = "webdav",
        server_id = descriptor.server_id,
        remote_path = descriptor.remote_path,
        display_name = descriptor.display_name,
        extension = extension,
        url = joinedUrl(server.address, descriptor.remote_path),
        username = server.username or "",
        password = server.password or "",
        expected_size = descriptor.size,
        etag = descriptor.etag,
        last_modified = descriptor.last_modified,
        magic = descriptor.display_name or ("remote." .. extension),
        -- Premiumize redirects every range request to its CDN. One MiB blocks
        -- substantially reduce redirect/round-trip overhead for comic images
        -- while remaining well below the bounded RAM cache.
        block_size = 1024 * 1024,
        cache_limit = cache_mb * 1024 * 1024,
        opening_transfer_limit = strict_limit,
        operation_transfer_limit = strict_limit,
        strict_mode = strict and extension == "cbr",
        lookahead = lookahead,
        forget_on_close = not retain_progress,
        show_network_stats = settings:isTrue("webdav_stream_show_stats"),
        weak_validator = not (descriptor.etag and descriptor.etag:sub(1, 1) == '"'
            and descriptor.etag:sub(-1) == '"'),
    }
end

function RemoteDocument.resolve(path, supplied_source)
    if supplied_source and supplied_source.provider == "webdav" and supplied_source.url then
        return supplied_source
    end
    local descriptor = RemoteDocument.load(path)
    if not descriptor then return end
    local server, settings = findServer(descriptor.server_id)
    if not server then
        error(_("The WebDAV server used by this remote book no longer exists."))
    end
    return RemoteDocument.buildSource(descriptor, server, settings)
end

function RemoteDocument.userError(err)
    err = tostring(err or "")
    if err:find("authentication failed", 1, true) then
        return _("WebDAV authentication failed. Check the server username and password.")
    elseif err:find("ignored the byte range", 1, true) or err:find("instead of 206", 1, true) then
        return _("This WebDAV server does not support the byte-range requests required for streaming.")
    elseif err:find("remote file changed", 1, true) or err:find("ETag changed", 1, true)
            or err:find("Last-Modified", 1, true) or err:find("file size changed", 1, true) then
        return _("The remote file changed. Open it again from Cloud storage to refresh its descriptor.")
    elseif err:find("TLS", 1, true) then
        return _("The secure connection to the WebDAV server failed certificate verification or the TLS handshake.")
    elseif err:find("timed out", 1, true) then
        return _("The WebDAV range request timed out.")
    elseif err:find("transfer limit exceeded", 1, true) then
        return _("This CBR cannot be efficiently random-accessed. Convert it to CBZ or disable strict streaming mode to allow sequential streaming.")
    elseif err:find("remote file is unavailable", 1, true) then
        return _("The remote book was deleted, renamed, or is currently unavailable.")
    end
    return _("Could not stream the remote book.") .. "\n" .. err
end

function RemoteDocument.forget(path)
    path = canonicalDescriptorPath(path)
    if not path then return end
    local descriptor = RemoteDocument.load(path)
    if not descriptor then return end
    local doc_settings = DocSettings:open(path)
    doc_settings:purge()
    local ok, history = pcall(require, "readhistory")
    if ok then history:removeItemByPath(path) end
    local ok_collection, collection = pcall(require, "readcollection")
    if ok_collection then collection:removeItem(path) end
    local ok_booklist, BookList = pcall(require, "ui/widget/booklist")
    if ok_booklist then BookList.resetBookInfoCache(path) end
    if lfs.attributes(DataStorage:getSettingsDir() .. "/bookinfo_cache.sqlite3", "mode") == "file" then
        local ok_coverbrowser, BookInfoManager = pcall(require, "bookinfomanager")
        if ok_coverbrowser then BookInfoManager:deleteBookInfo(path) end
    end
    os.remove(path)
    local directory = path:match("^(.*)/[^/]+$")
    if directory then util.removePath(directory) end
    return true
end

function RemoteDocument.forgetRemote(server_id, remote_path, recursive)
    assert(type(server_id) == "string" and server_id ~= "", "server ID is required")
    local normalized_path = RemoteDocument.normalizePath(remote_path)
    RemoteDocument.clearReadStates(server_id, normalized_path, recursive)
    local search_root = descriptor_root
    if not recursive then
        search_root = search_root .. "/" .. RemoteDocument.getIdentity(server_id, normalized_path)
    end
    if lfs.attributes(search_root, "mode") ~= "directory" then return 0 end

    local descriptor_paths = {}
    util.findFiles(search_root, function(path)
        table.insert(descriptor_paths, path)
    end, true)

    local forgotten = 0
    local descendant_prefix = normalized_path == "/" and "/" or normalized_path .. "/"
    for _, path in ipairs(descriptor_paths) do
        local descriptor = RemoteDocument.load(path)
        local matches = descriptor and descriptor.server_id == server_id
            and (descriptor.remote_path == normalized_path
                or (recursive and descriptor.remote_path:sub(1, #descendant_prefix) == descendant_prefix))
        if matches and RemoteDocument.forget(path) then
            forgotten = forgotten + 1
        end
    end
    return forgotten
end

function RemoteDocument.cleanupUnretained(settings)
    settings = settings or LuaSettings:open(cloud_settings_path)
    if settings:nilOrTrue("webdav_stream_retain_progress") then return end
    if lfs.attributes(descriptor_root, "mode") ~= "directory" then return end
    local files = {}
    util.findFiles(descriptor_root, function(path, _, attr)
        table.insert(files, { path = path, size = attr.size })
    end, true)
    for _, file in ipairs(files) do
        if RemoteDocument.isDescriptor(file.path) then
            RemoteDocument.forget(file.path)
        elseif file.size == 0 or file.path:sub(-4) == ".tmp" then
            os.remove(file.path)
            local directory = file.path:match("^(.*)/[^/]+$")
            if directory then util.removePath(directory) end
        end
    end
end

return RemoteDocument
