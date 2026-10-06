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
local BESIDE_CM = 170           -- someone standing still: walk right up to them (guides in the
                                -- intro wait for you to come close before the story moves on)
local PING_EVERY = 1.3
local VK_W = 0x57               -- the game's default forward key
local VK_SPACE = 0x20           -- jump / climb / vault
local BLOCKED_AFTER = 1.0       -- holding forward this long without moving: try a jump
local STUCK_AFTER = 4.0         -- ...and give up after this long
local TURN_GIVE_UP = 5.0        -- turning on the spot this long without facing the way: give up

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

local next_mgr_search = 0
local function manager()
    local m
    if mgr_path then pcall(function() m = StaticFindObject(mgr_path) end) end
    if m then
        local ok, v = pcall(function() return m:IsValid() end)
        if ok and v then return m end
    end
    -- FindAllOf costs ~30 ms: when there's no manager (parts of the intro), look again only
    -- every 10 seconds.
    if os.clock() < next_mgr_search then return nil end
    next_mgr_search = os.clock() + 10
    m = nil
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
local TRAIL_JUMP_CM = 800       -- a bigger hop in one second is no one walking: a new
                                -- objective, or the marker moving on; start a fresh trail
local MOVING_FOR = 6            -- seconds since the target last moved that still count as moving
local trail = {}
local dest_moved_at = -100

local function dist2d(px, py, p) return math.sqrt((p[1] - px) ^ 2 + (p[2] - py) ^ 2) end

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

local dest_is_guide = false
-- The destination is a person (walking now, or walked in the last half minute, or the
-- nearest-person fallback) rather than a fixed objective.
local function dest_is_person() return dest_is_guide or os.clock() - dest_moved_at < 30 end

-- Parts of the intro have no objective at all, only someone leading the way: then autowalk
-- (never the beacon, which would ping at any passer-by) follows the nearest person, and keeps
-- following that same person rather than whoever happens to pass closer.
local GUIDE_RANGE_CM = 3000
local guide_path = nil
local source = nil              -- "route", "mission" or "guide": a change starts a fresh trail

local function refresh_route()
    local m = manager()
    diag.trace("path: read route")
    local pts = {}
    if m then
        pcall(function() pts = read_points(m.PathTS) end)
        if #pts == 0 then pcall(function() pts = read_points(m.GuidePathPoints) end) end
    end
    route = pts
    dest_is_guide = false
    if #pts > 0 then
        dest, trail, dest_moved_at, source, guide_path = pts[#pts], {}, -100, "route", nil
    else
        diag.trace("path: mission destination")
        local d, src
        if m then pcall(function() d = vec3(m:GetMissionDestinationLocation()) end) end
        if d and (math.abs(d[1]) + math.abs(d[2]) + math.abs(d[3])) > 1 then
            src, guide_path = "mission", nil
        else
            local px, py = world.position()
            d = guide_path and world.locate(guide_path)
            if d and dist2d(px, py, d) > GUIDE_RANGE_CM then d = nil end
            if not d then
                local p
                d, p = world.nearest("person", GUIDE_RANGE_CM)
                if p ~= guide_path then trail, dest_moved_at = {}, -100 end
                guide_path = p
            end
            dest_is_guide = d ~= nil
            src = "guide"
        end
        if src ~= source then trail, dest_moved_at, source = {}, -100, src end
        if d then
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
        dest_is_guide and " (nearest person)" or (target_moving() and " (following someone)" or ""),
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

-- --- Beacon ---------------------------------------------------------------------------

local function beacon()
    if not audio or not world.in_game() then return end
    local px, py, pz, yaw = world.position()
    if not dest or dest_is_guide then return end
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
local waiting = false           -- following, close behind them: standing still
local still_since, still_x, still_y = 0, 0, 0   -- where the player last made real progress
local jumps = 0                 -- jumps tried at the current blocked spot
local ignore_space_until = 0    -- our own jump presses must not cancel the walk
local crumb = nil               -- following: the trail point being walked to (a table in trail)
local next_walk_log = 0
local turning_since = nil       -- turning on the spot since

-- Following: step through the guide's own footprints in order, so the walk takes exactly
-- the way they went (round rocks and railings) rather than cutting toward the trail.
local CRUMB_REACHED_CM = 120
local function next_crumb(px, py)
    if #trail < 2 then return nil end
    local idx
    for i, p in ipairs(trail) do if p == crumb then idx = i; break end end
    if not idx then
        -- Joining the trail: the latest point about as close as the closest one, so the walk
        -- never heads back along it.
        local best = math.huge
        for _, p in ipairs(trail) do best = math.min(best, dist2d(px, py, p)) end
        for i, p in ipairs(trail) do if dist2d(px, py, p) <= best + 100 then idx = i end end
    end
    while idx < #trail and dist2d(px, py, trail[idx]) < CRUMB_REACHED_CM do idx = idx + 1 end
    crumb = trail[idx]
    return crumb, idx
end

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
              or (why == "caught up" and "Caught up. You're beside them.")
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

-- Turning: the game overwrites a control rotation set from outside (the camera never moved
-- in testing), so the camera is turned the way the player turns it, with relative mouse
-- moves. How far one mouse step turns depends on the player's sensitivity, so it's learned
-- from the facing read back after each move. Until the first move has been measured, moves
-- are kept small so a high sensitivity can't fling the camera round.
local deg_per_px, learned = 0.15, false
local last_dx, last_yaw = 0, nil
local function wrap(a) return (a + 180) % 360 - 180 end

-- The camera's facing right now, read from the controller (a property read, no call).
local function facing()
    local yaw
    pcall(function()
        local pawn = world.pawn()
        if pawn then yaw = pawn.Controller.ControlRotation.Yaw end
    end)
    return type(yaw) == "number" and yaw or nil
end

-- Returns how far off the wanted direction the camera still is, in degrees, or nil on failure.
local function steer(yaw)
    local now = facing()
    if not now then return nil end
    -- Learn from the last move: how far did the camera turn per mouse step?
    if last_yaw and math.abs(last_dx) >= 8 then
        local turned = wrap(now - last_yaw)
        if math.abs(turned) > 0.3 and (turned > 0) == (last_dx > 0) then
            local k = math.abs(turned / last_dx)
            deg_per_px = learned and math.max(0.002, math.min(2, deg_per_px * 0.6 + k * 0.4)) or k
            learned = true
        elseif math.abs(turned) <= 0.3 then
            -- No visible turn: the steps are smaller than guessed; use bigger moves.
            deg_per_px = math.max(0.002, deg_per_px * 0.5)
        end
    end
    local err = wrap(yaw - now)
    local dx = 0
    if math.abs(err) > 2 then
        local want = learned and err or math.max(-20, math.min(20, err))
        dx = math.floor(want / deg_per_px * 0.6 + 0.5)
        dx = math.max(-1500, math.min(1500, dx))
        if dx ~= 0 then input.mouse_move(dx, 0) end
    end
    last_dx, last_yaw = dx, now
    return err
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
    local person, moving = dest_is_person(), target_moving()
    if person and not moving then
        -- They're standing still: walk right up beside them (in the intro the story waits
        -- for you to come close).
        waiting = false
        if d < BESIDE_CM then stop("caught up"); return end
    elseif person then
        -- Walking: stay a few metres behind, wait when close, walk on when they're ahead.
        if waiting and d > FOLLOW_RESUME_CM then waiting = false
        elseif not waiting and d < FOLLOW_WAIT_CM then waiting = true end
        if waiting then
            release()
            still_since, still_x, still_y, jumps = os.clock(), px, py, 0
            return
        end
    elseif d < ARRIVE_CM then
        stop("you've arrived")   -- the beacon plays the arrival chime
        return
    end
    local p, ci
    if person then p, ci = next_crumb(px, py) end
    -- The last stretch to someone standing still goes straight to them.
    if person and not moving and ci == #trail then p = dest end
    if not p then p = point_along(px, py, pz, WALK_AHEAD_CM) end
    if not p then stop("lost the path"); return end
    if os.clock() >= next_walk_log then
        next_walk_log = os.clock() + 1
        log(string.format("walking: at %.1f %.1f %.1f facing %.0f (want %.0f, %.3f deg per mouse step%s), aim %.1f %.1f%s, %s %.1f %.1f, %.1f m",
            px / 100, py / 100, pz / 100, facing() or 0, math.deg(math.atan(p[2] - py, p[1] - px)), deg_per_px,
            learned and "" or ", guessed", p[1] / 100, p[2] / 100,
            ci and string.format(" (footprint %d of %d)", ci, #trail) or "",
            person and (moving and "person walking at" or "person standing at") or "objective at",
            dest[1] / 100, dest[2] / 100, d / 100))
    end
    local yaw = math.deg(math.atan(p[2] - py, p[1] - px))
    local off = steer(yaw)
    if not off then stop("couldn't turn the camera"); return end
    -- Facing well away from the way to go: turn on the spot first rather than walk off.
    if math.abs(off) > 60 then
        release()
        still_since = os.clock()
        turning_since = turning_since or os.clock()
        if os.clock() - turning_since > TURN_GIVE_UP then stop("couldn't turn the camera") end
        return
    end
    turning_since = nil
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
    if not world.in_game() then speech.say(world.not_ready_reason()) return end
    if not (input and input.mouse_move) then
        speech.say("Autowalk isn't available: its input module is missing or out of date. Reinstall the mod.")
        return
    end
    refresh_route()
    if not dest then
        speech.say("There's no objective or person nearby to walk to. Track a quest first.")
        return
    end
    local px, py = world.position()
    walking, cancel, waiting, crumb = true, nil, false, nil
    last_dx, last_yaw, turning_since = 0, nil, nil
    started_at, jumps = os.clock(), 0
    still_since, still_x, still_y = os.clock(), px, py
    local stop_key = keys.describe_combo(keys.combo_of("autowalk"))
    local metres = math.floor(dist2d(px, py, dest) / 100 + 0.5)
    if dest_is_guide then
        speech.say(string.format("No objective here. Following the nearest person, %d metres away. Press any movement key or %s to stop.", metres, stop_key))
    elseif dest_is_person() then
        speech.say(string.format("Following, %d metres behind. Press any movement key or %s to stop.", metres, stop_key))
    else
        speech.say(string.format("Walking to the objective, %d metres. Press any movement key or %s to stop.", metres, stop_key))
    end
    log("autowalk started, " .. #route .. " route points" .. (dest_is_person() and ", following" or ""))
end

-- --- Facing a target ---------------------------------------------------------------------
-- One key turns the camera toward the nearest enemy (or creature, or else the objective), so
-- the game's own spell targeting, which favours what's in front of you, picks it up. The
-- turn happens over a few ticks with the same mouse turning autowalk uses.

local face = nil                -- { path = actor path or nil, x, y, until_t, what }

local function face_tick()
    if not face or walking then return end
    if not world.in_game() or not input or not input.focused() then face = nil; return end
    if face.path then
        local p = world.locate(face.path)
        if p then face.x, face.y = p[1], p[2] end
    end
    local px, py = world.position()
    local off = steer(math.deg(math.atan(face.y - py, face.x - px)))
    if not off or math.abs(off) < 4 or os.clock() > face.until_t then
        log(string.format("facing %s: %s", face.what, off and string.format("%.0f degrees off", off) or "couldn't turn"))
        face = nil
    end
end

local function face_nearest()
    if not world.in_game() then speech.say(world.not_ready_reason()) return end
    if not (input and input.mouse_move) then speech.say("Can't turn: the input module is missing or out of date.") return end
    local px, py, _, yaw = world.position()
    local p, path, what = world.nearest("enemy", 3000)
    what = "enemy"
    if not p then p, path = world.nearest("beast", 3000); what = "creature" end
    if not p and dest and not dest_is_guide then p, path, what = dest, nil, "objective" end
    if not p then speech.say("No enemies or objective nearby to face.") return end
    local metres = math.floor(dist2d(px, py, p) / 100 + 0.5)
    local where = state.where(px, py, yaw, p[1], p[2]):gsub(",.*$", "")
    speech.say(string.format("Turning to the %s, %s, %d metres.", what, where, metres))
    last_dx, last_yaw = 0, nil
    face = { path = path, x = p[1], y = p[2], until_t = os.clock() + 3, what = what }
end

keys.action{
    id = "face_target", name = "Turn to face the nearest enemy (or creature, or the objective)",
    group = "In the world", default = ",", run = face_nearest,
}

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
dispatch.every(100, function() beacon(); walk_tick(); face_tick() end, "beacon and autowalk")
-- If the game stops ticking the dispatcher mid-walk (a load), never leave the key held.
dispatch.every(500, function()
    if walking and state.loading() then walking = false; log("autowalk stopped: loading") end
    if not walking then release() end
end, "autowalk key guard", true)

log("loaded")
return M
