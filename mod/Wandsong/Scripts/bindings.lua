-- Active game bindings are a startup snapshot. Editing Input.ini affects the next launch.
local M = {}
local function read()
    local result = {}
    local f = io.open(require("files").input(), "r")
    if not f then return result end
    for line in f:lines() do
        local kind, body = line:match("^%s*(%a+)Mappings=%((.+)%)")
        if kind == "Action" or kind == "Axis" then
            local id = body:match(kind .. 'Name="([^"]+)"')
            local key = body:match("Key=([%w_]+)")
            if id and key and not key:find("^Gamepad") then
                result[#result + 1] = { id = id, key = key, kind = kind,
                    scale = tonumber(body:match("Scale=([%d%.%-]+)")) or 1 }
            end
        end
    end
    f:close()
    return result
end
local active = read()
local VK = { SpaceBar = 32, LeftShift = 160, RightShift = 161, LeftControl = 162,
    RightControl = 163, LeftAlt = 164, RightAlt = 165, Escape = 27, Tab = 9, Enter = 13,
    BackSpace = 8, Insert = 45, Delete = 46, Home = 36, End = 35, PageUp = 33, PageDown = 34,
    Left = 37, Up = 38, Right = 39, Down = 40, Slash = 191, Period = 190, Comma = 188,
    Semicolon = 186, Apostrophe = 222, Backslash = 220, LeftBracket = 219, RightBracket = 221,
    Hyphen = 189, Equals = 187, Tilde = 192, Zero = 48, One = 49, Two = 50, Three = 51,
    Four = 52, Five = 53, Six = 54, Seven = 55, Eight = 56, Nine = 57 }
function M.virtual_key(key)
    if not key then return nil end
    if key:match("^%u$") then return key:byte() end
    local f = tonumber(key:match("^F(%d+)$"))
    if f and f >= 1 and f <= 24 then return 111 + f end
    return VK[key]
end
function M.key(id, default)
    local found = false
    for _, b in ipairs(active) do
        if b.id == id then
            found = true
            if M.virtual_key(b.key) then return b.key end
        end
    end
    -- An explicitly unbound/mouse-only action must not pretend it has a keyboard key.
    if not found then return default end
end
local SPOKEN = { SpaceBar = "space", Slash = "forward slash", LeftControl = "left control",
    RightControl = "right control", LeftShift = "left shift", RightShift = "right shift",
    Tilde = "grave accent", Hyphen = "minus", Equals = "equals", Backslash = "backslash" }
function M.spoken(id, default)
    local k = M.key(id, default)
    return k and (SPOKEN[k] or k:gsub("(%l)(%u)", "%1 %2"):lower()) or "the key assigned in Controls"
end
--- Words for one of the game's own key names ("LeftShift" -> "left shift").
function M.spoken_key(k)
    return SPOKEN[k] or (k:gsub("(%l)(%u)", "%1 %2"):lower())
end
-- The game's key names that turn up whole inside its texts ("Press LeftShift to sprint.").
M.KEY_NAMES = { LeftShift = true, RightShift = true, LeftControl = true, RightControl = true, LeftAlt = true,
    RightAlt = true, SpaceBar = true, BackSpace = true, PageUp = true, PageDown = true, CapsLock = true,
    LeftMouseButton = true, RightMouseButton = true, MiddleMouseButton = true }
function M.forward()
    for _, b in ipairs(active) do
        if b.id:lower():find("forward", 1, true) and b.scale > 0 and M.virtual_key(b.key) then
            return b.key
        end
    end
    return M.key("AM_MoveForward", "W")
end
function M.movement_vk(vk)
    if type(vk) ~= "number" then return false end
    for _, b in ipairs(active) do
        local id = b.id:lower()
        if b.kind == "Axis" and (id:find("forward", 1, true) or id:find("right", 1, true))
           and M.virtual_key(b.key) == vk then return true end
    end
    return vk == M.virtual_key(M.forward()) or vk == 65 or vk == 83 or vk == 68
end
--- The game action using an Unreal key name, if any, and when: "until restart" when only the
--- bindings in force have it (Input.ini moved it away), "from next start" when only Input.ini
--- has it (moved there this session), nil when both do.
function M.conflict(key, except)
    local now, later
    for _, b in ipairs(active) do if b.key == key and b.id ~= except then now = b.id; break end end
    for _, b in ipairs(read()) do if b.key == key and b.id ~= except then later = b.id; break end end
    if later then return later, (not now) and "from next start" or nil end
    if now then return now, "until restart" end
end
--- Whether a UE4SS key (enum name, "DEL") is an Unreal key (name, "Delete"): compared as the
--- virtual key both stand for.
function M.same_key(enum_name, ue_key)
    local vk = M.virtual_key(ue_key)
    return vk ~= nil and type(Key) == "table" and Key[enum_name] == vk
end
return M
