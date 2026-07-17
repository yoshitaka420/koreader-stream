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

    it("decorates read WebDAV rows without losing size or selection state", function()
        local RemoteDocument = require("document/remotedocument")
        local original_get_read_states = RemoteDocument.getReadStates
        local item = {
            is_file = true,
            text = "Done.cbz",
            url = "/Comics/Done.cbz",
            mandatory = "12 MB",
            dim = true,
        }
        local storage = setmetatable({}, { __index = CloudStorage })
        RemoteDocument.getReadStates = function(server_id)
            assert.equals("server-id", server_id)
            return { ["/Comics/Done.cbz"] = true }
        end

        local ok, err = pcall(function()
            storage:applyReadStates({ item }, { type = "webdav", id = "server-id" })
        end)
        RemoteDocument.getReadStates = original_get_read_states

        assert.is_true(ok, err)
        assert.is_true(item.is_read)
        assert.is_truthy(item.mandatory:find("Read", 1, true))
        assert.is_truthy(item.mandatory:find("12 MB", 1, true))
        assert.is_true(item.dim)

        storage:decorateReadState(item, false)
        assert.is_nil(item.is_read)
        assert.equals("12 MB", item.mandatory)
        assert.is_true(item.dim)
    end)

    it("offers mark-as-read and mark-as-unread actions on file long-press", function()
        local UIManager = require("ui/uimanager")
        local original_show = UIManager.show
        local original_close = UIManager.close
        local shown
        local closed
        local state_changes = {}
        local storage = setmetatable({
            provider = { deleteFile = function() end },
            setItemReadState = function(_, selected_item, is_read)
                table.insert(state_changes, { selected_item, is_read })
            end,
        }, { __index = CloudStorage })
        local item = {
            is_file = true,
            text = "Comic.cbz",
            url = "/Comics/Comic.cbz",
        }
        UIManager.show = function(_, widget) shown = widget end
        UIManager.close = function(_, widget) closed = widget end

        local ok, err = pcall(function()
            assert.is_true(storage:onMenuHold(item))
            assert.equals("Mark as read", shown.buttons[1][1].text)
            local first_dialog = shown
            shown.buttons[1][1].callback()
            assert.equals(first_dialog, closed)

            item.is_read = true
            assert.is_true(storage:onMenuHold(item))
            assert.equals("Mark as unread", shown.buttons[1][1].text)
            local second_dialog = shown
            shown.buttons[1][1].callback()
            assert.equals(second_dialog, closed)
        end)
        UIManager.show = original_show
        UIManager.close = original_close

        assert.is_true(ok, err)
        assert.same({
            { item, true },
            { item, false },
        }, state_changes)
    end)

    it("updates the WebDAV row and active remote-book summary when marked manually", function()
        local BookList = require("ui/widget/booklist")
        local RemoteDocument = require("document/remotedocument")
        local UIManager = require("ui/uimanager")
        local original_set_read_state = RemoteDocument.setReadState
        local original_show = UIManager.show
        local file = "/tmp/cloudstorage-read-state-test.cbz"
        local original_book_info = BookList.book_info_cache[file]
        local summary = { status = "reading" }
        local persisted = {}
        local updates = {}
        local item = {
            idx = 4,
            is_file = true,
            text = "Active.cbz",
            url = "/Comics/Active.cbz",
            mandatory = "8 MB",
        }
        local storage = setmetatable({
            servers = { {
                type = "webdav",
                id = "server-id",
            } },
            server_idx = 1,
            _manager = {
                ui = {
                    document = {
                        file = file,
                        is_remote = true,
                        remote_source = {
                            server_id = "server-id",
                            remote_path = item.url,
                        },
                    },
                    doc_settings = {
                        readSetting = function(_, key, default)
                            return key == "summary" and summary or default
                        end,
                    },
                },
            },
            updateItems = function(_, idx, no_recalculate_dimen)
                table.insert(updates, { idx, no_recalculate_dimen })
            end,
        }, { __index = CloudStorage })
        RemoteDocument.setReadState = function(server_id, path, is_read)
            table.insert(persisted, { server_id, path, is_read })
        end
        UIManager.show = function() end

        local ok, err = pcall(function()
            assert.is_true(storage:setItemReadState(item, true))
            assert.is_true(item.is_read)
            assert.is_truthy(item.mandatory:find("Read", 1, true))
            assert.is_truthy(item.mandatory:find("8 MB", 1, true))
            assert.equals("complete", summary.status)

            assert.is_true(storage:setItemReadState(item, false))
            assert.is_nil(item.is_read)
            assert.equals("8 MB", item.mandatory)
            assert.equals("reading", summary.status)
        end)
        RemoteDocument.setReadState = original_set_read_state
        UIManager.show = original_show
        BookList.book_info_cache[file] = original_book_info

        assert.is_true(ok, err)
        assert.same({
            { "server-id", item.url, true },
            { "server-id", item.url, false },
        }, persisted)
        assert.same({ { 4, true }, { 4, true } }, updates)
        assert.matches("^%d%d%d%d%-%d%d%-%d%d$", summary.modified)
    end)

    it("does not show or apply a read-state change that failed to persist", function()
        local RemoteDocument = require("document/remotedocument")
        local UIManager = require("ui/uimanager")
        local original_set_read_state = RemoteDocument.setReadState
        local original_show = UIManager.show
        local shown
        local updated = false
        local item = {
            idx = 1,
            is_file = true,
            text = "Book.cbz",
            url = "/Comics/Book.cbz",
            mandatory = "4 MB",
        }
        local storage = setmetatable({
            servers = { { type = "webdav", id = "server-id" } },
            server_idx = 1,
            updateItems = function() updated = true end,
        }, { __index = CloudStorage })
        RemoteDocument.setReadState = function() error("write failed") end
        UIManager.show = function(_, widget) shown = widget end

        local ok, err = pcall(function()
            assert.is_nil(storage:setItemReadState(item, true))
        end)
        RemoteDocument.setReadState = original_set_read_state
        UIManager.show = original_show

        assert.is_true(ok, err)
        assert.is_nil(item.is_read)
        assert.equals("4 MB", item.mandatory)
        assert.is_false(updated)
        assert.is_truthy(shown.text:find("Could not update read status", 1, true))
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

    it("enables idle Wi-Fi shutdown by default on Kobo without overriding the user", function()
        local Device = require("device")
        local had_setting = G_reader_settings:has("auto_disable_wifi")
        local original_setting = G_reader_settings:readSetting("auto_disable_wifi")
        local original_is_kobo = Device.isKobo
        Device.isKobo = function() return true end
        G_reader_settings:delSetting("auto_disable_wifi")

        local ok, err = pcall(function()
            Cloud:applyKoboPowerDefaults()
            assert.is_true(G_reader_settings:isTrue("auto_disable_wifi"))

            G_reader_settings:makeFalse("auto_disable_wifi")
            Cloud:applyKoboPowerDefaults()
            assert.is_true(G_reader_settings:isFalse("auto_disable_wifi"))
        end)

        Device.isKobo = original_is_kobo
        if had_setting then
            G_reader_settings:saveSetting("auto_disable_wifi", original_setting)
        else
            G_reader_settings:delSetting("auto_disable_wifi")
        end
        assert.is_true(ok, err)
    end)

    it("shows power-saving streaming defaults", function()
        local UIManager = require("ui/uimanager")
        local original_show = UIManager.show
        local shown
        UIManager.show = function(_, widget) shown = widget end
        local storage = setmetatable({
            settings = {
                readSetting = function(_, _, default) return default end,
                nilOrTrue = function() return true end,
                isTrue = function() return false end,
            },
            _manager = {},
        }, { __index = CloudStorage })

        local ok, err = pcall(storage.showStreamingSettingsDialog, storage)
        UIManager.show = original_show

        assert.is_true(ok, err)
        assert.equals("Page lookahead: Off (lower power)", shown.buttons[2][1].text)
        assert.equals("Disable Wi-Fi when inactive", shown.buttons[3][1].text)
    end)

    it("keeps an idle Wi-Fi opt-out across plugin restarts", function()
        local Device = require("device")
        local UIManager = require("ui/uimanager")
        local had_setting = G_reader_settings:has("auto_disable_wifi")
        local original_setting = G_reader_settings:readSetting("auto_disable_wifi")
        local original_is_kobo = Device.isKobo
        local original_show = UIManager.show
        local original_ask_for_restart = UIManager.askForRestart
        local shown
        local restart_requested
        Device.isKobo = function() return true end
        UIManager.show = function(_, widget) shown = widget end
        UIManager.askForRestart = function() restart_requested = true end
        G_reader_settings:makeTrue("auto_disable_wifi")
        local storage = setmetatable({
            settings = {
                readSetting = function(_, _, default) return default end,
                nilOrTrue = function() return true end,
                isTrue = function() return false end,
            },
            _manager = {},
        }, { __index = CloudStorage })

        local ok, err = pcall(function()
            storage:showStreamingSettingsDialog()
            shown.buttons[3][1].callback()
            assert.is_true(restart_requested)
            assert.is_true(G_reader_settings:isFalse("auto_disable_wifi"))

            Cloud:applyKoboPowerDefaults()
            assert.is_true(G_reader_settings:isFalse("auto_disable_wifi"))
        end)

        Device.isKobo = original_is_kobo
        UIManager.show = original_show
        UIManager.askForRestart = original_ask_for_restart
        if had_setting then
            G_reader_settings:saveSetting("auto_disable_wifi", original_setting)
        else
            G_reader_settings:delSetting("auto_disable_wifi")
        end
        assert.is_true(ok, err)
    end)

    it("opens an explicitly selected server without showing the server root", function()
        local opened
        local storage = setmetatable({
            initial_server_idx = 2,
            settings = { readSetting = function() return nil end },
            servers = {
                { url = "/unused" },
                { type = "webdav", url = "/comics" },
            },
            providers = { webdav = {} },
            paths = {},
            openCloudServer = function(self, url, do_show)
                opened = { server_idx = self.server_idx, url = url, do_show = do_show }
            end,
        }, { __index = CloudStorage })

        storage:show()

        assert.same({ server_idx = 2, url = "/comics", do_show = true }, opened)
        assert.is_nil(storage.initial_server_idx)
    end)

    it("ignores a stale default that belongs to a removed provider", function()
        local UIManager = require("ui/uimanager")
        local shown
        local storage = setmetatable({
            settings = { readSetting = function() return 1 end },
            servers = {
                { type = "ftp", url = "/old" },
                { type = "webdav", url = "/comics" },
            },
            providers = { webdav = {} },
            paths = {},
            openCloudServer = function() error("unsupported default must not be opened") end,
        }, { __index = CloudStorage })
        local original_show = UIManager.show
        UIManager.show = function(_, widget) shown = widget end
        local ok, err = pcall(function() storage:show() end)
        UIManager.show = original_show

        assert.is_true(ok, err)
        assert.equals(storage, shown)
        assert.is_nil(storage.server_idx)
    end)

    it("offers deletion for WebDAV folders as well as files", function()
        local selected
        local storage = setmetatable({
            showFolderDialog = function(_, item) selected = item end,
        }, { __index = CloudStorage })
        local folder = { is_folder = true, text = "Old/", url = "/Comics/Old" }

        assert.is_true(storage:onMenuHold(folder))
        assert.equals(folder, selected)
    end)

    it("does not expose generic cloud transfer and sync actions", function()
        local UIManager = require("ui/uimanager")
        local shown
        local storage = setmetatable({
            paths = { { url = "/Comics" } },
            provider = { type = "webdav", deleteFile = function() end },
            providers = { webdav = { name = "WebDAV", config = function() end } },
            servers = { { type = "webdav", name = "DAV" } },
            server_idx = 1,
            collate = "strcoll",
            settings = { readSetting = function() return nil end },
            remote_selected_files = { ["/Comics/Book.cbz"] = true },
        }, { __index = CloudStorage })
        local original_show = UIManager.show
        UIManager.show = function(_, widget) shown = widget end
        local ok, err = pcall(function()
            local function assertFocusedButtons(open_dialog)
                open_dialog()
                local labels = {}
                for _, row in ipairs(shown.buttons) do
                    for _, button in ipairs(row) do
                        if button.text then labels[button.text] = true end
                    end
                end
                assert.is_nil(labels.Download)
                assert.is_nil(labels["Upload file"])
                assert.is_nil(labels["Upload selected files"])
                assert.is_nil(labels["New folder"])
                assert.is_nil(labels["Sync now"])
                assert.is_nil(labels["Sync settings"])
            end
            assertFocusedButtons(function() storage:showPlusCloudDialog() end)
            assertFocusedButtons(function() storage:showSelectModeDialog() end)
            assertFocusedButtons(function()
                storage:showServerDialog({
                    idx = 1,
                    server_idx = 1,
                    type = "webdav",
                    text = "DAV",
                })
            end)
        end)
        UIManager.show = original_show

        assert.is_true(ok, err)
    end)

    it("runs deletion through the provider network guard before refreshing", function()
        local UIManager = require("ui/uimanager")
        local RemoteDocument = require("document/remotedocument")
        local queued_callback
        local delete_count = 0
        local forgotten
        local refreshed
        local item = {
            is_file = true,
            text = "Book.cbz",
            url = "/Comics/Book.cbz",
            dav_url = "https://dav.example.test/canonical/Book.cbz",
        }
        local storage = setmetatable({
            paths = { { url = "/Comics" } },
            providers = {},
            servers = { { type = "webdav", id = "server-id" } },
            server_idx = 1,
            provider = {
                run = function(callback) queued_callback = callback end,
                deleteItem = function(url, is_folder, dav_url)
                    delete_count = delete_count + 1
                    assert.equals(item.url, url)
                    assert.is_false(is_folder)
                    assert.equals(item.dav_url, dav_url)
                    return true
                end,
            },
            openCloudServer = function(_, url) refreshed = url end,
        }, { __index = CloudStorage })
        local original_show = UIManager.show
        local original_forget_remote = RemoteDocument.forgetRemote
        UIManager.show = function() end
        RemoteDocument.forgetRemote = function(server_id, path, recursive)
            forgotten = { server_id, path, recursive }
        end
        local ok, err = pcall(function()
            storage:deleteItem(item)
            assert.equals(0, delete_count)
            assert.is_nil(refreshed)
            assert.is_function(queued_callback)
            queued_callback()
        end)
        UIManager.show = original_show
        RemoteDocument.forgetRemote = original_forget_remote

        assert.is_true(ok, err)
        assert.equals(1, delete_count)
        assert.equals("/Comics", refreshed)
        assert.same({ "server-id", item.url, false }, forgotten)
    end)

    it("refreshes but preserves local metadata when WebDAV says the item was already absent", function()
        local RemoteDocument = require("document/remotedocument")
        local forgot = false
        local storage = setmetatable({
            servers = { { type = "webdav", id = "server-id" } },
            server_idx = 1,
            provider = {
                deleteItem = function() return true, nil, true end,
            },
        }, { __index = CloudStorage })
        local original_forget_remote = RemoteDocument.forgetRemote
        RemoteDocument.forgetRemote = function() forgot = true end

        local ok, err, already_absent = storage:deleteRemoteItem({
            is_file = true,
            text = "Gone.cbz",
            url = "/Comics/Gone.cbz",
        })
        RemoteDocument.forgetRemote = original_forget_remote

        assert.is_true(ok)
        assert.is_nil(err)
        assert.is_true(already_absent)
        assert.is_false(forgot)
    end)

    it("blocks deletion of the open remote book and its parent collection", function()
        local delete_count = 0
        local run_count = 0
        local storage = setmetatable({
            paths = { { url = "/Comics" } },
            servers = { { type = "webdav", id = "server-id" } },
            server_idx = 1,
            _manager = {
                ui = {
                    document = {
                        is_remote = true,
                        remote_source = {
                            server_id = "server-id",
                            remote_path = "/Comics/Open.cbz",
                        },
                    },
                },
            },
            provider = {
                run = function() run_count = run_count + 1 end,
                deleteItem = function()
                    delete_count = delete_count + 1
                    return true
                end,
            },
        }, { __index = CloudStorage })
        local UIManager = require("ui/uimanager")
        local original_show = UIManager.show
        UIManager.show = function() end

        storage:deleteItem({ is_file = true, text = "Open.cbz", url = "/Comics/Open.cbz" })
        storage:deleteItem({ is_folder = true, text = "Comics/", url = "/Comics" })
        local ok = storage:deleteRemoteItem({
            is_file = true,
            text = "Other.cbz",
            url = "/Comics/Other.cbz",
        })
        UIManager.show = original_show

        assert.equals(0, run_count)
        assert.equals(1, delete_count)
        assert.is_true(ok)
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
