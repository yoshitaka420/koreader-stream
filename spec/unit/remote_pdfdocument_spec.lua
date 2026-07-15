local Archiver = require("ffi/archiver")
local DrawContext = require("ffi/drawcontext")
local ffiUtil = require("ffi/util")
local lfs = require("libs/libkoreader-lfs")

local function shellQuote(value)
    return "'" .. tostring(value):gsub("'", "'\\''") .. "'"
end

local function readFile(path)
    local file = assert(io.open(path, "rb"))
    local data = file:read("*all")
    file:close()
    return data
end

local function waitForFile(path)
    for _ = 1, 200 do
        local file = io.open(path, "rb")
        if file then
            local value = file:read("*all")
            file:close()
            if value ~= "" then return value end
        end
        ffiUtil.usleep(25000)
    end
end

local function startServer(fixture)
    local port_file = os.tmpname()
    local log_file = os.tmpname()
    os.remove(port_file)
    os.remove(log_file)
    local args = {
        os.getenv("PYTHON") or "python3",
        "spec/base/support/webdav_range_server.py",
        "--file", fixture,
        "--port-file", port_file,
        "--log-file", log_file,
    }
    local escaped = {}
    for _, arg in ipairs(args) do table.insert(escaped, shellQuote(arg)) end
    local pid = ffiUtil.runInSubProcess(function()
        os.execute(table.concat(escaped, " "))
    end)
    assert.is_truthy(pid)
    local port = tonumber(waitForFile(port_file))
    assert.is_truthy(port)
    return { pid = pid, port = port, port_file = port_file, log_file = log_file }
end

local function stopServer(server)
    if not server then return end
    ffiUtil.terminateSubProcess(server.pid)
    ffiUtil.isSubProcessDone(server.pid, true)
    os.remove(server.port_file)
    os.remove(server.log_file)
end

describe("remote PdfDocument integration", function()
    local DataStorage
    local DocCache
    local DocumentRegistry
    local LuaSettings
    local RemoteDocument
    local descriptor_path
    local fixture
    local fixture_size
    local server
    local settings
    local original_servers

    setup(function()
        require("commonrequire")
        DataStorage = require("datastorage")
        DocCache = require("document/doccache")
        DocumentRegistry = require("document/documentregistry")
        LuaSettings = require("luasettings")
        RemoteDocument = require("document/remotedocument")

        fixture = assert(os.getenv("KO_HOME")) .. "/remote-pdfdocument.cbz"
        local image = readFile("spec/base/unit/data/sample.jpg")
        local writer = Archiver.Writer:new()
        assert.is_true(writer:open(fixture, "zip"))
        assert.is_true(writer:setZipCompression("store"))
        assert.is_true(writer:addFileFromMemory("001.jpg", image))
        assert.is_true(writer:addFileFromMemory("padding.bin", string.rep("X", 2 * 1024 * 1024)))
        assert.is_true(writer:addFileFromMemory("002.jpg", image))
        assert.is_true(writer:addFileFromMemory("003.jpg", image))
        writer:close()
        fixture_size = assert(lfs.attributes(fixture, "size"))
        server = startServer(fixture)

        settings = LuaSettings:open(DataStorage:getSettingsDir() .. "/cloudstorage.lua")
        original_servers = settings:readSetting("cs_servers")
        settings:saveSetting("cs_servers", {
            {
                type = "webdav",
                id = "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee",
                address = string.format("http://127.0.0.1:%d", server.port),
                username = "reader",
                password = "secret",
            },
        })
        settings:flush()
        descriptor_path = RemoteDocument.create({
            provider = "webdav",
            server_id = "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee",
            remote_path = "/book.cbz",
            display_name = "Integration.cbz",
            size = fixture_size,
            etag = '"fixture-v1"',
            last_modified = "Wed, 15 Jul 2026 00:00:00 GMT",
            extension = "cbz",
        })
    end)

    teardown(function()
        if descriptor_path and RemoteDocument.isDescriptor(descriptor_path) then
            RemoteDocument.forget(descriptor_path)
        end
        DocCache:clear()
        if original_servers == nil then
            settings:delSetting("cs_servers")
        else
            settings:saveSetting("cs_servers", original_servers)
        end
        settings:flush()
        stopServer(server)
        if fixture then os.remove(fixture) end
    end)

    it("opens, seeks, closes, and reopens through the normal document registry", function()
        local document = assert(DocumentRegistry:openDocument(descriptor_path))
        assert.is_true(document.is_remote)
        assert.is_true(document.is_read_only)
        assert.is_true(document.no_persistent_content_cache)
        assert.equals(3, document.info.number_of_pages)

        local page = document._document:openPage(3)
        local width, height = page:getSize(DrawContext.new())
        assert.is_true(width > 0 and height > 0)
        page:close()
        local stats = assert(document:getNetworkStats())
        assert.is_true(stats.bytes_received < fixture_size)
        assert.is_true(stats.request_count > 1)
        document:close()
        assert.is_nil(DocumentRegistry:getReferenceCount(descriptor_path))

        local reopened = assert(DocumentRegistry:openDocument(descriptor_path))
        assert.equals(3, reopened.info.number_of_pages)
        reopened:close()
        assert.is_nil(DocumentRegistry:getReferenceCount(descriptor_path))
    end)
end)
