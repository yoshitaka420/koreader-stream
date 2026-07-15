describe("Readerui module", function()
    local DocumentRegistry, ReaderUI, DocSettings, UIManager, Screen
    local sample_epub = "spec/front/unit/data/juliet.epub"
    local readerui
    setup(function()
        require("commonrequire")
        disable_plugins()
        DocumentRegistry = require("document/documentregistry")
        ReaderUI = require("apps/reader/readerui")
        DocSettings = require("docsettings")
        UIManager = require("ui/uimanager")
        Screen = require("device").screen

        readerui = ReaderUI:new{
            dimen = Screen:getSize(),
            document = DocumentRegistry:openDocument(sample_epub),
        }
    end)
    it("should save settings", function()
        -- remove history settings and sidecar settings
        DocSettings:open(sample_epub):purge()
        local doc_settings = DocSettings:open(sample_epub)
        assert.are.same(doc_settings.data, {doc_path = sample_epub})
        readerui:saveSettings()
        assert.are_not.same(readerui.doc_settings.data, {doc_path = sample_epub})
        doc_settings = DocSettings:open(sample_epub)
        assert.truthy(doc_settings.data.last_xpointer)
        assert.are.same(doc_settings.data.last_xpointer,
                readerui.doc_settings.data.last_xpointer)
    end)
    it("should enforce page view for reflowable documents", function()
        assert.are.same(0, readerui.doc_settings:readSetting("copt_view_mode"))
        assert.are.same(0, readerui.document.configurable.view_mode)
        assert.are.same("page", readerui.view.view_mode)
    end)
    it("should replace stale paged-document display settings on every open", function()
        local fake_settings = {
            data = {
                kopt_page_scroll = 1,
                kopt_zoom_mode_genus = 3,
                kopt_zoom_mode_type = 1,
                zoom_mode = "contentwidth",
                normal_zoom_mode = "contentwidth",
                flipping_zoom_mode = "contentwidth",
                flipping_scroll_mode = true,
            },
            saveSetting = function(self, key, value)
                self.data[key] = value
            end,
        }
        ReaderUI.enforceReaderViewDefaults{
            document = { info = { has_pages = true } },
            doc_settings = fake_settings,
        }

        assert.are.same(0, fake_settings.data.kopt_page_scroll)
        assert.are.same(4, fake_settings.data.kopt_zoom_mode_genus)
        assert.are.same(2, fake_settings.data.kopt_zoom_mode_type)
        assert.are.same("page", fake_settings.data.zoom_mode)
        assert.are.same("page", fake_settings.data.normal_zoom_mode)
        assert.are.same("page", fake_settings.data.flipping_zoom_mode)
        assert.is_false(fake_settings.data.flipping_scroll_mode)
    end)
    it("should show reader", function()
        UIManager:quit()
        UIManager:show(readerui)
        UIManager:scheduleIn(1, function()
            UIManager:close(readerui)
            -- We haven't torn it down yet
            ReaderUI.instance = readerui
        end)
        UIManager:run()
    end)
    it("should close document", function()
        readerui:closeDocument()
        assert(readerui.document == nil)
        readerui:onClose()
    end)
    it("should not reset ReaderUI.instance by mistake", function()
        ReaderUI:doShowReader(sample_epub) -- spins up a new, sane instance
        local new_readerui = ReaderUI.instance
        assert.is.truthy(new_readerui.document)
        -- This *will* trip:
        -- * A pair of ReaderUI instance mimsatch warnings (on open/close) because it bypasses the safety of doShowReader!
        -- * A refcount warning from DocumentRegistry, because bypassinf the safeties means that two different instances opened the same Document.
        ReaderUI:new{
            dimen = Screen:getSize(),
            document = DocumentRegistry:openDocument(sample_epub)
        }:onClose()
        assert.is.truthy(new_readerui.document)
        new_readerui:closeDocument()
        new_readerui:onClose()
    end)
    it("should forget remote metadata only after the final dialog flush", function()
        local RemoteDocument = require("document/remotedocument")
        local ReadCollection = require("readcollection")
        local ReadHistory = require("readhistory")
        local events = {}
        local old_close = UIManager.close
        local old_forget = RemoteDocument.forget
        local old_collection_update = ReadCollection.updateLastBookTime
        local old_history_update = ReadHistory.updateLastBookTime

        UIManager.close = function(_, dialog)
            dialog:saveSettings()
        end
        RemoteDocument.forget = function()
            table.insert(events, "forget")
            return true
        end
        ReadCollection.updateLastBookTime = function() end
        ReadHistory.updateLastBookTime = function() end

        local fake_document = {
            file = "/tmp/remote-forget-order.cbz",
            is_remote = true,
            remote_source = { forget_on_close = true },
            getNetworkStats = function() return {} end,
            isEdited = function() return false end,
            close = function() end,
        }
        local fake_reader = ReaderUI:extend{
            document = fake_document,
            highlight = { highlight_write_into_pdf = false },
            handleEvent = function() end,
            saveSettings = function()
                table.insert(events, "flush")
            end,
        }
        fake_reader.dialog = fake_reader

        local ok, err = pcall(ReaderUI.onClose, fake_reader)
        UIManager.close = old_close
        RemoteDocument.forget = old_forget
        ReadCollection.updateLastBookTime = old_collection_update
        ReadHistory.updateLastBookTime = old_history_update

        assert.is_true(ok, err)
        assert.same({ "flush", "forget" }, events)
    end)
end)
