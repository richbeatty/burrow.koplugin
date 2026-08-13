local Updater = require("burrow_updater_prepare_fix")

local function cleanError(err)
    return tostring(err or "unknown error"):gsub("^.-:%d+:%s*", "")
end

-- This is the final updater entrypoint. Resolve _prepareRelease at call time so
-- later preparation implementations cannot be bypassed by a cached function
-- reference from an earlier compatibility layer.
function Updater:_performUpdate(release)
    local prepared, prepare_err = pcall(self._prepareRelease, self, release)
    if not prepared then
        error("Preparation failed: " .. cleanError(prepare_err), 0)
    end

    local installed, install_err = pcall(self._swapInPreparedRelease, self, release)
    if not installed then
        error("Installation failed: " .. cleanError(install_err), 0)
    end
end

Updater._burrow_dynamic_prepare_dispatch = true

return Updater
