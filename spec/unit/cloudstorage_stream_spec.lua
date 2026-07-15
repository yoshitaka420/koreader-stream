describe("WebDAV comic selection", function()
    local CloudStorage
    local Cloud

    setup(function()
        require("commonrequire")
        package.path = "plugins/cloudstorage.koplugin/?.lua;" .. package.path
        CloudStorage = require("cloudstorage")
        Cloud = dofile("plugins/cloudstorage.koplugin/main.lua")
    end)

    it("streams CBZ and CBR immediately without an action dialog", function()
        assert.is_nil(CloudStorage.showStreamOrDownloadDialog)
        for _, suffix in ipairs({ "cbz", "cbr", "CBZ" }) do
            local selected
            local storage = setmetatable({
                provider = { type = "webdav" },
                startStreaming = function(_, item) selected = item end,
            }, { __index = CloudStorage })
            local item = {
                is_file = true,
                text = "Comic." .. suffix,
                suffix = suffix,
            }
            assert.is_true(storage:onMenuSelect(item))
            assert.equals(item, selected)
        end
    end)

    it("loads WebDAV as its only cloud provider", function()
        Cloud.providers = nil
        local manager = setmetatable({
            path = "plugins/cloudstorage.koplugin",
        }, { __index = Cloud })

        manager:getProviders()

        assert.is_table(Cloud.providers.webdav)
        assert.is_nil(Cloud.providers.dropbox)
        assert.is_nil(Cloud.providers.ftp)
        local provider_count = 0
        for _ in pairs(Cloud.providers) do
            provider_count = provider_count + 1
        end
        assert.are.same(1, provider_count)
        Cloud.providers = nil
    end)

    it("opens an explicitly selected server without showing the server root", function()
        local opened
        local storage = setmetatable({
            initial_server_idx = 2,
            settings = { readSetting = function() return nil end },
            servers = {
                { url = "/unused" },
                { url = "/comics" },
            },
            paths = {},
            openCloudServer = function(self, url, do_show)
                opened = { server_idx = self.server_idx, url = url, do_show = do_show }
            end,
        }, { __index = CloudStorage })

        storage:show()

        assert.same({ server_idx = 2, url = "/comics", do_show = true }, opened)
        assert.is_nil(storage.initial_server_idx)
    end)

    it("chooses the first WebDAV server for startup", function()
        local selected
        local manager = setmetatable({
            settings = { readSetting = function() return 1 end },
            servers = {
                { type = "ftp" },
                { type = "webdav" },
                { type = "webdav" },
            },
            onShowCloudStorageList = function(_, callback, server_idx)
                assert.is_nil(callback)
                selected = server_idx
            end,
        }, { __index = Cloud })

        assert.is_true(manager:onShowWebDavStartup())
        assert.equals(2, selected)
    end)

    it("defers automatic WebDAV opening until after FileManager initialization", function()
        local UIManager = require("ui/uimanager")
        local post_init_callback
        local queued_callback
        local opened = false
        local manager = setmetatable({
            ui = {
                menu = { registerToMainMenu = function() end },
                folder_shortcuts = { registerShortcut = function() end },
                registerPostInitCallback = function(_, callback)
                    post_init_callback = callback
                end,
            },
            getProviders = function() end,
            loadSettings = function() end,
            onDispatcherRegisterActions = function() end,
            onShowWebDavStartup = function() opened = true end,
        }, { __index = Cloud })

        manager:init()
        assert.is_function(post_init_callback)

        local original_next_tick = UIManager.nextTick
        UIManager.nextTick = function(_, callback) queued_callback = callback end
        local ok, err = pcall(post_init_callback)
        UIManager.nextTick = original_next_tick

        assert.is_true(ok, err)
        assert.is_false(opened)
        assert.is_function(queued_callback)
        queued_callback()
        assert.is_true(opened)
    end)

    it("does not reopen WebDAV over a newly initialized ReaderUI", function()
        local post_init_callback
        local manager = setmetatable({
            ui = {
                document = {},
                menu = { registerToMainMenu = function() end },
                folder_shortcuts = { registerShortcut = function() end },
                registerPostInitCallback = function(_, callback)
                    post_init_callback = callback
                end,
            },
            getProviders = function() end,
            loadSettings = function() end,
            onDispatcherRegisterActions = function() end,
        }, { __index = Cloud })

        manager:init()

        assert.is_nil(post_init_callback)
    end)
end)
