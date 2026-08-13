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

print("Burrow updater path regression tests passed")
