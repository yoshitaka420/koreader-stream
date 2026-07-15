describe("remote document descriptors", function()
    local DataStorage
    local CacheItem
    local DocCache
    local DocSettings
    local ffiUtil
    local LuaSettings
    local RemoteDocument
    local cloud_settings
    local original_servers
    local original_cache
    local original_lookahead
    local original_retain
    local original_strict
    local original_stats
    local util
    local created = {}

    local function remember(path)
        table.insert(created, path)
        return path
    end

    local function create(extension, etag)
        return remember((RemoteDocument.create({
            provider = "webdav",
            server_id = "11111111-2222-4333-8444-555555555555",
            remote_path = "/Comics/A B." .. extension,
            display_name = "A B." .. extension,
            size = 10 * 1024 * 1024,
            etag = etag or '"v1"',
            last_modified = "Wed, 15 Jul 2026 00:00:00 GMT",
            extension = extension,
        })))
    end

    setup(function()
        require("commonrequire")
        DataStorage = require("datastorage")
        CacheItem = require("cacheitem")
        DocCache = require("document/doccache")
        DocSettings = require("docsettings")
        ffiUtil = require("ffi/util")
        LuaSettings = require("luasettings")
        RemoteDocument = require("document/remotedocument")
        util = require("util")
        cloud_settings = LuaSettings:open(DataStorage:getSettingsDir() .. "/cloudstorage.lua")
        original_servers = cloud_settings:readSetting("cs_servers")
        original_cache = cloud_settings:readSetting("webdav_stream_cache_mb")
        original_lookahead = cloud_settings:readSetting("webdav_stream_lookahead")
        original_retain = cloud_settings:readSetting("webdav_stream_retain_progress")
        original_strict = cloud_settings:readSetting("webdav_stream_strict")
        original_stats = cloud_settings:readSetting("webdav_stream_show_stats")
        cloud_settings:saveSetting("cs_servers", {
            {
                type = "webdav",
                id = "11111111-2222-4333-8444-555555555555",
                address = "https://dav.example.test/root/",
                username = "alice",
                password = "top-secret",
            },
        })
        cloud_settings:flush()
    end)

    teardown(function()
        for _, path in ipairs(created) do
            if RemoteDocument.isDescriptor(path) then RemoteDocument.forget(path) end
            os.remove(path)
        end
        local function restore(key, value)
            if value == nil then cloud_settings:delSetting(key) else cloud_settings:saveSetting(key, value) end
        end
        restore("cs_servers", original_servers)
        restore("webdav_stream_cache_mb", original_cache)
        restore("webdav_stream_lookahead", original_lookahead)
        restore("webdav_stream_retain_progress", original_retain)
        restore("webdav_stream_strict", original_strict)
        restore("webdav_stream_show_stats", original_stats)
        cloud_settings:flush()
    end)

    it("normalizes paths and derives a stable server/path identity", function()
        assert.equals("/Comics/Book.cbz", RemoteDocument.normalizePath("//Comics/./Old/../Book.cbz"))
        local one = RemoteDocument.getIdentity("server", "/Comics/Book.cbz")
        local two = RemoteDocument.getIdentity("server", "Comics/./Book.cbz")
        assert.equals(one, two)
        assert.are_not.equal(one, RemoteDocument.getIdentity("other-server", "/Comics/Book.cbz"))
    end)

    it("uses only strong validators observed by the ranged GET probe", function()
        local etag, last_modified = RemoteDocument.getProbeValidators({
            etag = '"get-v1"',
            last_modified = "Wed, 15 Jul 2026 00:00:00 GMT",
        })
        assert.equals('"get-v1"', etag)
        assert.equals("Wed, 15 Jul 2026 00:00:00 GMT", last_modified)

        etag, last_modified = RemoteDocument.getProbeValidators({
            etag = 'W/"weak-v1"',
            last_modified = "Wed, 15 Jul 2026 00:00:00 GMT",
        })
        assert.is_nil(etag)
        assert.equals("Wed, 15 Jul 2026 00:00:00 GMT", last_modified)

        etag, last_modified = RemoteDocument.getProbeValidators({
            -- A PROPFIND value must never be substituted when GET omitted it.
            etag = nil,
            last_modified = "Wed, 15 Jul 2026 00:00:00 GMT",
        })
        assert.is_nil(etag)
        assert.equals("Wed, 15 Jul 2026 00:00:00 GMT", last_modified)
    end)

    it("recognizes canonical and historical relative descriptor paths", function()
        local path = create("cbz")
        local absolute = assert(ffiUtil.realpath(path))
        assert.equals("/", RemoteDocument.getDescriptorRoot():sub(1, 1))
        assert.is_true(RemoteDocument.isDescriptor(absolute))
        assert.equals(RemoteDocument.getDescriptorIdentity(path),
            RemoteDocument.getDescriptorIdentity(absolute))

        local data_root = DataStorage:getFullDataDir()
        if data_root == require("libs/libkoreader-lfs").currentdir()
                and absolute:sub(1, #data_root + 1) == data_root .. "/" then
            local relative = "." .. absolute:sub(#data_root + 1)
            assert.is_true(RemoteDocument.isDescriptor(relative))
            assert.equals(RemoteDocument.getDescriptorIdentity(absolute),
                RemoteDocument.getDescriptorIdentity(relative))
        end
    end)

    it("stores only non-secret descriptor data and keeps its path across ETag changes", function()
        local path = create("cbz", '"v1"')
        local encoded = assert(util.readFromFile(path, "rb"))
        assert.is_nil(encoded:find("top-secret", 1, true))
        assert.is_nil(encoded:find("alice", 1, true))
        assert.is_nil(encoded:find("dav.example.test", 1, true))

        local identity = RemoteDocument.getDescriptorIdentity(path)
        local second_path = create("cbz", '"v2"')
        assert.equals(path, second_path)
        assert.equals(identity, RemoteDocument.getDescriptorIdentity(second_path))
        assert.equals('"v2"', RemoteDocument.load(second_path).etag)
    end)

    it("resolves credentials in RAM and applies bounded settings", function()
        cloud_settings:saveSetting("webdav_stream_cache_mb", 64)
        cloud_settings:saveSetting("webdav_stream_lookahead", 2)
        cloud_settings:saveSetting("webdav_stream_show_stats", true)
        cloud_settings:flush()
        local source = assert(RemoteDocument.resolve(create("cbz")))
        assert.equals("https://dav.example.test/root/Comics/A%20B.cbz", source.url)
        assert.equals("alice", source.username)
        assert.equals("top-secret", source.password)
        assert.equals(64 * 1024 * 1024, source.cache_limit)
        assert.equals(1024 * 1024, source.block_size)
        assert.equals(2, source.lookahead)
        assert.is_true(source.show_network_stats)
        assert.is_false(source.strict_mode)
        assert.equals(0, source.opening_transfer_limit)
    end)

    it("caps strict CBR archive-open and page transfers", function()
        cloud_settings:saveSetting("webdav_stream_strict", true)
        cloud_settings:flush()
        local source = assert(RemoteDocument.resolve(create("cbr")))
        assert.is_true(source.strict_mode)
        assert.equals(16 * 1024 * 1024, source.opening_transfer_limit)
        assert.equals(source.opening_transfer_limit, source.operation_transfer_limit)
    end)

    it("uses the stable identity for hash-located metadata", function()
        local path = create("cbz", '"before"')
        local identity = RemoteDocument.getDescriptorIdentity(path)
        local first = DocSettings:getSidecarDir(path, "hash")
        create("cbz", '"after"')
        local second = DocSettings:getSidecarDir(path, "hash")
        assert.equals(first, second)
        assert.is_truthy(first:find(identity, 1, true))
    end)

    it("never serializes remote pages and evicts all matching RAM items", function()
        local path = create("cbz")
        local dumped = false
        local remote_key = "page|" .. path .. "|1"
        local local_key = "page|/local/book.cbz|1"
        DocCache:clear()
        DocCache:insert(remote_key, CacheItem:new{
            doc_path = path,
            persistent = true,
            size = 128,
            dump = function() dumped = true end,
        })
        DocCache:insert(local_key, CacheItem:new{ doc_path = "/local/book.cbz", size = 128 })
        DocCache:serialize(path)
        assert.is_false(dumped)
        DocCache:evictDocument(path)
        assert.is_nil(DocCache.cache:get(remote_key))
        assert.is_not_nil(DocCache.cache:get(local_key))
        DocCache:clear()
    end)

    it("forgets descriptor and progress metadata together", function()
        local path = create("cbz")
        local settings = DocSettings:open(path)
        settings:saveSetting("page", 7)
        local sidecar_dir = assert(settings:flush())
        local sidecar = sidecar_dir .. "/" .. settings.sidecar_filename
        assert.equals("file", require("libs/libkoreader-lfs").attributes(sidecar, "mode"))
        assert.is_true(RemoteDocument.forget(path))
        assert.is_nil(require("libs/libkoreader-lfs").attributes(path, "mode"))
        assert.is_nil(require("libs/libkoreader-lfs").attributes(sidecar, "mode"))
    end)

    it("safely ignores malformed descriptors and removes stale zero-byte stubs", function()
        local root = RemoteDocument.getDescriptorRoot()
        local bad_dir = root .. "/00000000000000000000000000000000"
        local bad_path = bad_dir .. "/broken.cbz"
        assert.is_true(util.makePath(bad_dir))
        assert.is_true(util.writeToFile("{broken", bad_path, true))
        assert.is_false(RemoteDocument.isDescriptor(bad_path))
        os.remove(bad_path)
        assert.is_true(util.writeToFile("", bad_path, true))
        cloud_settings:saveSetting("webdav_stream_retain_progress", false)
        RemoteDocument.cleanupUnretained(cloud_settings)
        assert.is_nil(require("libs/libkoreader-lfs").attributes(bad_path, "mode"))
    end)
end)
