local EventListener = require("ui/widget/eventlistener")
local CanvasContext = require("document/canvascontext")

local DHINTCOUNT = G_defaults:readSetting("DHINTCOUNT")

local ReaderHinting = EventListener:extend{
    hinting_states = nil, -- array
}

function ReaderHinting:init()
    self.hinting_states = {}
end

function ReaderHinting:onHintPage()
    if not self.view.hinting then return true end
    local hint_count = self.document.remote_source and self.document.remote_source.lookahead or DHINTCOUNT
    for i=1, hint_count do
        if self.view.state.page + i <= self.document.info.number_of_pages then
            local ok, err = xpcall(function()
                self.document:hintPage(
                    self.view.state.page + i,
                    self.zoom:getZoom(self.view.state.page + i),
                    self.view.state.rotation,
                    self.view.state.gamma,
                    self.view.state.saturation)
            end, debug.traceback)
            if not ok then
                -- Hinted rendering temporarily enables a second Kobo CPU core.
                -- A remote I/O or decode error used to skip the matching
                -- restore and could leave that core online for the session.
                CanvasContext:enableCPUCores(1)
                error(err, 0)
            end
        end
    end
    return true
end

function ReaderHinting:onSetHinting(hinting)
    self.view.hinting = hinting
end

function ReaderHinting:onDisableHinting()
    table.insert(self.hinting_states, self.view.hinting)
    self.view.hinting = false
    return true
end

function ReaderHinting:onRestoreHinting()
    self.view.hinting = table.remove(self.hinting_states)
    return true
end

return ReaderHinting
