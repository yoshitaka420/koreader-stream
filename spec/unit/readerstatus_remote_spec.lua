describe("remote ReaderStatus read-state synchronization", function()
    local ReaderStatus
    local RemoteDocument
    local util
    local read_state_path
    local original_read_state
    local original_read_state_backup
    local original_auto_mark
    local original_end_action
    local original_lastfile
    local original_collate

    local server_id = "11111111-2222-4333-8444-555555555555"
    local remote_path = "/Comics/Finished.cbz"

    local function restoreSetting(key, value)
        if value == nil then
            G_reader_settings:delSetting(key)
        else
            G_reader_settings:saveSetting(key, value)
        end
    end

    local function makeStatus(is_remote)
        local summary = { status = "reading" }
        local went_to_beginning = false
        local status = setmetatable({
            document = {
                file = "/tmp/remote-reader-status.cbz",
                is_remote = is_remote,
                remote_source = is_remote and {
                    provider = "webdav",
                    server_id = server_id,
                    remote_path = remote_path,
                } or nil,
            },
            ui = {
                doc_settings = {
                    readSetting = function(_, key)
                        if key == "summary" then return summary end
                    end,
                },
                gotopage = {
                    onGoToBeginning = function()
                        went_to_beginning = true
                    end,
                },
            },
        }, { __index = ReaderStatus })
        return status, summary, function() return went_to_beginning end
    end

    setup(function()
        require("commonrequire")
        ReaderStatus = require("apps/reader/modules/readerstatus")
        RemoteDocument = require("document/remotedocument")
        util = require("util")
        read_state_path = RemoteDocument.getReadStatePath()
        original_read_state = util.readFromFile(read_state_path, "rb")
        original_read_state_backup = util.readFromFile(read_state_path .. ".old", "rb")
        original_auto_mark = G_reader_settings:readSetting("end_document_auto_mark")
        original_end_action = G_reader_settings:readSetting("end_document_action")
        original_lastfile = G_reader_settings:readSetting("lastfile")
        original_collate = G_reader_settings:readSetting("collate")
    end)

    before_each(function()
        os.remove(read_state_path)
        os.remove(read_state_path .. ".old")
        G_reader_settings:saveSetting("end_document_auto_mark", false)
        G_reader_settings:saveSetting("end_document_action", "goto_beginning")
        G_reader_settings:saveSetting("lastfile", "/tmp/not-quickstart.cbz")
        G_reader_settings:saveSetting("collate", "strcoll")
    end)

    teardown(function()
        restoreSetting("end_document_auto_mark", original_auto_mark)
        restoreSetting("end_document_action", original_end_action)
        restoreSetting("lastfile", original_lastfile)
        restoreSetting("collate", original_collate)
        os.remove(read_state_path)
        os.remove(read_state_path .. ".old")
        if original_read_state then
            assert(util.writeToFile(original_read_state, read_state_path, true))
        end
        if original_read_state_backup then
            assert(util.writeToFile(original_read_state_backup, read_state_path .. ".old", true))
        end
    end)

    it("automatically marks a remote book read at the end regardless of the local preference", function()
        local status, summary, went_to_beginning = makeStatus(true)

        status:onEndOfBook()

        assert.equals("complete", summary.status)
        assert.is_true(went_to_beginning())
        RemoteDocument = package.reload("document/remotedocument")
        assert.is_true(RemoteDocument.getReadState(server_id, remote_path))
    end)

    it("does not auto-mark a local book when the preference is disabled", function()
        local status, summary, went_to_beginning = makeStatus(false)

        status:onEndOfBook()

        assert.equals("reading", summary.status)
        assert.is_true(went_to_beginning())
        assert.is_nil(RemoteDocument.getReadState(server_id, remote_path))
    end)

    it("synchronizes manual finished and reading states for a remote book", function()
        local status, summary = makeStatus(true)

        status:markBook()
        assert.equals("complete", summary.status)
        RemoteDocument = package.reload("document/remotedocument")
        assert.is_true(RemoteDocument.getReadState(server_id, remote_path))

        status:markBook()
        assert.equals("reading", summary.status)
        RemoteDocument = package.reload("document/remotedocument")
        assert.is_false(RemoteDocument.getReadState(server_id, remote_path))
    end)

    it("synchronizes changes made through the book-status widget", function()
        local BookStatusWidget = require("ui/widget/bookstatuswidget")
        local UIManager = require("ui/uimanager")
        local status = makeStatus(true)
        local widget_options
        local original_new = BookStatusWidget.new
        local original_show = UIManager.show
        BookStatusWidget.new = function(_, options)
            widget_options = options
            return options
        end
        UIManager.show = function() end
        local ok, err = pcall(function()
            status:onShowBookStatus()
            assert.is_function(widget_options.status_change_callback)
            widget_options.status_change_callback("complete")
            assert.is_true(RemoteDocument.getReadState(server_id, remote_path))
            widget_options.status_change_callback("reading")
            assert.is_false(RemoteDocument.getReadState(server_id, remote_path))
        end)
        BookStatusWidget.new = original_new
        UIManager.show = original_show
        assert.is_true(ok, err)
    end)

    it("does not create WebDAV read state for manual local-book status changes", function()
        local status, summary = makeStatus(false)

        status:markBook()

        assert.equals("complete", summary.status)
        assert.is_nil(RemoteDocument.getReadState(server_id, remote_path))
    end)
end)
