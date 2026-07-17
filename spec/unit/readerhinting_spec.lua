describe("Reader hinting power cleanup", function()
    local CanvasContext
    local ReaderHinting

    setup(function()
        require("commonrequire")
        CanvasContext = require("document/canvascontext")
        ReaderHinting = require("apps/reader/modules/readerhinting")
    end)

    local function newHinting(lookahead, hint_page)
        return ReaderHinting:new{
            document = {
                remote_source = { lookahead = lookahead },
                info = { number_of_pages = 3 },
                hintPage = hint_page,
            },
            view = {
                hinting = true,
                state = { page = 1, rotation = 0, gamma = 1, saturation = 1 },
            },
            zoom = { getZoom = function() return 1 end },
        }
    end

    it("does no speculative work when remote lookahead is off", function()
        local hinting = newHinting(0, function()
            error("lookahead is disabled")
        end)

        assert.is_true(hinting:onHintPage())
    end)

    it("restores one CPU core when hinted rendering fails", function()
        local original_enable_cpu_cores = CanvasContext.enableCPUCores
        local calls = {}
        CanvasContext.enableCPUCores = function(_, amount)
            table.insert(calls, amount)
        end
        local hinting = newHinting(1, function()
            CanvasContext:enableCPUCores(2)
            error("remote read failed")
        end)

        local ok, err = pcall(hinting.onHintPage, hinting)
        CanvasContext.enableCPUCores = original_enable_cpu_cores

        assert.is_false(ok)
        assert.is_truthy(tostring(err):find("remote read failed", 1, true))
        assert.same({ 2, 1 }, calls)
    end)
end)
