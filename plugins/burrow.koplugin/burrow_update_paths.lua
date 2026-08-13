local Paths = {}

function Paths.normalizeArchivePath(path)
    if type(path) ~= "string" or path == "" then
        return nil, "empty archive path"
    end
    if path:find("\0", 1, true) then
        return nil, "archive path contains NUL"
    end
    if path:find("\\", 1, true) then
        return nil, "archive path contains a backslash"
    end
    if path:sub(1, 1) == "/" or path:match("^%a:") then
        return nil, "archive path is absolute"
    end
    if path:find("//", 1, true) then
        return nil, "archive path contains an empty segment"
    end

    while path:sub(1, 2) == "./" do
        path = path:sub(3)
    end
    path = path:gsub("/+$", "")
    if path == "" then
        return nil, "archive path is empty after normalization"
    end

    for segment in path:gmatch("[^/]+") do
        if segment == "." or segment == ".." then
            return nil, "archive path contains a traversal segment"
        end
    end
    return path
end

function Paths.parent(path)
    if type(path) ~= "string" or path == "" then return nil end
    path = path:gsub("/+$", "")
    if path == "" then return nil end
    local parent = path:match("^(.*)/[^/]+$")
    if parent == "" and path:sub(1, 1) == "/" then
        return "/"
    end
    return parent
end

return Paths
