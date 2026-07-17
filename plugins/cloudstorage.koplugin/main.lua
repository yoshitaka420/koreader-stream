local DataStorage = require("datastorage")
local Device = require("device")
local Dispatcher = require("dispatcher")
local InfoMessage = require("ui/widget/infomessage")
local LuaSettings = require("luasettings")
local Notification = require("ui/widget/notification")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local ffiUtil = require("ffi/util")
local logger = require("logger")
local util = require("util")
local _ = require("gettext")

local Cloud = WidgetContainer:extend{
    name = "cloudstorage",
    title = _("WebDAV streaming"),
    settings_file = DataStorage:getSettingsDir() .. "/cloudstorage.lua",
    settings = nil,
    servers = nil, -- user servers (array)
    providers = nil, -- cloud providers (hash table); must provide at least .config, .run, .listFolder
    updated = nil,
}

function Cloud:init()
    self:applyKoboPowerDefaults()
    self:getProviders()
    self:loadSettings()
    self:onDispatcherRegisterActions()
    self.ui.menu:registerToMainMenu(self)
    -- This WebDAV-focused build opens Cloud storage on top of the File
    -- Manager as soon as startup has completed. Defer the action by one UI
    -- tick: FileManager runs post-init callbacks while it is still being
    -- constructed and is only placed on the widget stack afterwards.
    -- ReaderUI also exposes registerPostInitCallback, so explicitly exclude
    -- document-backed UIs. Otherwise WebDAV is opened over the freshly
    -- rendered book and looks like the reader crashed.
    if not self.ui.document then
        self.ui:registerPostInitCallback(function()
            UIManager:nextTick(function()
                if not self.ui.tearing_down then
                    self:onShowWebDavStartup()
                end
            end)
        end)
    end
end

-- The focused Kobo build is network-heavy by design. Match upstream's power
-- saving recommendation for new profiles, while preserving an explicit user
-- choice carried over from an existing installation.
function Cloud:applyKoboPowerDefaults()
    if Device:isKobo() and G_reader_settings:hasNot("auto_disable_wifi") then
        G_reader_settings:makeTrue("auto_disable_wifi")
    end
end

function Cloud:getProviders()
    if not Cloud.providers then
        Cloud.providers = {}
        local ok, provider = pcall(dofile, self.path .. "/providers/webdav.lua")
        if ok and next(provider) and provider.name and provider.config and provider.run and provider.listFolder then
            Cloud.providers.webdav = provider
        else
            logger.err("WebDAV streaming: failed to load the WebDAV provider", provider)
        end
    end
end

function Cloud:loadSettings()
    if not Cloud.settings then
        Cloud.settings = LuaSettings:open(self.settings_file)
        if not next(Cloud.settings.data) then
            self.updated = true -- first run, force flush
        end
    end
    self.servers = Cloud.settings:readSetting("cs_servers", {})
    local RemoteDocument = require("document/remotedocument")
    local migrated
    for _, server in ipairs(self.servers) do
        if server.type == "webdav" and RemoteDocument.ensureServerId(server) then
            migrated = true
        end
    end
    if migrated then
        Cloud.settings:saveSetting("cs_servers", self.servers)
        Cloud.settings:flush()
    end
    RemoteDocument.cleanupUnretained(Cloud.settings)
end

function Cloud:onFlushSettings()
    if self.updated then
        Cloud.settings:flush()
        self.updated = nil
    end
end

function Cloud:onDispatcherRegisterActions()
    Dispatcher:registerAction("cloudstorage", { category="none", event="ShowCloudStorageList", title=self.title, general=true })
end

function Cloud:addToMainMenu(menu_items)
    menu_items.cloudstorage = {
        text = self.title,
        callback = function()
            self:onShowCloudStorageList()
        end,
    }
end

function Cloud:onShowCloudStorageList(caller_choose_folder_callback, initial_server_idx)
    local base
    local CloudStorage = require("cloudstorage")
    base = CloudStorage:new{
        title = self.title,
        subtitle = "",
        settings = self.settings,
        servers = self.servers,
        providers = self.providers,
        initial_server_idx = initial_server_idx,
        _manager = self,
        -- external modules can call the plugin to choose the remote folder
        -- see CloudStorage:showFolderChooseDialog() for details of calling the callback
        caller_choose_folder_callback = caller_choose_folder_callback,
    }
    for _, provider in pairs(self.providers) do
        provider.base = base
    end
    base:show()
end

function Cloud:onShowWebDavStartup()
    local server_idx = self.settings:readSetting("default_server")
    if not (server_idx and self.servers[server_idx]
            and self.servers[server_idx].type == "webdav") then
        server_idx = nil
        for idx, server in ipairs(self.servers) do
            if server.type == "webdav" then
                server_idx = idx
                break
            end
        end
    end
    self:onShowCloudStorageList(nil, server_idx)
    return true
end

function Cloud:stopPlugin()
    Cloud.providers = nil
end

-- cloud sync (Statistics, Vocabulary builder)

function Cloud:getServerNameType(server)
    local provider = server and server.type and self.providers[server.type]
    return provider and string.format("%s (%s)", server.name, provider.name)
end

function Cloud.getReadablePath(server)
    local url = server and server.url
    if url then
        url = util.stringStartsWith(url, "/") and url:sub(2) or url
        url = util.urlDecode(url) or url
        url = util.stringEndsWith(url, "/") and url or url .. "/"
        local address = server.address or ""
        url = (address:sub(-1) == "/" and address or address .. "/") .. url
        url = url:sub(-2) == "//" and url:sub(1, -2) or url
    end
    return url
end

-- Former SyncService https://github.com/koreader/koreader/pull/9709
-- Prepares three files for sync_cb to call to do the actual syncing:
-- * local_file (one that is being used)
-- * income_file (one that has just been downloaded from Cloud to be merged, then to be deleted)
-- * cached_file (the one that was uploaded in the previous round of syncing)
--
-- How it works:
--
-- If we simply merge the local file with the income file (ignore duplicates), then items that have been deleted locally
-- but not remotely (on other devices) will re-emerge in the result file. The same goes for items deleted remotely but
-- not locally. To avoid this, we first need to delete them from both the income file and local file.
--
-- The problem is how to identify them, and that is when the cached file comes into play.
-- The cached file represents what local and remote agreed on previously (was identical to local and remote after being uploaded
-- the previous round), by comparing it with local file, items no longer in local file are ones being recently deleted.
-- The same applies to income file. Then we can delete them from both local and income files to be ready for merging. (The actual
-- deletion and merging procedures happen in sync_cb as users of this service will have different file specifications)
--
-- After merging, the income file is no longer needed and is deleted. The local file is uploaded and then a copy of it is saved
-- and renamed to replace the old cached file (thus the naming). The cached file stays (in the same folder) till being replaced
-- in the next round.
function Cloud:sync(server, file_path, sync_cb, is_silent, caller_pre_callback)
    local provider = server and server.type and self.providers[server.type]
    if not provider then return end
    provider.base = server
    provider.run(function()
        if caller_pre_callback then
            caller_pre_callback()
        end
        UIManager:nextTick(function()
            local file_name = ffiUtil.basename(file_path)
            local income_file_path = file_path .. ".temp" -- file downloaded from server
            local cached_file_path = file_path .. ".sync" -- file uploaded to server last time
            local fail_msg = _("Something went wrong when syncing, please check your network connection and try again later.")
            local show_msg = function(msg)
                if is_silent then return end
                UIManager:show(InfoMessage:new{
                    text = msg or fail_msg,
                    timeout = 3,
                })
            end
            local etag
            local code_response = 412 -- If-Match header failed
            while code_response == 412 do
                os.remove(income_file_path)
                code_response, etag = provider.downloadFile(server.url.."/"..file_name, income_file_path)
                if code_response ~= 200 and code_response ~= 404 then
                    show_msg()
                    return
                end
                local ok, cb_return = pcall(sync_cb, file_path, cached_file_path, income_file_path)
                if not ok or not cb_return then
                    show_msg()
                    if not ok then logger.err("sync service callback failed:", cb_return) end
                    return
                end
                code_response = provider.uploadFile(server.url, file_path, etag, true) or 412
            end
            os.remove(income_file_path)
            if type(code_response) == "number" and code_response >= 200 and code_response < 300 then
                os.remove(cached_file_path)
                ffiUtil.copyFile(file_path, cached_file_path)
                UIManager:show(Notification:new{
                    text = _("Successfully synchronized."),
                    timeout = 2,
                })
            else
                show_msg()
            end
        end)
    end)
end

return Cloud
