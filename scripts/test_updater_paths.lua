package.path = "plugins/burrow.koplugin/?.lua;" .. package.path

local Paths = require("burrow_update_paths")

local function expect(input, expected)
    local actual, err = Paths.normalizeArchivePath(input)
    assert(actual == expected, string.format("%q normalized to %q instead of %q (%s)", input, tostring(actual), tostring(expected), tostring(err)))
end

local function reject(input)
    local actual = Paths.normalizeArchivePath(input)
    assert(actual == nil, string.format("unsafe path %q was accepted as %q", input, tostring(actual)))
end

local function read(path)
    local file = assert(io.open(path, "rb"), "could not open " .. path)
    local content = file:read("*a")
    file:close()
    return content
end

expect("plugins/", "plugins")
expect("plugins/burrow.koplugin/", "plugins/burrow.koplugin")
expect("plugins/burrow.koplugin/main.lua", "plugins/burrow.koplugin/main.lua")
expect("./plugins/burrow.koplugin/main.lua", "plugins/burrow.koplugin/main.lua")
expect("././FILES.sha256", "FILES.sha256")

reject("")
reject("/")
reject("/plugins/burrow.koplugin/main.lua")
reject("../plugins/burrow.koplugin/main.lua")
reject("plugins/../burrow.koplugin/main.lua")
reject("plugins/./burrow.koplugin/main.lua")
reject("plugins//burrow.koplugin/main.lua")
reject("plugins\\burrow.koplugin\\main.lua")
reject("C:/plugins/burrow.koplugin/main.lua")
reject("plugins/burrow.koplugin/bad\0name.lua")

assert(Paths.parent("/storage/emulated/0/koreader/ota/burrow-updater/staging/plugins/burrow.koplugin") == "/storage/emulated/0/koreader/ota/burrow-updater/staging/plugins")
assert(Paths.parent("/storage") == "/")

local entry = read("plugins/burrow.koplugin/burrow_updater_entry.lua")
local main = read("plugins/burrow.koplugin/main.lua")
assert(entry:find('require%("burrow_updater_prepare_fix"%)'), "entrypoint must load the corrected preparation module")
assert(entry:find("pcall%(self%._prepareRelease, self, release%)"), "entrypoint must resolve _prepareRelease at call time")
assert(not entry:find("originalPrepare", 1, true), "entrypoint must not cache an older preparation function")
assert(entry:find("_burrow_dynamic_prepare_dispatch", 1, true), "entrypoint must expose the dispatch guard")
assert(main:find('require%("burrow_updater_entry"%)'), "main.lua must load the final updater entrypoint")
assert(main:find("_burrow_dynamic_prepare_dispatch", 1, true), "main.lua must verify the dispatch guard")

print("Burrow updater path and dispatch regression tests passed")
