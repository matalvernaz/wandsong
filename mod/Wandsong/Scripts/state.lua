-- Shared state between modules: things one module notices that another must respect.
local M = {}

-- Set while the game is loading (a loading screen is up) and for a short while after.
-- Nothing may touch world objects (actors, the player) during a load: they're being torn
-- down and rebuilt, and touching one mid-teardown crashes inside UE4SS.
M.loading_until = -1
M.generation = 0
-- Counts the worlds the game has built: a map load (or a new player object) replaces every
-- actor and controller, while a load mark alone may be a menu's screen loading in the same
-- world. Objects from an earlier world are never looked up.
M.world = 0
M.scene = 0
M.cinematic = false
M.paused = false
-- What the UI manager last said keeps play from being plain gameplay (a menu, pause, a modal
-- tutorial, a spell lesson), or nil (world.lua's ui_blocker). The dispatcher's barrier for a
-- stop in the game's ticks permits known settled menus to work without Blueprint ticks.
-- Unknown UI states and transitions still hold work; explicit load marks always take priority.
M.ui_blocker = nil

function M.loading() return os.clock() < M.loading_until end

function M.mark_loading(seconds)
    if not M.loading() then M.generation = M.generation + 1; M.scene = M.scene + 1 end
    M.loading_until = math.max(M.loading_until, os.clock() + (seconds or 10))
end

-- Set from the start of UEngine::LoadMap until it returns (UE4SS's load-map hooks). Actors
-- still tick while the old world is torn down, so the dispatcher would run inside the load:
-- at the end of the intro the world gate looked the player up by path there and the game
-- crashed in StaticFindObject (Oct 8). The dispatcher runs nothing while this is set.
M.map_loading_since = nil
function M.begin_map_load()
    M.mark_loading(6)
    M.world = M.world + 1
    M.map_loading_since = os.clock()
end
function M.end_map_load()
    M.map_loading_since = nil
    M.world = M.world + 1
    M.mark_loading(6)
end
--- True while a map load is in progress (at most a minute, should its end never be heard).
function M.in_map_load()
    return M.map_loading_since ~= nil and os.clock() - M.map_loading_since < 60
end

function M.set_cinematic(value)
    value = value == true
    if value ~= M.cinematic then M.scene = M.scene + 1; M.cinematic = value end
end

-- Set when a modal tutorial (one that pauses play until you continue) has been read; the
-- world gate then checks the game's tutorial system and stays closed while it's up.
M.modal_since = nil
-- Set when the quest-failed (or defeated) screen has been read; cleared once it's gone.
M.fail_screen_since = nil

-- Recent sound cues, so the player can ask what a sound was. Newest first.
M.cues = {}
function M.cue(text)
    table.insert(M.cues, 1, { text = text, at = os.clock() })
    if #M.cues > 8 then table.remove(M.cues) end
end

-- A world yaw as a compass word. The game's +X axis is called north (Unreal's convention); it
-- stays consistent, which is what matters for finding your way.
local COMPASS = { "north", "north-east", "east", "south-east", "south", "south-west", "west", "north-west" }
function M.compass(yaw) return COMPASS[math.floor(((yaw % 360) + 22.5) / 45) % 8 + 1] end

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
