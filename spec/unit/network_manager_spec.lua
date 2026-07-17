describe("network_manager module", function()
    local Device
    local turn_on_wifi_called
    local turn_off_wifi_called
    local obtain_ip_called
    local release_ip_called

    local function clearState()
        G_reader_settings:saveSetting("auto_restore_wifi", true)
        turn_on_wifi_called = 0
        turn_off_wifi_called = 0
        obtain_ip_called = 0
        release_ip_called = 0
    end

    setup(function()
        require("commonrequire")
        Device = require("device")
        function Device:initNetworkManager(NetworkMgr)
            function NetworkMgr:turnOnWifi(callback)
                turn_on_wifi_called = turn_on_wifi_called + 1
                if callback then
                    callback()
                end
            end
            function NetworkMgr:turnOffWifi(callback)
                turn_off_wifi_called = turn_off_wifi_called + 1
                if callback then
                    callback()
                end
            end
            function NetworkMgr:obtainIP(callback)
                obtain_ip_called = obtain_ip_called + 1
                if callback then
                    callback()
                end
            end
            function NetworkMgr:releaseIP(callback)
                release_ip_called = release_ip_called + 1
                if callback then
                    callback()
                end
            end
            function NetworkMgr:restoreWifiAsync()
                self:turnOnWifi()
                self:obtainIP()
            end
        end
        function Device:hasWifiRestore()
            return true
        end
    end)

    it("should restore wifi in init if wifi was on", function()
        package.loaded["ui/network/manager"] = nil
        clearState()
        G_reader_settings:saveSetting("wifi_was_on", true)
        local network_manager = require("ui/network/manager") --luacheck: ignore
        assert.is.same(turn_on_wifi_called, 1)
        assert.is.same(turn_off_wifi_called, 0)
        assert.is.same(obtain_ip_called, 1)
        assert.is.same(release_ip_called, 0)
    end)

    it("should not restore wifi in init if wifi was off", function()
        package.loaded["ui/network/manager"] = nil
        clearState()
        G_reader_settings:saveSetting("wifi_was_on", false)
        local network_manager = require("ui/network/manager") --luacheck: ignore
        assert.is.same(turn_on_wifi_called, 0)
        assert.is.same(turn_off_wifi_called, 0)
        assert.is.same(obtain_ip_called, 0)
        assert.is.same(release_ip_called, 0)
    end)

    teardown(function()
        function Device:initNetworkManager() end
        function Device:hasWifiRestore() return false end
        package.loaded["ui/network/manager"] = nil
    end)
end)

describe("NetworkMgr connectivity polling backoff", function()
    local Device
    local NetworkMgr
    local UIManager

    setup(function()
        require("commonrequire")
        Device = require("device")
        function Device:initNetworkManager(mgr)
            function mgr:turnOnWifi() end
            function mgr:turnOffWifi() end
            function mgr:obtainIP() end
            function mgr:releaseIP() end
        end
        function Device:hasWifiRestore() return false end
    end)

    before_each(function()
        package.loaded["ui/network/manager"] = nil
        G_reader_settings:saveSetting("wifi_was_on", false)
        NetworkMgr = require("ui/network/manager")
        UIManager = require("ui/uimanager")
        stub(UIManager, "scheduleIn")
        stub(NetworkMgr, "queryNetworkState")
        NetworkMgr.queryNetworkState.invokes(function(self)
            self.is_wifi_on = false
            self.is_connected = false
        end)
        stub(NetworkMgr, "_abortWifiConnection")
    end)

    after_each(function()
        NetworkMgr._abortWifiConnection:revert()
        NetworkMgr.queryNetworkState:revert()
        UIManager.scheduleIn:revert()
        package.loaded["ui/network/manager"] = nil
    end)

    teardown(function()
        function Device:initNetworkManager() end
        function Device:hasWifiRestore() return false end
    end)

    it("backs off failed checks while preserving the 45-second deadline", function()
        local delays = {}
        local tasks = {}
        UIManager.scheduleIn.invokes(function(_, delay, callback, ...)
            local args = { n = select("#", ...), ... }
            table.insert(delays, delay)
            table.insert(tasks, { callback = callback, args = args })
        end)

        NetworkMgr:scheduleConnectivityCheck()
        while #tasks > 0 do
            local task = table.remove(tasks, 1)
            task.callback(unpack(task.args, 1, task.args.n))
        end

        assert.equals(0.25, delays[1])
        assert.equals(0.5, delays[2])
        assert.equals(1, delays[3])
        assert.equals(2, delays[4])
        local elapsed = 0
        for _, delay in ipairs(delays) do
            assert.is_true(delay <= 2)
            elapsed = elapsed + delay
        end
        assert.equals(45, elapsed)
        assert.is_true(#delays < 30)
        assert.stub(NetworkMgr._abortWifiConnection).was.called(1)
    end)
end)

describe("NetworkMgr:hasLeaseForCurrentNetwork", function()
    local NetworkMgr
    local UIManager
    local broadcast_handlers

    setup(function()
        require("commonrequire")
        UIManager = require("ui/uimanager")
        local Device = require("device")
        function Device:initNetworkManager(mgr)
            -- Minimal stubs so manager.lua initialises without errors.
            function mgr:turnOnWifi() end
            function mgr:turnOffWifi() end
            function mgr:obtainIP() end
            function mgr:releaseIP() end
            function mgr:restoreWifiAsync() end
        end
        function Device:hasWifiRestore() return false end
    end)

    before_each(function()
        broadcast_handlers = {}
        stub(UIManager, "broadcastEvent")
        UIManager.broadcastEvent.invokes(function(_, event)
            table.insert(broadcast_handlers, event.handler)
        end)
        package.loaded["ui/network/manager"] = nil
        G_reader_settings:saveSetting("wifi_was_on", false)
        NetworkMgr = require("ui/network/manager")
    end)

    after_each(function()
        package.loaded["ui/network/manager"] = nil
        UIManager.broadcastEvent:revert()
    end)

    it("returns false when not connected", function()
        -- Override isConnected so we don't need a real interface.
        function NetworkMgr:isConnected() return false end
        assert.is_false(NetworkMgr:hasLeaseForCurrentNetwork())
    end)

    it("returns true when backend cannot report an SSID (non-wpa_supplicant platforms)", function()
        function NetworkMgr:isConnected() return true end
        -- getCurrentNetwork() is a no-op stub that returns nil on non-Kobo builds.
        function NetworkMgr:getCurrentNetwork() return nil end
        assert.is_true(NetworkMgr:hasLeaseForCurrentNetwork())
    end)

    it("returns true when connected and lease matches the current SSID (no churn)", function()
        function NetworkMgr:isConnected() return true end
        function NetworkMgr:getCurrentNetwork() return {ssid = "HomeNet"} end
        NetworkMgr.lease_ssid = "HomeNet"
        assert.is_true(NetworkMgr:hasLeaseForCurrentNetwork())
    end)

    it("returns false when lease_ssid differs from current SSID (stale lease)", function()
        function NetworkMgr:isConnected() return true end
        function NetworkMgr:getCurrentNetwork() return {ssid = "OfficeNet"} end
        NetworkMgr.lease_ssid = "HomeNet"   -- still holds the lease from the old network
        assert.is_false(NetworkMgr:hasLeaseForCurrentNetwork())
    end)

    it("returns false when lease_ssid is nil even though a SSID is reported", function()
        function NetworkMgr:isConnected() return true end
        function NetworkMgr:getCurrentNetwork() return {ssid = "SomeNet"} end
        NetworkMgr.lease_ssid = nil
        assert.is_false(NetworkMgr:hasLeaseForCurrentNetwork())
    end)

    it("reference-counts active remote-document network leases", function()
        assert.is_false(NetworkMgr:hasNetworkLease())
        NetworkMgr:acquireNetworkLease("remote-document")
        NetworkMgr:acquireNetworkLease("remote-document")
        assert.is_true(NetworkMgr:hasNetworkLease())
        NetworkMgr:releaseNetworkLease("remote-document")
        assert.is_true(NetworkMgr:hasNetworkLease())
        assert.equals(0, #broadcast_handlers)
        NetworkMgr:releaseNetworkLease("remote-document")
        assert.is_false(NetworkMgr:hasNetworkLease())
        assert.same({ "onNetworkLeaseReleased" }, broadcast_handlers)
    end)

    it("tracks independent lease owners and tolerates an unknown release", function()
        NetworkMgr:acquireNetworkLease("remote-document")
        NetworkMgr:acquireNetworkLease("sync")
        NetworkMgr:releaseNetworkLease("missing")
        assert.is_true(NetworkMgr:hasNetworkLease())
        assert.equals(0, #broadcast_handlers)
        NetworkMgr:releaseNetworkLease("remote-document")
        assert.is_true(NetworkMgr:hasNetworkLease())
        assert.equals(0, #broadcast_handlers)
        NetworkMgr:releaseNetworkLease("sync")
        assert.is_false(NetworkMgr:hasNetworkLease())
        assert.same({ "onNetworkLeaseReleased" }, broadcast_handlers)
    end)

    it("persists an explicit inactive-Wi-Fi opt-out", function()
        local had_setting = G_reader_settings:has("auto_disable_wifi")
        local original_setting = G_reader_settings:readSetting("auto_disable_wifi")
        local original_ask_for_restart = UIManager.askForRestart
        local restart_requested
        UIManager.askForRestart = function() restart_requested = true end
        G_reader_settings:makeTrue("auto_disable_wifi")

        local ok, err = pcall(function()
            NetworkMgr:getPowersaveMenuTable().callback()
            assert.is_true(restart_requested)
            assert.is_true(G_reader_settings:isFalse("auto_disable_wifi"))
        end)

        UIManager.askForRestart = original_ask_for_restart
        if had_setting then
            G_reader_settings:saveSetting("auto_disable_wifi", original_setting)
        else
            G_reader_settings:delSetting("auto_disable_wifi")
        end
        assert.is_true(ok, err)
    end)

    teardown(function()
        local Device = require("device")
        function Device:initNetworkManager() end
        function Device:hasWifiRestore() return false end
        package.loaded["ui/network/manager"] = nil
    end)
end)
