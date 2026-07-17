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
    local read_state_path
    local original_read_state
    local original_read_state_backup
    local util
    local created = {}

    local function remember(path)
        table.insert(created, path)
        return path
    end

    local function create(extension, etag, remote_path, server_id)
        remote_path = remote_path or ("/Comics/A B." .. extension)
        return remember((RemoteDocument.create({
            provider = "webdav",
            server_id = server_id or "11111111-2222-4333-8444-555555555555",
            remote_path = remote_path,
            display_name = remote_path:match("([^/]+)$"),
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
        read_state_path = RemoteDocument.getReadStatePath()
        original_read_state = util.readFromFile(read_state_path, "rb")
        original_read_state_backup = util.readFromFile(read_state_path .. ".old", "rb")
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

    before_each(function()
        os.remove(read_state_path)
        os.remove(read_state_path .. ".old")
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
        os.remove(read_state_path)
        os.remove(read_state_path .. ".old")
        if original_read_state then
            assert(util.writeToFile(original_read_state, read_state_path, true))
        end
        if original_read_state_backup then
            assert(util.writeToFile(original_read_state_backup, read_state_path .. ".old", true))
        end
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

    it("writes new and changed descriptors but skips semantically unchanged ones", function()
        local server_id = "11111111-2222-4333-8444-555555555555"
        local remote_path = "/Write-elision/Book.cbz"
        local expected_path = RemoteDocument.getDescriptorRoot() .. "/"
            .. RemoteDocument.getIdentity(server_id, remote_path) .. "/Book.cbz"
        os.remove(expected_path)

        local descriptor = {
            provider = "webdav",
            server_id = server_id,
            remote_path = remote_path,
            display_name = "Book.cbz",
            size = 10 * 1024 * 1024,
            etag = '"v1"',
            last_modified = "Wed, 15 Jul 2026 00:00:00 GMT",
            extension = "cbz",
        }
        local original_write = util.writeToFile
        local writes = 0
        util.writeToFile = function(...)
            writes = writes + 1
            return original_write(...)
        end

        local ok, err = pcall(function()
            local path = remember((RemoteDocument.create(descriptor)))
            assert.equals(expected_path, path)
            assert.equals(1, writes)

            -- Different bytes with the same decoded descriptor must still be
            -- treated as a no-op.
            local encoded = assert(util.readFromFile(path, "rb"))
            assert.is_true(original_write("\n" .. encoded .. "\n", path, true))
            assert.equals(path, (RemoteDocument.create(descriptor)))
            assert.equals(1, writes)

            descriptor.etag = '"v2"'
            assert.equals(path, (RemoteDocument.create(descriptor)))
            assert.equals(2, writes)
            assert.equals('"v2"', RemoteDocument.load(path).etag)
        end)
        util.writeToFile = original_write

        assert.is_true(ok, err)
    end)

    it("persists normalized read state across module and settings reloads", function()
        local server_id = "11111111-2222-4333-8444-555555555555"
        assert.is_true(RemoteDocument.setReadState(
            server_id, "//Comics/Old/../Book.cbz", true))

        local persisted = LuaSettings:open(read_state_path):readSetting("read_items")
        assert.is_table(persisted)
        assert.equals(1, util.tableSize(persisted))

        RemoteDocument = package.reload("document/remotedocument")
        assert.is_true(RemoteDocument.isRead(server_id, "/Comics/Book.cbz"))

        assert.is_true(RemoteDocument.setReadState(server_id, "/Comics/Book.cbz", false))
        RemoteDocument = package.reload("document/remotedocument")
        assert.is_false(RemoteDocument.isRead(server_id, "/Comics/Book.cbz"))
        assert.is_false(RemoteDocument.getReadState(server_id, "/Comics/Book.cbz"))
        assert.is_false(RemoteDocument.getReadStates(server_id)["/Comics/Book.cbz"])
        assert.equals(1, util.tableSize(
            LuaSettings:open(read_state_path):readSetting("read_items")))
    end)

    it("reports a read-state write that did not reach disk", function()
        local original_flush = LuaSettings.flush
        LuaSettings.flush = function(self) return self end
        local ok, err = pcall(RemoteDocument.setReadState,
            "11111111-2222-4333-8444-555555555555", "/Comics/Book.cbz", true)
        LuaSettings.flush = original_flush

        assert.is_false(ok)
        assert.is_truthy(tostring(err):find("could not save WebDAV read state", 1, true))
        assert.is_nil(RemoteDocument.getReadState(
            "11111111-2222-4333-8444-555555555555", "/Comics/Book.cbz"))
    end)

    it("isolates read state by server and exact remote path", function()
        local server_a = "11111111-2222-4333-8444-555555555555"
        local server_b = "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"
        RemoteDocument.setReadState(server_a, "/Comics/Book.cbz", true)
        RemoteDocument.setReadState(server_b, "/Comics/Other.cbz", true)

        assert.is_true(RemoteDocument.isRead(server_a, "/Comics/Book.cbz"))
        assert.is_false(RemoteDocument.isRead(server_b, "/Comics/Book.cbz"))
        assert.is_nil(RemoteDocument.getReadState(server_b, "/Comics/Book.cbz"))
        assert.is_false(RemoteDocument.isRead(server_a, "/Comics/Other.cbz"))
        assert.is_nil(RemoteDocument.getReadState(server_a, "/Comics/Other.cbz"))
        assert.is_true(RemoteDocument.isRead(server_b, "/Comics/Other.cbz"))
        assert.is_false(RemoteDocument.isRead(server_a, "/Comics/Book.cbz.bak"))
    end)

    it("retains read state when unretained streaming progress is purged", function()
        local server_id = "11111111-2222-4333-8444-555555555555"
        local path = create("cbz", nil, "/Comics/Finished.cbz", server_id)
        local settings = DocSettings:open(path)
        settings:saveSetting("summary", { status = "complete" })
        settings:flush()
        RemoteDocument.setReadState(server_id, "/Comics/Finished.cbz", true)

        local previous_retain = cloud_settings:readSetting("webdav_stream_retain_progress")
        cloud_settings:saveSetting("webdav_stream_retain_progress", false)
        local ok, err = pcall(RemoteDocument.cleanupUnretained, cloud_settings)
        if previous_retain == nil then
            cloud_settings:delSetting("webdav_stream_retain_progress")
        else
            cloud_settings:saveSetting("webdav_stream_retain_progress", previous_retain)
        end
        assert.is_true(ok, err)

        assert.is_false(RemoteDocument.isDescriptor(path))
        assert.is_true(RemoteDocument.isRead(server_id, "/Comics/Finished.cbz"))
    end)

    it("clears deleted read state without crossing path or server boundaries", function()
        local server_a = "11111111-2222-4333-8444-555555555555"
        local server_b = "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"
        for _, path in ipairs({
            "/Delete/One.cbz",
            "/Delete/Nested/Two.cbz",
            "/Delete2/Keep.cbz",
            "/Keep/Three.cbz",
        }) do
            RemoteDocument.setReadState(server_a, path, true)
        end
        RemoteDocument.setReadState(server_b, "/Delete/Other.cbz", true)

        -- These entries deliberately have no descriptors: remote deletion must
        -- still clean the durable read-state index before returning early.
        assert.equals(0, RemoteDocument.forgetRemote(server_a, "/Delete/One.cbz"))
        assert.is_nil(RemoteDocument.getReadState(server_a, "/Delete/One.cbz"))
        assert.is_true(RemoteDocument.isRead(server_a, "/Delete/Nested/Two.cbz"))

        assert.equals(0, RemoteDocument.forgetRemote(server_a, "/Delete", true))
        assert.is_nil(RemoteDocument.getReadState(server_a, "/Delete/Nested/Two.cbz"))
        assert.is_true(RemoteDocument.isRead(server_a, "/Delete2/Keep.cbz"))
        assert.is_true(RemoteDocument.isRead(server_a, "/Keep/Three.cbz"))
        assert.is_true(RemoteDocument.isRead(server_b, "/Delete/Other.cbz"))
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

    it("keeps remote page lookahead opt-in", function()
        cloud_settings:delSetting("webdav_stream_lookahead")
        cloud_settings:flush()
        assert.equals(0, assert(RemoteDocument.resolve(create("cbz"))).lookahead)

        cloud_settings:saveSetting("webdav_stream_lookahead", 1)
        cloud_settings:flush()
        assert.equals(1, assert(RemoteDocument.resolve(create("cbz"))).lookahead)
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

    it("forgets descriptors for a deleted remote file or collection", function()
        local server_id = "11111111-2222-4333-8444-555555555555"
        local other_server_id = "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"
        local deleted = create("cbz", nil, "/Delete/One.cbz", server_id)
        local kept = create("cbz", nil, "/Keep/Two.cbz", server_id)
        local other_server = create("cbz", nil, "/Delete/Other.cbz", other_server_id)

        assert.equals(1, RemoteDocument.forgetRemote(server_id, "/Delete", true))
        assert.is_false(RemoteDocument.isDescriptor(deleted))
        assert.is_true(RemoteDocument.isDescriptor(kept))
        assert.is_true(RemoteDocument.isDescriptor(other_server))

        assert.equals(1, RemoteDocument.forgetRemote(other_server_id, "/Delete/Other.cbz"))
        assert.is_false(RemoteDocument.isDescriptor(other_server))
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
