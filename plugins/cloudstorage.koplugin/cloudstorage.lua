local BD = require("ui/bidi")
local BookList = require("ui/widget/booklist")
local ButtonDialog = require("ui/widget/buttondialog")
local ButtonSelector = require("ui/widget/buttonselector")
local ConfirmBox = require("ui/widget/confirmbox")
local InfoMessage = require("ui/widget/infomessage")
local SortWidget = require("ui/widget/sortwidget")
local UIManager = require("ui/uimanager")
local ffiUtil = require("ffi/util")
local logger = require("logger")
local sort = require("sort")
local util = require("util")
local _ = require("gettext")
local N_ = _.ngettext
local T = ffiUtil.template

local CloudStorage = BookList:extend{
    collates = {
        strcoll = {
            text = _("name"),
            sort_func = function(a, b)
                return ffiUtil.strcoll(a.text, b.text)
            end,
        },
        natural = {
            text = _("name (natural sorting)"),
            sort_func = function(a, b)
                local natsort = sort.natsort_cmp()
                return natsort(a.text, b.text)
            end,
        },
        type = {
            text = _("type"),
            sort_func = function(a, b)
                if (a.suffix or b.suffix) and a.suffix ~= b.suffix then
                    return ffiUtil.strcoll(a.suffix, b.suffix)
                end
                return ffiUtil.strcoll(a.text, b.text)
            end,
        },
        size = {
            text = _("size"),
            sort_func = function(a, b)
                if a.filesize and b.filesize then
                    return a.filesize < b.filesize
                end
                return ffiUtil.strcoll(a.text, b.text)
            end,
        },
        date = {
            text = _("date modified"),
            sort_func = function(a, b)
                if a.modification and b.modification then
                    return a.modification > b.modification
                end
                return ffiUtil.strcoll(a.text, b.text)
            end,
        },
    },
}

function CloudStorage:init(re_init)
    self.choose_folder_callback = nil
    self.item_table = {}
    for i, server in ipairs(self.servers) do
        if self.providers[server.type] then
            table.insert(self.item_table, self:genItemFromServer(i))
        end
        if #self.item_table > 1 then
            table.sort(self.item_table, function(a, b) return a.order < b.order end)
        end
    end
    if re_init then
        self.paths = {}
        self:switchItemTable(self.title, self.item_table, self.item_idx, nil, "")
        self.item_idx = nil -- set item_idx before opening a server to keep the page when reopening the root list
        self.remote_selected_files = nil -- select mode off
        self:setTitleBarLeftIcon("plus")
    else
        self.title_bar_left_icon = "plus"
        self.onLeftButtonTap = function()
            if next(self.paths) then -- cloud
                if self.remote_selected_files then
                    self:showSelectModeDialog()
                else
                    self:showPlusCloudDialog()
                end
            else -- root
                self:showPlusRootDialog()
            end
        end
        self.onLeftButtonHold = function()
            if next(self.paths) and not self.choose_folder_callback then
                self:toggleSelectMode()
            end
        end
        BookList.init(self)
    end
end

function CloudStorage:genItemFromServer(idx)
    local server = self.servers[idx]
    local mandatory = self.providers[server.type].name
    if idx == self.settings:readSetting("default_server") then
        mandatory = "★ " .. mandatory
    end
    return {
        text = server.name,
        mandatory = mandatory,
        server_idx = idx,
        type = server.type,
        url = server.url,
        order = server.order or idx,
    }
end

function CloudStorage:initServer(server_idx)
    local server = self.servers[server_idx]
    self.provider = self.providers[server.type]
    self.address = server.address
    self.username = server.username
    self.password = server.password
    self.collate = server.collate or "strcoll"
    return server
end

function CloudStorage:sortItemTable(tbl, url)
    tbl = tbl or self.item_table

    local folder_mode_item
    if self.choose_folder_callback and #tbl > 0 and tbl[1].is_folder_long_press then
        folder_mode_item = table.remove(tbl, 1)
    end

    if #tbl > 1 then
        local sort_func = self.collates[self.collate].sort_func
        table.sort(tbl, function(a, b)
            if a.is_file and b.is_file then
                return sort_func(a, b)
            elseif a.is_folder and b.is_folder then
                return ffiUtil.strcoll(a.text, b.text)
            else -- folders first
                return a.is_folder
            end
        end)
    end

    if self.choose_folder_callback then
        table.insert(tbl, 1, folder_mode_item or {
            is_folder_long_press = true,
            text = _("Long-press here to choose current folder"),
            bold = true,
            url = url,
        })
    end
end

function CloudStorage:decorateReadState(item, is_read)
    if item.read_state_mandatory == nil then
        -- false is a sentinel for rows without a file-size label.
        item.read_state_mandatory = item.mandatory or false
    end
    item.is_read = is_read == true and true or nil
    local original_mandatory = item.read_state_mandatory ~= false
        and item.read_state_mandatory or nil
    if item.is_read then
        item.mandatory = original_mandatory
            and T(_("✓ Read · %1"), original_mandatory) or _("✓ Read")
        item.mandatory_dim = true
    else
        item.mandatory = original_mandatory
        item.mandatory_dim = nil
    end
end

function CloudStorage:applyReadStates(tbl, server)
    if not server or server.type ~= "webdav" or not server.id then return end
    local RemoteDocument = require("document/remotedocument")
    local ok, states = pcall(RemoteDocument.getReadStates, server.id)
    if not ok then
        logger.warn("CloudStorage: could not load WebDAV read states:", states)
        return
    end
    for _, item in ipairs(tbl) do
        if item.is_file then
            self:decorateReadState(item,
                states[RemoteDocument.normalizePath(item.url)] == true)
        end
    end
end

function CloudStorage:show()
    local default_server_idx = self.initial_server_idx
        or self.settings:readSetting("default_server")
    self.initial_server_idx = nil
    if default_server_idx then
        local server = self.servers[default_server_idx]
        if not server or not self.providers[server.type] then
            default_server_idx = nil
        end
    end
    if default_server_idx then -- open default server
        self.server_idx = default_server_idx
        local url = self.servers[default_server_idx].url
        table.insert(self.paths, { url = url })
        self:openCloudServer(url, true)
    else -- show root list of servers
        UIManager:show(self)
    end
end

function CloudStorage:openCloudServer(url, do_show)
    if self.caller_choose_folder_callback then
        self.choose_folder_callback = true
    end
    local server = self:initServer(self.server_idx)
    url = url or server.url
    self.provider.run(function()
        local tbl = self.provider.listFolder(url, true) -- including folders
        if tbl then
            self:applyReadStates(tbl, server)
            if self.remote_selected_files then
                for _, item in ipairs(tbl) do
                    if self.remote_selected_files[item.url] then
                        item.dim = true
                        self.remote_selected_files[item.url] = item
                    end
                end
            else
                self:setTitleBarLeftIcon("appbar.menu")
            end
            self:sortItemTable(tbl, url)
            self:switchItemTable(server.name, tbl, nil, nil, url == "" and "/" or url)
            if do_show then
                UIManager:show(self)
            end
        else
            table.remove(self.paths)
            self.choose_folder_callback = nil
            if do_show then
                -- could not show the server content; show the root list of servers
                -- "flashui" is needed when called with wi-fi off (NetworkMgr:willRerunWhenConnected())
                UIManager:show(self, "flashui")
            end
            UIManager:show(InfoMessage:new{
                text = T(_("Server: %1"), server.name) .. "\n" ..
                    _("Could not fetch server's content.\nPlease check your configuration or network connection."),
            })
        end
    end)
end

function CloudStorage:setItemReadState(item, is_read)
    local server = self.servers and self.servers[self.server_idx]
    if not server or server.type ~= "webdav" or not server.id then
        UIManager:show(InfoMessage:new{ text = _("Could not identify this WebDAV server.") })
        return
    end

    local RemoteDocument = require("document/remotedocument")
    local ok, err = pcall(RemoteDocument.setReadState, server.id, item.url, is_read)
    if not ok then
        UIManager:show(InfoMessage:new{
            text = T(_("Could not update read status:\n%1"), tostring(err)),
        })
        return
    end

    self:decorateReadState(item, is_read)

    -- Cloud storage may be opened over ReaderUI. Keep the active sidecar
    -- status in lockstep so a later reader save cannot undo a manual choice.
    if self:isActiveRemoteItem(item) then
        local ui = self._manager and self._manager.ui
        if ui and ui.doc_settings then
            local summary = ui.doc_settings:readSetting("summary", {})
            summary.status = is_read and "complete" or "reading"
            summary.modified = os.date("%Y-%m-%d", os.time())
            BookList.setBookInfoCacheProperty(ui.document.file, "status", summary.status)
        end
    end

    self:updateItems(item.idx or 1, true)
    UIManager:show(InfoMessage:new{
        text = is_read and T(_("Marked as read:\n%1"), item.text)
            or T(_("Marked as unread:\n%1"), item.text),
        timeout = 2,
    })
    return true
end

function CloudStorage:onReturn()
    if #self.paths > 0 then
        table.remove(self.paths)
        local path = self.paths[#self.paths]
        if path then
            self:openCloudServer(path.url)
        else -- return to root list
            self:init(true)
        end
    end
    return true
end

function CloudStorage:onHoldReturn()
    if #self.paths > 1 then -- return to the server start folder
        local path = self.paths[1]
        if path then
            for i = #self.paths, 2, -1 do
                table.remove(self.paths)
            end
            self:openCloudServer(path.url)
        end
    end
    return true
end

function CloudStorage:onMenuSelect(item)
    if item.server_idx then -- root list
        table.insert(self.paths, { url = item.url })
        self.item_idx = item.idx
        self.server_idx = item.server_idx
        self:openCloudServer()
    elseif item.is_folder then
        table.insert(self.paths, { url = item.url })
        self:openCloudServer(item.url)
    elseif item.is_file and not self.choose_folder_callback then
        if self.remote_selected_files then
            item.dim = not item.dim and true or nil
            self.remote_selected_files[item.url] = item.dim and item or nil
            self:updateItems(1, true)
        else
            local suffix = (item.suffix or util.getFileNameSuffix(item.text) or ""):lower()
            if self.provider.type == "webdav" and (suffix == "cbz" or suffix == "cbr") then
                self:startStreaming(item)
            else
                UIManager:show(InfoMessage:new{
                    text = _("Only CBZ and CBR books can be streamed from WebDAV."),
                })
            end
        end
    end
    return true
end

function CloudStorage:startStreaming(item)
    self.provider.run(function()
        local probing = InfoMessage:new{ text = _("Checking byte-range streaming support…"), timeout = 0 }
        UIManager:show(probing)
        UIManager:forceRePaint()
        local probe, err = self.provider.probeRange(item.url, item.filesize)
        UIManager:close(probing)
        if not probe then
            UIManager:show(InfoMessage:new{ text = err })
            return
        end

        local server = self.servers[self.server_idx]
        local RemoteDocument = require("document/remotedocument")
        if RemoteDocument.ensureServerId(server) then
            self.settings:saveSetting("cs_servers", self.servers)
        end
        -- The descriptor is reopened outside the cloud-storage plugin, so its
        -- server UUID must be durable before ReaderUI is started.
        self.settings:flush()
        local suffix = (item.suffix or util.getFileNameSuffix(item.text) or ""):lower()
        -- Validators returned by PROPFIND may describe the WebDAV resource,
        -- while the ranged GET is served by a redirecting CDN with different
        -- validator semantics. Only persist validators observed through the
        -- actual ranged GET probe; otherwise a catalog ETag can make every
        -- subsequent range request fail (or trigger a full 200 response).
        local validator_etag, validator_last_modified = RemoteDocument.getProbeValidators(probe)
        local function openRemoteBook()
            local ok, descriptor_path = pcall(RemoteDocument.create, {
                provider = "webdav",
                server_id = server.id,
                remote_path = item.url,
                display_name = item.text,
                size = probe.content_length,
                etag = validator_etag,
                last_modified = validator_last_modified,
                extension = suffix,
            })
            if not ok then
                UIManager:show(InfoMessage:new{ text = RemoteDocument.userError(descriptor_path) })
                return
            end
            local ok_source, source = pcall(RemoteDocument.resolve, descriptor_path)
            if not ok_source or not source then
                UIManager:show(InfoMessage:new{ text = RemoteDocument.userError(source) })
                return
            end
            self:onCloseAllMenus()
            require("apps/reader/readerui"):showReader(descriptor_path, nil, nil, nil, nil, source)
        end
        openRemoteBook()
    end)
end

function CloudStorage:onMenuHold(item)
    if self.choose_folder_callback then
        if item.is_folder or item.is_folder_long_press then
            self:showFolderChooseDialog(item)
        end
    else
        if item.server_idx then -- root list
            self:showServerDialog(item)
        elseif item.is_file then
            if self.remote_selected_files then
                self:showSelectModeDialog()
            else
                self:showFileDialog(item)
            end
        elseif item.is_folder then
            self:showFolderDialog(item)
        end
    end
    return true
end

function CloudStorage:isActiveRemoteItem(item)
    local ui = self._manager and self._manager.ui
    local document = ui and ui.document
    local source = document and document.is_remote and document.remote_source
    local server = self.servers and self.servers[self.server_idx]
    if not source or type(source.remote_path) ~= "string"
            or not server or source.server_id ~= server.id then
        return false
    end

    local RemoteDocument = require("document/remotedocument")
    local active_path = RemoteDocument.normalizePath(source.remote_path)
    local item_path = RemoteDocument.normalizePath(item.url)
    if not item.is_folder then return active_path == item_path end
    local descendant_prefix = item_path == "/" and "/" or item_path .. "/"
    return active_path == item_path
        or active_path:sub(1, #descendant_prefix) == descendant_prefix
end

function CloudStorage:forgetDeletedItem(item)
    local server = self.servers[self.server_idx]
    if not server or server.type ~= "webdav" or not server.id then return end
    local ok, err = pcall(require("document/remotedocument").forgetRemote,
        server.id, item.url, item.is_folder == true)
    if not ok then
        logger.warn("CloudStorage: could not forget deleted remote-book metadata:", err)
    end
end

function CloudStorage:deleteRemoteItem(item)
    if self:isActiveRemoteItem(item) then
        return nil, _("Close this remote book before deleting it or its parent folder.")
    end
    local delete_item = self.provider.deleteItem or self.provider.deleteFile
    if not delete_item then return nil, _("Deletion is not supported by this server.") end
    local ok, err, already_absent = delete_item(item.url, item.is_folder == true, item.dav_url)
    -- A 404/410 reaches the requested server state, but may be an
    -- authentication-concealing response. Refresh the listing without
    -- irreversibly purging local reading metadata in that case.
    if ok and not already_absent then self:forgetDeletedItem(item) end
    return ok, err, already_absent
end

function CloudStorage:deleteItem(item)
    if self:isActiveRemoteItem(item) then
        UIManager:show(InfoMessage:new{
            text = _("Close this remote book before deleting it or its parent folder."),
        })
        return
    end
    local current_path = self.paths[#self.paths] and self.paths[#self.paths].url
    self.provider.run(function()
        local ok, err, already_absent = self:deleteRemoteItem(item)
        if ok then
            if current_path then self:openCloudServer(current_path) end
            UIManager:show(InfoMessage:new{
                text = already_absent
                    and T(_("Already absent from WebDAV:\n%1"), item.text)
                    or T(_("Deleted:\n%1"), item.text),
                timeout = 2,
            })
        else
            local text = T(_("Could not delete item:\n%1"), item.text)
            if err and err ~= "" then text = text .. "\n" .. tostring(err) end
            UIManager:show(InfoMessage:new{ text = text })
        end
    end)
end

function CloudStorage:showFolderChooseDialog(item)
    local url = item.url == "" and "/" or item.url
    local folder_dialog
    folder_dialog = ButtonDialog:new{
        title = _("Choose this folder?") .. "\n\n" .. BD.dirpath(url) .. "\n",
        buttons = {
            {
                {
                    text = _("Cancel"),
                    callback = function()
                        UIManager:close(folder_dialog)
                    end,
                },
                {
                    text = _("Choose"),
                    callback = function()
                        UIManager:close(folder_dialog)
                        if self.caller_choose_folder_callback then
                            self:onClose()
                            local server = self.servers[self.server_idx]
                            self.caller_choose_folder_callback({
                                name     = server.name,
                                type     = server.type,
                                address  = server.address,
                                username = server.username,
                                password = server.password,
                                url      = item.url,
                            })
                        else
                            self.choose_folder_callback(item.url)
                            self:init(true)
                        end
                    end,
                },
            },
        },
    }
    UIManager:show(folder_dialog)
end

function CloudStorage:showFileDialog(item)
    local file_dialog
    file_dialog = ButtonDialog:new{
        title = item.text,
        title_align = "center",
        buttons = {
            {
                {
                    text = item.is_read and _("Mark as unread") or _("Mark as read"),
                    callback = function()
                        UIManager:close(file_dialog)
                        self:setItemReadState(item, not item.is_read)
                    end,
                },
            },
            {
                {
                    text = _("Delete"),
                    enabled = self.provider.deleteFile and true or false,
                    callback = function()
                        UIManager:close(file_dialog)
                        UIManager:show(ConfirmBox:new{
                            text = _("Delete this file?") .. "\n\n" .. item.text,
                            ok_text = _("Delete"),
                            ok_callback = function()
                                self:deleteItem(item)
                            end,
                        })
                    end,
                },
                {
                    text = _("Select"),
                    callback = function()
                        UIManager:close(file_dialog)
                        self:toggleSelectMode() -- turn on
                        self.remote_selected_files[item.url] = item
                        self.item_table[item.idx].dim = true
                        self:updateItems(1, true)
                    end,
                },
            },
        },
    }
    UIManager:show(file_dialog)
end

function CloudStorage:showFolderDialog(item)
    local folder_dialog
    folder_dialog = ButtonDialog:new{
        title = item.text,
        title_align = "center",
        buttons = {
            {
                {
                    text = _("Delete folder"),
                    enabled = (self.provider.deleteItem or self.provider.deleteFile) and true or false,
                    callback = function()
                        UIManager:close(folder_dialog)
                        UIManager:show(ConfirmBox:new{
                            text = _("Delete this folder and all of its contents?") .. "\n\n" .. item.text,
                            ok_text = _("Delete"),
                            ok_callback = function()
                                self:deleteItem(item)
                            end,
                        })
                    end,
                },
            },
        },
    }
    UIManager:show(folder_dialog)
end

function CloudStorage:showSelectModeDialog()
    local select_count = util.tableSize(self.remote_selected_files)
    local actions_enabled = select_count > 0
    local select_dialog
    select_dialog = ButtonDialog:new{
        title = actions_enabled and T(N_("1 file selected", "%1 files selected", select_count), select_count)
            or _("No files selected"),
        title_align = "center",
        buttons = {
            {
                {
                    text = _("Delete"),
                    enabled = actions_enabled and self.provider.deleteFile and true or false,
                    callback = function()
                        UIManager:close(select_dialog)
                        self:showSelectedFilesDeleteDialog()
                    end,
                },
            },
            {}, -- separator
            {
                {
                    text = _("Deselect all"),
                    enabled = actions_enabled,
                    callback = function()
                        UIManager:close(select_dialog)
                        for url in pairs (self.remote_selected_files) do
                            self.remote_selected_files[url] = nil
                        end
                        for _, item in ipairs(self.item_table) do
                            item.dim = nil
                        end
                        self:updateItems(1, true)
                    end,
                },
                {
                    text = _("Select all files in folder"),
                    callback = function()
                        UIManager:close(select_dialog)
                        for _, item in ipairs(self.item_table) do
                            if item.is_file then
                                item.dim = true
                                self.remote_selected_files[item.url] = item
                            end
                        end
                        self:updateItems(1, true)
                    end,
                },
            },
            {
                {
                    text = _("Exit select mode"),
                    callback = function()
                        UIManager:close(select_dialog)
                        self:toggleSelectMode()
                    end,
                },
            },
        },
    }
    UIManager:show(select_dialog)
end

function CloudStorage:toggleSelectMode()
    if self.remote_selected_files then
        for _, item in ipairs(self.item_table) do
            item.dim = nil
        end
        self:updateItems(1, true)
        self:setTitleBarLeftIcon("appbar.menu")
        self.remote_selected_files = nil
    else
        self:setTitleBarLeftIcon("check")
        self.remote_selected_files = {}
    end
end

function CloudStorage:showServerDialog(item)
    local is_not_default_server = item.server_idx ~= self.settings:readSetting("default_server")
    local provider = self.providers[item.type]
    local server_dialog
    local buttons = {
        {
            {
                text = is_not_default_server and _("Set default") or _("Reset default"),
                callback = function()
                    UIManager:close(server_dialog)
                    local idx = is_not_default_server and item.server_idx or nil
                    self.settings:saveSetting("default_server", idx)
                    self._manager.updated = true
                    self:init(true)
                end,
            },
        },
        {
            {
                text = _("Remove server"),
                callback = function()
                    UIManager:show(ConfirmBox:new{
                        text = _("Remove this server?") .. "\n\n" .. item.text,
                        ok_text = _("Remove"),
                        ok_callback = function()
                            UIManager:close(server_dialog)
                            table.remove(self.servers, item.server_idx)
                            local default_server_idx = self.settings:readSetting("default_server")
                            if default_server_idx then
                                if default_server_idx == item.server_idx then
                                    self.settings:delSetting("default_server")
                                elseif default_server_idx > item.server_idx then
                                    self.settings:saveSetting("default_server", default_server_idx - 1)
                                end
                            end
                            self._manager.updated = true
                            self:init(true)
                        end,
                    })
                end,
            },
            {
                text = _("Server settings"),
                callback = function()
                    UIManager:close(server_dialog)
                    local update_callback = function()
                        self._manager.updated = true
                        self.item_table[item.idx] = self:genItemFromServer(item.server_idx)
                        self:updateItems(1, true)
                    end
                    provider.config(item.server_idx, update_callback)
                end,
            },
        },
    }
    server_dialog = ButtonDialog:new{
        title = item.text,
        title_align = "center",
        buttons = buttons,
    }
    UIManager:show(server_dialog)
end

function CloudStorage:showPlusRootDialog()
    local plus_root_dialog
    local buttons = {}
    for _, provider in pairs(self.providers) do
        table.insert(buttons, {
            {
                text = provider.name, -- add new storage
                callback = function()
                    UIManager:close(plus_root_dialog)
                    local update_callback = function(new_server)
                        self._manager.updated = true
                        local max_order = #self.servers
                        for _, item in ipairs(self.servers) do
                            if item.order and max_order < item.order then
                                max_order = item.order
                            end
                        end
                        new_server.order = max_order + 1
                        local next_idx = #self.servers + 1
                        self.servers[next_idx] = new_server
                        self.item_table[next_idx] = self:genItemFromServer(next_idx)
                        self:switchItemTable(nil, self.item_table, next_idx)
                    end
                    provider.config(nil, update_callback)
                end,
            },
        })
    end
    if #buttons > 1 then
        table.sort(buttons, function(a, b) return ffiUtil.strcoll(a[1].text, b[1].text) end)
    end
    table.insert(buttons, {}) -- separator
    table.insert(buttons, {
        {
            text = _("Arrange servers"),
            enabled = #self.item_table > 1,
            callback = function()
                UIManager:close(plus_root_dialog)
                local sort_widget
                sort_widget = SortWidget:new{
                    title = _("Arrange servers"),
                    item_table = self.item_table,
                    callback = function()
                        self._manager.updated = true
                        for i, item in ipairs(sort_widget.item_table) do
                            self.servers[item.server_idx].order = i
                        end
                        self:init(true)
                    end,
                }
                UIManager:show(sort_widget)
            end,
        },
    })
    plus_root_dialog = ButtonDialog:new{
        title = _("Add new server"),
        title_align = "center",
        buttons = buttons,
    }
    UIManager:show(plus_root_dialog)
end

function CloudStorage:showStreamingSettingsDialog()
    local dialog
    local function reopen()
        UIManager:close(dialog)
        self:showStreamingSettingsDialog()
    end
    local function save(key, value)
        self.settings:saveSetting(key, value)
        self._manager.updated = true
    end
    local cache_mb = self.settings:readSetting("webdav_stream_cache_mb", 32)
    local lookahead = self.settings:readSetting("webdav_stream_lookahead", 0)
    local lookahead_label = lookahead == 0 and _("Off (lower power)") or tostring(lookahead)
    local retain = self.settings:nilOrTrue("webdav_stream_retain_progress")
    dialog = ButtonDialog:new{
        title = _("WebDAV comic streaming"),
        title_align = "center",
        buttons = {
            {
                {
                    text = T(_("RAM block cache: %1 MB"), cache_mb),
                    callback = function()
                        UIManager:show(ButtonSelector:new{
                            current_value = cache_mb,
                            values = {
                                { "8 MB", 8 }, { "16 MB", 16 },
                                { "32 MB", 32 }, { "64 MB", 64 },
                            },
                            callback = function(value)
                                save("webdav_stream_cache_mb", value)
                                reopen()
                            end,
                        })
                    end,
                },
            },
            {
                {
                    text = T(_("Page lookahead: %1"), lookahead_label),
                    callback = function()
                        UIManager:show(ButtonSelector:new{
                            current_value = lookahead,
                            values = {
                                { _("Off"), 0 }, { "1", 1 }, { "2", 2 },
                            },
                            callback = function(value)
                                save("webdav_stream_lookahead", value)
                                reopen()
                            end,
                        })
                    end,
                },
            },
            {
                {
                    text = _("Disable Wi-Fi when inactive"),
                    checked_func = function() return G_reader_settings:isTrue("auto_disable_wifi") end,
                    callback = function()
                        G_reader_settings:saveSetting("auto_disable_wifi",
                            not G_reader_settings:isTrue("auto_disable_wifi"))
                        -- Match KOReader's network power-save control: the
                        -- listener applies this when the UI restarts.
                        UIManager:askForRestart()
                    end,
                },
            },
            {
                {
                    text = _("Strict CBR streaming"),
                    checked_func = function() return self.settings:nilOrTrue("webdav_stream_strict") end,
                    callback = function()
                        save("webdav_stream_strict", not self.settings:nilOrTrue("webdav_stream_strict"))
                        reopen()
                    end,
                },
            },
            {
                {
                    text = retain and _("After closing: retain progress") or _("After closing: forget book"),
                    callback = function()
                        save("webdav_stream_retain_progress", not retain)
                        reopen()
                    end,
                },
            },
            {
                {
                    text = _("Show per-book network statistics"),
                    checked_func = function() return self.settings:isTrue("webdav_stream_show_stats") end,
                    callback = function()
                        save("webdav_stream_show_stats", not self.settings:isTrue("webdav_stream_show_stats"))
                        reopen()
                    end,
                },
            },
            {
                {
                    text = _("Close"),
                    callback = function() UIManager:close(dialog) end,
                },
            },
        },
    }
    UIManager:show(dialog)
end

function CloudStorage:showPlusCloudDialog()
    local plus_cloud_dialog
    plus_cloud_dialog = ButtonDialog:new{
        buttons = {
            {
                {
                    text = _("Streaming settings"),
                    enabled = self.provider.type == "webdav",
                    callback = function()
                        UIManager:close(plus_cloud_dialog)
                        self:showStreamingSettingsDialog()
                    end,
                },
            },
            {}, -- separator
            {
                {
                    text = T(_("Sort by: %1"), self.collates[self.collate].text),
                    callback = function()
                        UIManager:show(ButtonSelector:new{
                            width_factor = 0.5,
                            current_value = self.collate,
                            values = {
                                { self.collates["strcoll"].text, "strcoll" },
                                { self.collates["natural"].text, "natural" },
                                { self.collates["type"].text, "type" },
                                { self.collates["size"].text, "size" },
                                { self.collates["date"].text, "date" },
                            },
                            callback = function(value)
                                UIManager:close(plus_cloud_dialog)
                                if self.collate ~= value then
                                    self.collate = value
                                    self.servers[self.server_idx].collate = value ~= "strcoll" and value or nil
                                    self._manager.updated = true
                                    self:sortItemTable()
                                    self:updateItems(1, true)
                                end
                            end,
                        })
                    end,
                },
            },
            {
                {
                    text = _("Return to server list"),
                    callback = function()
                        UIManager:close(plus_cloud_dialog)
                        self:init(true)
                    end,
                },
            },
        },
    }
    UIManager:show(plus_cloud_dialog)
end

function CloudStorage:showSelectedFilesDeleteDialog()
    local files = self.remote_selected_files
    local files_nb = util.tableSize(files)
    UIManager:show(ConfirmBox:new{
        text = T(N_("Delete 1 file?", "Delete %1 files?", files_nb), files_nb),
        ok_text = _("Delete"),
        ok_callback = function()
            self.provider.run(function()
                local Trapper = require("ui/trapper")
                Trapper:wrap(function()
                    Trapper:setPausedText("Deleting paused.\nDo you want to continue or abort deleting files?")
                    local proccessed_files, success_files, unsuccess_files = 0, 0, 0
                    for file, selected_item in pairs(files) do
                        proccessed_files = proccessed_files + 1
                        local text = string.format("Deleting file (%d/%d):\n%s", proccessed_files, files_nb, file:gsub(".*/", ""))
                        if not Trapper:info(text) then
                            break
                        end
                        local deletion_item = type(selected_item) == "table" and selected_item or {
                            is_file = true,
                            text = file:gsub(".*/", ""),
                            url = file,
                        }
                        local ok = self:deleteRemoteItem(deletion_item)
                        if ok then
                            files[file] = nil
                            success_files = success_files + 1
                        else
                            unsuccess_files = unsuccess_files + 1
                        end
                    end
                    Trapper:clear()
                    if success_files > 0 then
                        if not next(files) then
                            self:toggleSelectMode() -- turn off
                        end
                        self:openCloudServer(self.paths[#self.paths].url)
                    end
                    local text = T(N_("Deleted 1 file.", "Deleted %1 files.", success_files), success_files)
                    if unsuccess_files > 0 then
                        text = text .. "\n" ..
                            T(N_("Could not delete 1 file.", "Could not delete %1 files.", unsuccess_files), unsuccess_files)
                    end
                    UIManager:show(InfoMessage:new{ text = text })
                end)
            end)
        end,
    })
end

return CloudStorage
