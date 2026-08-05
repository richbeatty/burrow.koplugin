local EventListener = require("ui/widget/eventlistener")
local time = require("ui/time")
local logger = require("logger")

local burrow_debug = EventListener:extend{
    start_time = nil
}

burrow_debug.enabled = false

burrow_debug.logprefix = "Burrow -"

function burrow_debug:init()
    if burrow_debug.enabled then
        self.start_time = time.now()
    end
end

function burrow_debug:report(description)
    if burrow_debug.enabled then
        logger.info(burrow_debug.logprefix, description, string.format("done in %.3f", time.to_ms(time.since(self.start_time))))
    end
end

return burrow_debug