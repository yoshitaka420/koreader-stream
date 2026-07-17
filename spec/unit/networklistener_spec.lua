describe("NetworkListener network lease release", function()
    local Device
    local NetworkListener
    local NetworkMgr
    local UIManager
    local original_auto_disable
    local original_auto_standby
    local scheduled_callback
    local scheduled_delay

    local function restoreSetting(key, value)
        if value == nil then
            G_reader_settings:delSetting(key)
        else
            G_reader_settings:saveSetting(key, value)
        end
    end

    setup(function()
        require("commonrequire")
        Device = require("device")
        NetworkMgr = require("ui/network/manager")
        UIManager = require("ui/uimanager")
        original_auto_disable = G_reader_settings:readSetting("auto_disable_wifi")
        original_auto_standby = G_reader_settings:readSetting("auto_standby_timeout_seconds")
    end)

    before_each(function()
        G_reader_settings:saveSetting("auto_disable_wifi", true)
        G_reader_settings:saveSetting("auto_standby_timeout_seconds", -1)

        stub(Device, "hasWifiToggle")
        Device.hasWifiToggle.returns(true)
        package.loaded["ui/network/networklistener"] = nil
        NetworkListener = require("ui/network/networklistener")

        stub(NetworkMgr, "getWifiState")
        NetworkMgr.getWifiState.returns(true)
        stub(NetworkMgr, "getNetworkInterfaceName")
        NetworkMgr.getNetworkInterfaceName.returns("eth0")
        stub(NetworkListener, "_getTxPackets")
        NetworkListener._getTxPackets.returns(42)
        stub(UIManager, "unschedule")
        stub(UIManager, "scheduleIn")
        UIManager.scheduleIn.invokes(function(_, delay, callback)
            scheduled_delay = delay
            scheduled_callback = callback
        end)

        scheduled_delay = nil
        scheduled_callback = nil
        NetworkListener._activity_check_scheduled = true
        NetworkListener._last_tx_packets = 7
        NetworkListener._activity_check_delay_seconds = 30 * 60
        NetworkListener._released_lease_recheck = nil
    end)

    after_each(function()
        UIManager.scheduleIn:revert()
        UIManager.unschedule:revert()
        NetworkListener._getTxPackets:revert()
        NetworkMgr.getNetworkInterfaceName:revert()
        NetworkMgr.getWifiState:revert()
        Device.hasWifiToggle:revert()
        package.loaded["ui/network/networklistener"] = nil
    end)

    teardown(function()
        restoreSetting("auto_disable_wifi", original_auto_disable)
        restoreSetting("auto_standby_timeout_seconds", original_auto_standby)
    end)

    it("restarts the activity check from a fresh baseline after one minute", function()
        NetworkListener:onNetworkLeaseReleased()

        assert.stub(UIManager.unschedule).was.called_with(
            UIManager, NetworkListener._scheduleActivityCheck)
        assert.equals(42, NetworkListener._last_tx_packets)
        assert.equals(60, NetworkListener._activity_check_delay_seconds)
        assert.equals(60, scheduled_delay)
        assert.equals(NetworkListener._scheduleActivityCheck, scheduled_callback)
        assert.is_true(NetworkListener._activity_check_scheduled)
        assert.is_true(NetworkListener._released_lease_recheck)
    end)

    it("returns to the normal cadence after the one-minute recheck", function()
        NetworkListener:onNetworkLeaseReleased()
        NetworkListener._getTxPackets.returns(100)

        scheduled_callback()

        assert.equals(100, NetworkListener._last_tx_packets)
        assert.equals(5 * 60, NetworkListener._activity_check_delay_seconds)
        assert.equals(5 * 60, scheduled_delay)
        assert.is_nil(NetworkListener._released_lease_recheck)
    end)

    it("does nothing when automatic shutdown cannot apply", function()
        G_reader_settings:saveSetting("auto_disable_wifi", false)
        NetworkListener:onNetworkLeaseReleased()

        NetworkMgr.getWifiState.returns(false)
        G_reader_settings:saveSetting("auto_disable_wifi", true)
        NetworkListener:onNetworkLeaseReleased()

        NetworkMgr.getWifiState.returns(true)
        NetworkMgr.getNetworkInterfaceName.returns(nil)
        NetworkListener:onNetworkLeaseReleased()

        assert.stub(UIManager.unschedule).was.called(0)
        assert.stub(UIManager.scheduleIn).was.called(0)
        assert.equals(7, NetworkListener._last_tx_packets)
        assert.equals(30 * 60, NetworkListener._activity_check_delay_seconds)
        assert.is_true(NetworkListener._activity_check_scheduled)
    end)
end)
