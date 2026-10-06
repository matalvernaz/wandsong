-- Path: the objective beacon and autowalk, both following the game's own route.
--
-- The game's path-navigation manager (BP_PathNavigationManager_C) keeps the route it has
-- computed to the tracked objective in PathTS, a plain list of points, plus the mission's
-- destination. Both are read as data; the only function called is
-- GetMissionDestinationLocation on that long-lived manager, when there's no route.
--
-- Beacon (no keys): a ping from a point about 8 metres further along the route, so following
-- the ping follows the path around corners. Higher pitch when that point is above you, lower
-- when below. A chime when you arrive.
--
-- Autowalk (one key, toggles): turns the camera toward the route and holds the forward key
-- while the game window has focus. Any other movement key, the key again, a menu, a cutscene,
-- arrival or getting stuck stops it.

local dispatch = require("dispatch")
local diag = require("diag")
local world = require("world")
local state = require("state")
local keys = require("keys")
local speech = require("speech")

local M = {}

local function log(s) print("[Wandsong path] " .. s .. "\n") end

local audio, input
do
    local ok, mod = pcall(require, "audio_bridge")
    if ok and type(mod) == "table" and mod.init() then audio = mod end
    local ok2, mod2 = pcall(require, "input_bridge")
    if ok2 and type(mod2) == "table" then input = mod2 end
    log("input bridge: " .. (input and "ready" or ("unavailable: " .. tostring(mod2))))
end

local LOOK_AHEAD_CM = 800       -- beacon point distance along the route
local WALK_AHEAD_CM = 300       -- autowalk steers toward a point this far along
local ARRIVE_CM = 400
local FOLLOW_WAIT_CM = 300      -- following someone: stop this close and wait for them
local FOLLOW_RESUME_CM = 500    -- ...and walk on once they're this far ahead
local PING_EVERY = 1.3
local VK_W = 0x57               -- the game's default forward key
local VK_SPACE = 0x20           -- jump / climb / vault
local BLOCKED_AFTER = 1.0       -- holding forward this long without moving: try a jump
local STUCK_AFTER = 4.0         -- ...and give up after this long

local beacon_on = true
local route = {}                -- { {x, y, z}, ... } latest route, player end first
local dest = nil                -- {x, y, z} of the final point
local next_ping = 0
local arrived_at = nil          -- destination already announced as reached

-- --- Reading the route ----------------------------------------------------------------

local mgr_path
local function path_of(o)
    local full
    pcall(function() full = o:GetFullName() end)
    return full and full:match("^%S+%s+(.+)$") or nil
end

local function manager()
    local m
    if mgr_path then pcall(function() m = StaticFindObject(mgr_path) end) end
    if m then
        local ok, v = pcall(function() return m:IsValid() end)
        if ok and v then return m end
    end
    pcall(function()
        for _, o in ipairs(FindAllOf("BP_PathNavigationManager_C") or {}) do
            local n = o:GetFullName()
            if not n:find("Default__", 1, true) then m = o; mgr_path = n:match("^%S+%s+(.+)$") end
        end
    end)
    return m
end

local function vec3(v)
    local x, y, z
    pcall(function() x, y, z = v.X, v.Y, v.Z end)
    if type(x) == "number" then return { x, y, z } end
    return nil
end

local function read_points(arr)
    local pts = {}
    local n = 0
    pcall(function() n = arr:GetArrayNum() end)
    for i = 1, math.min(n, 2000) do
        local p
        pcall(function() p = vec3(arr[i]) end)
        if p then pts[#pts + 1] = p end
    end
    return pts
end

-- Escort scenes (the intro, "follow me" quests) have no route: the mission destination is the
-- character leading you, and it moves. Its positions are kept as a trail, which is the way
-- they actually walked, and the trail is followed like a route.
local TRAIL_STEP_CM = 150       -- a new trail point every this far the target moves
local TRAIL_JUMP_CM = 3000      -- a bigger jump is a new objective: start a fresh trail
local MOVING_FOR = 6            -- seconds since the target last moved that still count as moving
local trail = {}
local dest_moved_at = -100

local function dist3(a, b)
    return math.sqrt((a[1] - b[1]) ^ 2 + (a[2] - b[2]) ^ 2 + (a[3] - b[3]) ^ 2)
end

local function note_dest(d)
    local last = trail[#trail]
    if last and dist3(last, d) > TRAIL_JUMP_CM then trail, dest_moved_at = {}, -100; last = nil end
    if not last then trail[1] = d; return end
    if dist3(last, d) >= TRAIL_STEP_CM then
        trail[#trail + 1] = d
        if #trail > 80 then table.remove(trail, 1) end
        dest_moved_at = os.clock()
    end
end

-- True while the destination is someone walking ahead of you.
local function target_moving() return os.clock() - dest_moved_at < MOVING_FOR end

local function refresh_route()
    local m = manager()
    if not m then route, dest, trail = {}, nil, {}; return end
    diag.trace("path: read route")
    local pts = {}
    pcall(function() pts = read_points(m.PathTS) end)
    if #pts == 0 then pcall(function() pts = read_points(m.GuidePathPoints) end) end
    route = pts
    if #pts > 0 then
        dest, trail, dest_moved_at = pts[#pts], {}, -100
    else
        diag.trace("path: mission destination")
        local d
        pcall(function() d = vec3(m:GetMissionDestinationLocation()) end)
        if d and (math.abs(d[1]) + math.abs(d[2]) + math.abs(d[3])) > 1 then
            dest = d
            note_dest(d)
            -- The trail, ending exactly where the target is now.
            if #trail > 1 then
                for i, p in ipairs(trail) do route[i] = p end
                if dist3(trail[#trail], d) > 1 then route[#route + 1] = d end
            end
        else
            dest, trail = nil, {}
        end
    end
    diag.event("route", string.format("%d points%s, destination %s", #route,
        target_moving() and " (following someone)" or "",
        dest and string.format("%.0f %.0f %.0f", dest[1] / 100, dest[2] / 100, dest[3] / 100) or "none"))
end

-- Point `ahead` cm further along the route from where the player is closest to it.
local function point_along(px, py, pz, ahead)
    if #route == 0 then return dest end
    if #route == 1 then return route[1] end
    -- Closest point on the route's segments (not its corners: the nearest corner can be
    -- behind the player, which would turn them round).
    local best, bi, bx, by, bz = math.huge, 2, route[1][1], route[1][2], route[1][3]
    for i = 1, #route - 1 do
        local a, b = route[i], route[i + 1]
        local sx, sy = b[1] - a[1], b[2] - a[2]
        local len2 = sx * sx + sy * sy
        local t = len2 > 0 and math.max(0, math.min(1, ((px - a[1]) * sx + (py - a[2]) * sy) / len2)) or 0
        local qx, qy = a[1] + sx * t, a[2] + sy * t
        local d = (qx - px) ^ 2 + (qy - py) ^ 2
        if d < best then best, bi, bx, by, bz = d, i + 1, qx, qy, a[3] + (b[3] - a[3]) * t end
    end
    local left = ahead
    local cx, cy, cz = bx, by, bz
    for i = bi, #route do
        local p = route[i]
        local seg = math.sqrt((p[1] - cx) ^ 2 + (p[2] - cy) ^ 2 + (p[3] - cz) ^ 2)
        if seg >= left then
            local t = left / seg
            return { cx + (p[1] - cx) * t, cy + (p[2] - cy) * t, cz + (p[3] - cz) * t }
        end
        left = left - seg
        cx, cy, cz = p[1], p[2], p[3]
    end
    return route[#route]
end

local function dist2d(px, py, p) return math.sqrt((p[1] - px) ^ 2 + (p[2] - py) ^ 2) end

-- --- Beacon ---------------------------------------------------------------------------

local function beacon()
    if not audio or not world.in_game() then return end
    local px, py, pz, yaw = world.position()
    if not dest then return end
    if target_moving() then
        -- Someone leading you: their own person sound says where they are once you're close;
        -- the beacon only calls you along when you fall behind. No arrival chimes.
        if dist2d(px, py, dest) < FOLLOW_RESUME_CM then return end
    elseif dist2d(px, py, dest) < ARRIVE_CM then
        local key = string.format("%.0f,%.0f", dest[1] / 200, dest[2] / 200)
        if arrived_at ~= key then
            arrived_at = key
            audio.play_ui("arrive", 0.6)
            state.cue("Arrived at the objective")
        end
        return
    end
    if not beacon_on or os.clock() < next_ping then return end
    next_ping = os.clock() + PING_EVERY
    local p = point_along(px, py, pz, LOOK_AHEAD_CM)
    if not p then return end
    local dz = p[3] - pz
    local pitch = math.max(0.7, math.min(1.4, 1 + dz / 800))
    audio.play("ping", p[1], p[2], p[3], 0.8, pitch)
    local full = math.floor(dist2d(px, py, dest) / 100 + 0.5)
    state.cue((target_moving() and "Path of the person you're following " or "Objective path ") ..
              state.where(px, py, yaw, p[1], p[2]):gsub(",.*$", "") ..
              (dz > 150 and ", going up" or (dz < -150 and ", going down" or "")) ..
              (target_moving() and ", they're " or ", objective ") .. full .. " metres away")
end

-- --- Autowalk -------------------------------------------------------------------------

local walking = false
local cancel = nil              -- reason, set from the key observer
local key_down = false
local started_at = 0
local following = false         -- this walk is behind someone leading the way
local waiting = false           -- following, close behind them: standing still
local still_since, still_x, still_y = 0, 0, 0   -- where the player last made real progress
local jumps = 0                 -- jumps tried at the current blocked spot
local ignore_space_until = 0    -- our own jump presses must not cancel the walk

local function release()
    if key_down and input then pcall(input.key, VK_W, false) end
    key_down = false
end

local function stop(why, sound)
    if not walking then return end
    walking, waiting = false, false
    release()
    log("autowalk stopped: " .. why)
    if sound and audio then audio.play_ui(sound, 0.6) end
    local said = (why == "you've arrived" and "Arrived at the objective.")
              or (why == "caught up" and "Caught up. They've stopped.")
              or ("Autowalk stopped" .. (why ~= "" and (", " .. why) or ""))
    speech.say(said)
end

-- Movement keys the player presses stop autowalk (not W: that's the key being held).
local STOP_KEYS = { A = true, S = true, D = true, SPACE = true, ESCAPE = true, LEFT_ARROW = true,
                    RIGHT_ARROW = true, UP_ARROW = true, DOWN_ARROW = true }
keys.observe(function(combo, key)
    if not walking or not STOP_KEYS[key] or os.clock() - started_at < 0.3 then return end
    if key == "SPACE" and os.clock() < ignore_space_until then return end
    cancel = "you moved"
end)

local function steer(yaw)
    local pawn = world.pawn()
    if not pawn then return false end
    local ok = pcall(function()
        local c = pawn.Controller
        local r = c.ControlRotation
        c:SetControlRotation({ Pitch = r.Pitch, Yaw = yaw, Roll = 0 })
    end)
    return ok
end

-- A low wall, a fence or a gap in the way: tap the jump key, which also climbs and vaults.
local function jump()
    ignore_space_until = os.clock() + 0.6
    if input.key(VK_SPACE, true) then
        dispatch.later(80, function() pcall(input.key, VK_SPACE, false) end, "autowalk jump release", true)
    end
end

local function walk_tick()
    if not walking then return end
    if cancel then local c = cancel; cancel = nil; stop(c); return end
    if not world.in_game() then stop("the game paused or a scene started"); return end
    if not input or not input.focused() then
        release()   -- alt-tabbed: let go, and pick up again when the game has focus
        return
    end
    local px, py, pz = world.position()
    if not dest then stop("no objective to walk to"); return end
    local d = dist2d(px, py, dest)
    if target_moving() then
        following = true
    elseif following and d < ARRIVE_CM then
        stop("caught up")
        return
    elseif d < ARRIVE_CM then
        stop("you've arrived")   -- the beacon plays the arrival chime
        return
    end
    -- Following: wait close behind them, walk on when they've gone ahead.
    if following then
        if waiting and d > FOLLOW_RESUME_CM then waiting = false
        elseif not waiting and d < FOLLOW_WAIT_CM then waiting = true end
        if waiting then
            release()
            still_since, still_x, still_y, jumps = os.clock(), px, py, 0
            return
        end
    end
    local p = point_along(px, py, pz, WALK_AHEAD_CM)
    if not p then stop("lost the path"); return end
    local yaw = math.deg(math.atan(p[2] - py, p[1] - px))
    if not steer(yaw) then stop("couldn't turn the camera"); return end
    if not key_down then
        key_down = input.key(VK_W, true)
        still_since, still_x, still_y = os.clock(), px, py
    end
    -- Blocked: hardly moved while holding forward. Jump (which climbs and vaults) a couple of
    -- times, then give up.
    if math.sqrt((px - still_x) ^ 2 + (py - still_y) ^ 2) > 60 then
        still_since, still_x, still_y, jumps = os.clock(), px, py, 0
    else
        local t = os.clock() - still_since
        if t > STUCK_AFTER then stop("stuck", "step_blocked")
        elseif t > BLOCKED_AFTER * (jumps + 1) and jumps < 2 then
            jumps = jumps + 1
            log("autowalk blocked: jump " .. jumps)
            jump()
        end
    end
end

local function toggle_walk()
    if walking then stop("") return end
    if not world.in_game() then speech.say("Autowalk works in the world, not in menus.") return end
    if not input then speech.say("Autowalk isn't available: its input module didn't load.") return end
    refresh_route()
    if not dest then speech.say("There's no objective to walk to. Track a quest first.") return end
    local px, py = world.position()
    walking, cancel, waiting = true, nil, false
    following = target_moving()
    started_at, jumps = os.clock(), 0
    still_since, still_x, still_y = os.clock(), px, py
    local stop_key = keys.describe_combo(keys.combo_of("autowalk"))
    local metres = math.floor(dist2d(px, py, dest) / 100 + 0.5)
    if following then
        speech.say(string.format("Following, %d metres behind. Press any movement key or %s to stop.", metres, stop_key))
    else
        speech.say(string.format("Walking to the objective, %d metres. Press any movement key or %s to stop.", metres, stop_key))
    end
    log("autowalk started, " .. #route .. " route points" .. (following and ", following" or ""))
end

keys.action{
    id = "autowalk", name = "Walk to the objective or follow your guide, or stop walking", group = "In the world",
    default = "shift+`", run = toggle_walk,
}
keys.action{
    id = "beacon_toggle", name = "Turn the objective beacon off or on", group = "In the world",
    default = "ctrl+`", run = function()
        beacon_on = not beacon_on
        speech.say("Objective beacon " .. (beacon_on and "on" or "off"))
    end,
}

dispatch.every(1000, function() if world.in_game() then refresh_route() end end, "route")
dispatch.every(100, function() beacon(); walk_tick() end, "beacon and autowalk")
-- If the game stops ticking the dispatcher mid-walk (a load), never leave the key held.
dispatch.every(500, function()
    if walking and state.loading() then walking = false; log("autowalk stopped: loading") end
    if not walking then release() end
end, "autowalk key guard", true)

log("loaded")
return M
