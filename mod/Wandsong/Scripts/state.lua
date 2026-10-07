-- Shared state between modules: things one module notices that another must respect.
local M = {}

-- Set while the game is loading (a loading screen is up) and for a short while after.
-- Nothing may touch world objects (actors, the player) during a load: they're being torn
-- down and rebuilt, and touching one mid-teardown crashes inside UE4SS.
M.loading_until = -1
M.generation = 0
M.scene = 0
M.cinematic = false
M.paused = false

function M.loading() return os.clock() < M.loading_until end

function M.mark_loading(seconds)
    if not M.loading() then M.generation = M.generation + 1; M.scene = M.scene + 1 end
    M.loading_until = math.max(M.loading_until, os.clock() + (seconds or 10))
end

function M.set_cinematic(value)
    value = value == true
    if value ~= M.cinematic then M.scene = M.scene + 1; M.cinematic = value end
end

-- Set when a modal tutorial (one that pauses play until you continue) has been read; the
-- world gate then checks the game's tutorial system and stays closed while it's up.
M.modal_since = nil

-- Recent sound cues, so the player can ask what a sound was. Newest first.
M.cues = {}
function M.cue(text)
    table.insert(M.cues, 1, { text = text, at = os.clock() })
    if #M.cues > 8 then table.remove(M.cues) end
end

-- Where a point is relative to the player and the camera: "ahead left, 4 metres".
local SIDES = { "ahead", "ahead right", "right", "behind right", "behind", "behind left", "left", "ahead left" }
function M.where(px, py, yaw, x, y)
    local dx, dy = x - px, y - py
    local rel = (math.deg(math.atan(dy, dx)) - yaw) % 360
    local side = SIDES[math.floor((rel + 22.5) / 45) % 8 + 1]
    local m = math.floor(math.sqrt(dx * dx + dy * dy) / 100 + 0.5)
    return side .. ", " .. (m <= 1 and "close" or (m .. " metres"))
end

return M
