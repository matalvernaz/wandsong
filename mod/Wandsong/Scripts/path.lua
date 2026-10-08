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
local bindings = require("bindings")

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
local ARRIVE_HEIGHT_CM = 140    -- actor centres/navmesh floors differ; another floor is not arrival
local FOLLOW_WAIT_CM = 300      -- following someone: stop this close and wait for them
local FOLLOW_RESUME_CM = 500    -- ...and walk on once they're this far ahead
local BESIDE_CM = 170           -- someone standing still: walk right up to them (guides in the
                                -- intro wait for you to come close before the story moves on)
local PING_EVERY = 1.3
local VK_W = bindings.virtual_key(bindings.forward())
local VK_SPACE = bindings.virtual_key(bindings.key("AM_Jump", "SpaceBar"))
local BLOCKED_AFTER = 1.0       -- holding forward this long without moving: try a jump
local STUCK_AFTER = 5.0         -- allow a held jump/climb and one route retry
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
        -- Valid, and still the object the path names (a destroyed one comes back renamed None).
        local ok, v = pcall(function() return m:IsValid() and m:GetFullName():find(mgr_path, 1, true) ~= nil end)
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
    if type(x) == "number" and type(y) == "number" and type(z) == "number"
       and x == x and y == y and z == z and math.abs(x) < math.huge
       and math.abs(y) < math.huge and math.abs(z) < math.huge then return { x, y, z } end
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
local chosen = nil              -- { path, name, kind }: selected scanner target
-- The destination is a person (walking now, or walked in the last half minute, or the
-- nearest-person fallback) rather than a fixed objective.
local function dest_is_person()
    if chosen then return chosen.kind == "person" or chosen.kind == "enemy" or chosen.kind == "beast" end
    return dest_is_guide or os.clock() - dest_moved_at < 30
end

-- Parts of the intro have no objective at all, only someone leading the way: then autowalk
-- (never the beacon, which would ping at any passer-by) follows the nearest person, and keeps
-- following that same person rather than whoever happens to pass closer.
local GUIDE_RANGE_CM = 3000
local guide_path = nil
local source = nil              -- "route", "mission" or "guide": a change starts a fresh trail

-- Forward-declared above for target classification.
local last_objective = nil      -- the current task, as the game words it (when it does)

-- Someone the current objective names ("Find Professor Fig"), among the characters the story
-- has introduced by name (subtitles): the world scan keeps those even far away.
local function named_in_objective()
    if not last_objective then return nil end
    local text = last_objective:lower()
    for _, e in ipairs(world.entries()) do
        if e.name_src == "subtitles" and e.name and #e.name > 3 and text:find(e.name:lower(), 1, true) then return e end
    end
    return nil
end

-- --- The engine's own pathfinding, when the game gives no route ---------------------------
-- Some objectives come with a destination but no route (PathTS empty). Then the engine's
-- navigation system is asked for a path over its navmesh (FindPathToLocationSynchronously,
-- a static function, called on its class default object) and the path's points become the
-- route. Guarded by a crash fuse like the world layer's: a marker file exists only during the
-- call, and if the game ever dies inside it, path-finding stays off from the next launch.
local NAV_FUSE = require("files").runtime("nav_active.flag", true)
local nav_ok = true
do
    local f = io.open(NAV_FUSE, "r")
    if f then
        f:close()
        nav_ok = false
        log("nav fuse: the game stopped during a path query last time; path-finding is off this session")
        os.remove(NAV_FUSE)
    end
end
local walking = false           -- autowalk running (declared early: the route refresh uses it)
local nav_cache = nil           -- { x, y, z, at, pts }
local nav_fails = 0
local route_failure = nil
local route_from_nav = false
-- The navmesh sometimes stops well short of an objective that is plainly walkable (the vault's
-- glowing floor: the path ended 13 m away, Oct 7, and Matt had to walk the rest by hand). Then
-- the last stretch is walked straight, up to this far, watching the floor ahead for drops;
-- a wall still ends it as "stuck".
local STRAIGHT_MAX_CM = 2500
local straight_to = nil         -- {x, y, z}: the objective being walked to in a straight line
local next_floor_check = 0

local function nav_route(d, max_age)
    if not nav_ok then return nil, "pathfinding is paused after a previous crash" end
    if nav_cache and os.clock() - nav_cache.at < max_age and dist3(nav_cache, { d[1], d[2], d[3] }) < 200 then
        return #nav_cache.pts >= 2 and nav_cache.pts or nil, nav_cache.error
    end
    local pawn = world.pawn()
    if not pawn then return nil end
    local px, py, pz = world.position()
    local pts = {}
    diag.trace("path: nav query")
    local f = io.open(NAV_FUSE, "w")
    if f then f:write("path query running\n"); f:close() end
    local ok, err = pcall(function()
        local ns = StaticFindObject("/Script/NavigationSystem.Default__NavigationSystemV1")
        local np = ns:FindPathToLocationSynchronously(pawn, { X = px, Y = py, Z = pz }, { X = d[1], Y = d[2], Z = d[3] }, pawn, nil)
        if np then pts = read_points(np.PathPoints) end
    end)
    os.remove(NAV_FUSE)
    nav_cache = { d[1], d[2], d[3], at = os.clock(), pts = pts }
    if not ok or #pts < 2 then
        nav_fails = nav_fails + 1
        log("nav query: " .. (ok and (#pts .. " points") or ("failed: " .. tostring(err))))
        nav_cache.error = "no path found"
        return nil, nav_cache.error
    end
    log(string.format("nav query: %d points to %.0f %.0f %.0f", #pts, d[1] / 100, d[2] / 100, d[3] / 100))
    return pts
end

local function refresh_route()
    route_failure, route_from_nav = nil, false
    if chosen then
        -- Walking to something picked in the scanner: it's the destination (followed like a
        -- person if it moves), whatever the quest says.
        route, dest_is_guide = {}, false
        local d = world.locate(chosen.path)
        if not d then dest = nil; return end
        if source ~= "chosen" then trail, dest_moved_at, source = {}, -100, "chosen" end
        dest = d
        note_dest(d)
        if dest_is_person() and #trail > 1 then
            for i, p in ipairs(trail) do route[i] = p end
            if dist3(trail[#trail], d) > 1 then route[#route + 1] = d end
        elseif straight_to and dist3(straight_to, d) < 200 then
            route = { d }
        else
            local nav, err = nav_route(d, walking and 3 or 8)
            if nav then route, route_from_nav = nav, true
            elseif not dest_is_person() then route_failure = err or "no path found" end
        end
        return
    end
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
        if not (d and (math.abs(d[1]) + math.abs(d[2]) + math.abs(d[3])) > 1) then
            -- No destination from the game, but the objective names someone the story has
            -- introduced: that person is the destination, however far (Oct 8, the vault: Fig
            -- 100 m away in the dark, and autowalk had nowhere to go).
            local named = named_in_objective()
            d = named and world.locate(named.path) or nil
        end
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
            elseif src == "mission" and not target_moving() then
                if straight_to and dist3(straight_to, d) < 200 then
                    route = { d }
                else
                    -- A fixed objective with no route from the game: ask the navmesh.
                    local nav = nav_route(d, walking and 3 or 8)
                    if nav then route, route_from_nav = nav, true end
                end
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
        local sx, sy, sz = b[1] - a[1], b[2] - a[2], b[3] - a[3]
        local len2 = sx * sx + sy * sy + sz * sz
        local t = len2 > 0 and math.max(0, math.min(1, ((px - a[1]) * sx + (py - a[2]) * sy + (pz - a[3]) * sz) / len2)) or 0
        local qx, qy = a[1] + sx * t, a[2] + sy * t
        local d = (qx - px) ^ 2 + (qy - py) ^ 2 + (a[3] + sz * t - pz) ^ 2
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
    if not audio or not world.in_game() or (world.sounds_enabled and not world.sounds_enabled()) then return end
    if speech.is_muted() or not beacon_on then return end
    local px, py, pz, yaw = world.position()
    if not dest or dest_is_guide then return end
    if target_moving() then
        -- Someone leading you: their own person sound says where they are once you're close;
        -- the beacon only calls you along when you fall behind. No arrival chimes.
        if dist2d(px, py, dest) < FOLLOW_RESUME_CM and math.abs(dest[3] - pz) < ARRIVE_HEIGHT_CM then return end
    elseif dist2d(px, py, dest) < ARRIVE_CM and math.abs(dest[3] - pz) < ARRIVE_HEIGHT_CM then
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

walking = false
local cancel = nil              -- reason, set from the key observer
local key_down = false
local started_at = 0
local waiting = false           -- following, close behind them: standing still
local still_since, still_x, still_y, still_z = 0, 0, 0, 0
local jump_down = false
local jump_token = 0
local ignore_forward_until = 0
local generation = state.generation
local jumps = 0                 -- jumps tried at the current blocked spot
local ignore_space_until = 0    -- our own jump presses must not cancel the walk
local crumb = nil               -- following: the trail point being walked to (a table in trail)
local next_walk_log = 0
local turning_since = nil       -- turning on the spot since

-- Following: step through the guide's own footprints in order, so the walk takes exactly
-- the way they went (round rocks and railings) rather than cutting toward the trail.
local CRUMB_REACHED_CM = 120
local function next_crumb(px, py, pz)
    if #trail < 2 then return nil end
    local idx
    for i, p in ipairs(trail) do if p == crumb then idx = i; break end end
    if not idx then
        -- Joining the trail: the latest point about as close as the closest one, so the walk
        -- never heads back along it.
        local best = math.huge
        for _, p in ipairs(trail) do best = math.min(best, dist3({px, py, pz}, p)) end
        for i, p in ipairs(trail) do if dist3({px, py, pz}, p) <= best + 40 then idx = i end end
    end
    while idx < #trail and dist3({px, py, pz}, trail[idx]) < CRUMB_REACHED_CM do idx = idx + 1 end
    crumb = trail[idx]
    return crumb, idx
end

local function release()
    if key_down and input then pcall(input.key, VK_W, false) end
    if jump_down and input then pcall(input.key, VK_SPACE, false) end
    key_down = false
    jump_down = false
    jump_token = jump_token + 1
end

local PAUSED = "the game paused or a scene started"
local function stop(why, sound)
    if not walking then return end
    walking, waiting, straight_to = false, false, nil
    release()
    log("autowalk stopped: " .. why)
    local was = chosen
    chosen = nil
    if was then route, dest, nav_cache, source = {}, nil, nil, nil end
    if why == "handed to the AI walk" then return end   -- ai_walk.lua speaks for itself
    if was and (why == "caught up" or why == "you've arrived") then
        speech.say("Arrived at " .. was.name .. ".")
        return
    end
    if sound and audio and not speech.is_muted() and (not world.sounds_enabled or world.sounds_enabled()) then
        audio.play_ui(sound, 0.6)
    end
    local said = (why == "you've arrived" and "Arrived at the objective.")
              or (why == "caught up" and "Caught up. You're beside them.")
              or ("Autowalk stopped" .. (why ~= "" and (", " .. why) or ""))
    -- A pause or scene stops autowalk because something else just started talking (a tutorial,
    -- a line of dialogue): queue behind it rather than cut it off.
    speech.say(said, why == PAUSED)
end

-- Movement keys the player presses stop autowalk (not W: that's the key being held).
local STOP_KEYS = { A = true, S = true, D = true, SPACE = true, ESCAPE = true, LEFT_ARROW = true,
                    RIGHT_ARROW = true, UP_ARROW = true, DOWN_ARROW = true }
keys.observe(function(combo, key)
    local vk = Key[key]
    if not walking or not (STOP_KEYS[key] or bindings.movement_vk(vk) or vk == VK_SPACE)
       or os.clock() - started_at < 0.3 then return end
    if vk == VK_SPACE and os.clock() < ignore_space_until then return end
    if vk == VK_W and os.clock() < ignore_forward_until then return end
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
        elseif math.abs(turned) <= 0.3 and not learned then
            -- No visible turn before anything was measured: the steps are smaller than
            -- guessed; use bigger moves. Once measured, no turn means the game is holding the
            -- camera (a scripted walk after the vault's basin scene, Oct 8): halving then shrank
            -- the measurement to 0.002 and grew the moves until they pushed the cursor to the
            -- screen's edge, and would fling the camera round once it was free.
            deg_per_px = math.max(0.01, deg_per_px * 0.5)
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

-- Hold jump while moving forward so the game's climb/vault can engage.
local function jump()
    if not VK_SPACE or jump_down then return end
    ignore_space_until = os.clock() + 1
    if input.key(VK_SPACE, true) then
        jump_down = true
        jump_token = jump_token + 1
        local token = jump_token
        -- Keep forward held through the jump so the game's mantle/vault can engage.
        dispatch.later(650, function()
            if token == jump_token and jump_down then pcall(input.key, VK_SPACE, false); jump_down = false end
        end, "autowalk jump release", true)
    end
end

-- The objective is someone to follow, standing at the destination ("Follow Professor Fig" by
-- the Gringotts vault door): the story waits until you are beside them, and stopping 4 m short
-- left you there with nothing happening (Oct 7; the same on the cliffs, Oct 6).
local function guide_at_dest()
    if last_objective and last_objective:find("^Follow ") then return true end
    if not dest or not world.entries or not world.locate then return false end
    for _, e in ipairs(world.entries()) do
        if e.kind == "person" and e.dist and e.dist < 3000 then
            local p = world.locate(e.path)
            if p and dist2d(p[1], p[2], dest) < 250 and math.abs(p[3] - dest[3]) < ARRIVE_HEIGHT_CM then
                return true
            end
        end
    end
    return false
end

-- Where the player was at the last walking tick: a jump further than this in one tick is the
-- game putting the player elsewhere. The vault's dark maze sends you back to its start when you
-- stray from the wisps, and autowalk walked into it again for three minutes (Oct 8).
local TELEPORT_CM = 1500
local walk_from = nil

local function walk_tick()
    if not walking then walk_from = nil; return end
    if cancel then local c = cancel; cancel = nil; stop(c); return end
    if not world.in_game() then stop(PAUSED); return end
    if route_failure then stop(route_failure); return end
    if not input or not input.focused() then
        release()   -- alt-tabbed: let go, and pick up again when the game has focus
        walk_from = nil
        return
    end
    local px, py, pz = world.position()
    if walk_from and dist3(walk_from, { px, py, pz }) > TELEPORT_CM then
        walk_from = nil
        stop("the game moved you back, so that way isn't open")
        return
    end
    walk_from = { px, py, pz }
    if not dest then stop(chosen and "it's gone" or "no objective to walk to"); return end
    local d = dist2d(px, py, dest)
    -- Right on top of it counts even when the marker sits lower or higher than the player's
    -- centre (the vault's glowing floor: 1.7 m below, and autowalk circled it, Oct 7).
    local level = math.abs(dest[3] - pz) < ARRIVE_HEIGHT_CM or (d < 150 and math.abs(dest[3] - pz) < 250)
    if route_failure then stop(route_failure); return end
    local person, moving = dest_is_person(), target_moving()
    if person and not moving then
        -- They're standing still: walk right up beside them (in the intro the story waits
        -- for you to come close).
        waiting = false
        if d < BESIDE_CM and level then stop("caught up"); return end
    elseif person then
        -- Walking: stay a few metres behind, wait when close, walk on when they're ahead.
        if waiting and (d > FOLLOW_RESUME_CM or not level) then waiting = false
        elseif not waiting and d < FOLLOW_WAIT_CM and level then waiting = true end
        if waiting then
            release()
            still_since, still_x, still_y, still_z, jumps = os.clock(), px, py, pz, 0
            return
        end
    elseif d < (chosen and BESIDE_CM or ARRIVE_CM) and level
           and (chosen or d < BESIDE_CM or not guide_at_dest()) then
        stop("you've arrived")   -- the beacon plays the arrival chime
        return
    end
    local p, ci
    -- Reaching the end of a complete path isn't a partial-path failure. The player can
    -- still be a step short of a waiting guide, who starts moving as we approach (vault 12).
    local endpoint = route[#route]
    local partial = endpoint and (dist2d(dest[1], dest[2], endpoint) > BESIDE_CM
        or math.abs(dest[3] - endpoint[3]) >= ARRIVE_HEIGHT_CM)
    if route_from_nav and #route > 1 and partial and dist3({px, py, pz}, endpoint) < 130 then
        local left = dist3({px, py, pz}, dest)
        if not straight_to and not person and left < STRAIGHT_MAX_CM and math.abs(dest[3] - pz) < 2 * ARRIVE_HEIGHT_CM then
            straight_to = { dest[1], dest[2], dest[3] }
            route, route_from_nav = { straight_to }, false
            log(string.format("path ends %.1f m short; walking straight", left / 100))
        else
            stop(string.format("as close as the path goes, %.1f metres from %s", left / 100,
                 chosen and chosen.name or "the objective"))
            return
        end
    end
    if straight_to and os.clock() >= next_floor_check then
        next_floor_check = os.clock() + 0.3
        local yaw_to = math.deg(math.atan(dest[2] - py, dest[1] - px))
        local floor, unknown = require("surroundings").floor_ahead(yaw_to, 120)
        if not unknown and (not floor or floor < -100) then
            stop(string.format("the floor drops away ahead, %.1f metres from %s", dist3({px, py, pz}, dest) / 100,
                 chosen and chosen.name or "the objective"), "ledge")
            return
        end
    end
    if person then p, ci = next_crumb(px, py, pz) end
    -- The last stretch to someone standing still goes straight to them.
    if person and not moving and ci == #trail and level then p = dest end
    if not p then p = point_along(px, py, pz, level and WALK_AHEAD_CM or 100) end
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
        ignore_forward_until = os.clock() + 0.3
        key_down = input.key(VK_W, true)
        still_since, still_x, still_y, still_z = os.clock(), px, py, pz
    end
    -- Blocked: hardly moved while holding forward. Jump (which climbs and vaults) a couple of
    -- times, then give up.
    if math.sqrt((px - still_x) ^ 2 + (py - still_y) ^ 2) > 60 then
        still_since, still_x, still_y, still_z, jumps = os.clock(), px, py, pz, 0
    elseif pz > still_z + 60 then
        -- Net ascent is progress. Landing after a jump is not, and must not renew
        -- the jump budget forever when bouncing against the same obstacle.
        still_since, still_z = os.clock(), pz
    else
        local t = os.clock() - still_since
        if t > STUCK_AFTER then
            -- Record what's in the way and where the route goes, to work out from the log what a
            -- sighted player would do here.
            pcall(function()
                local nxt = {}
                for _, q in ipairs(route) do
                    if #nxt < 4 and dist2d(px, py, q) > 50 then
                        nxt[#nxt + 1] = string.format("(%.1f m away, %+.1f m up)", dist2d(px, py, q) / 100, (q[3] - pz) / 100)
                    end
                end
                log(string.format("stuck at %.1f %.1f %.1f heading %.0f; ahead: %s; route: %s", px / 100, py / 100,
                    pz / 100, yaw, require("surroundings").profile(yaw), table.concat(nxt, " ")))
            end)
            -- A walk the keys can't finish: the game's own AI may (ai_walk.lua, switched off
            -- unless ai_walk_enabled.txt exists). Once per stuck walk.
            local ai = package.loaded.ai_walk
            if ai and ai.enabled and ai.enabled() and dest then
                local name = chosen and chosen.name or "the objective"
                local target = { dest[1], dest[2], dest[3] }
                release()
                if ai.start(target, name) then stop("handed to the AI walk"); return end
            end
            stop("stuck", "step_blocked")
        elseif t > BLOCKED_AFTER * (jumps + 1) and jumps < 2 then
            jumps = jumps + 1
            log("autowalk blocked: jump " .. jumps)
            nav_cache = nil   -- and ask for a fresh path around whatever it is
            refresh_route()
            if route_failure then stop(route_failure); return end
            jump()
        end
    end
end

local function toggle_walk()
    if walking then stop("") return end
    local ai = package.loaded.ai_walk
    if ai and ai.active and ai.active() then ai.stop("walk key"); return end
    if not world.in_game() then speech.say(world.not_ready_reason()) return end
    if not (input and input.mouse_move) then
        speech.say("Autowalk isn't available: its input module is missing or out of date. Reinstall the mod.")
        return
    end
    if not VK_W then speech.say("Assign a keyboard key to forward movement before using autowalk."); return end
    refresh_route()
    if not dest then
        speech.say("There's no objective or person nearby to walk to. Track a quest first.")
        return
    end
    local px, py, pz = world.position()
    walking, cancel, waiting, crumb = true, nil, false, nil
    last_dx, last_yaw, turning_since = 0, nil, nil
    started_at, jumps = os.clock(), 0
    still_since, still_x, still_y, still_z = os.clock(), px, py, pz
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

--- Walk to a scanner entry (by object path).
function M.walk_to(path, name, kind)
    if not world.in_game() then speech.say(world.not_ready_reason()) return end
    if not (input and input.mouse_move) then
        speech.say("Autowalk isn't available: its input module is missing or out of date. Reinstall the mod.")
        return
    end
    if walking then stop("") end
    if not VK_W then speech.say("Assign a keyboard key to forward movement before using autowalk."); return end
    chosen = { path = path, name = name, kind = kind }
    nav_cache = nil
    refresh_route()
    if not dest then chosen = nil; speech.say(name .. " has gone.") return end
    if route_failure then
        speech.say("Can't walk to " .. name .. ": " .. route_failure .. ".")
        chosen, dest, route = nil, nil, {}
        return
    end
    local px, py, pz = world.position()
    walking, cancel, waiting, crumb = true, nil, false, nil
    last_dx, last_yaw, turning_since = 0, nil, nil
    started_at, jumps = os.clock(), 0
    still_since, still_x, still_y, still_z = os.clock(), px, py, pz
    speech.say(string.format("Walking to %s, %d metres. Press any movement key or %s to stop.", name,
        math.floor(dist2d(px, py, dest) / 100 + 0.5), keys.describe_combo(keys.combo_of("autowalk"))))
    log("autowalk to " .. path)
end

-- --- Facing a target ---------------------------------------------------------------------
-- One key turns the camera toward the nearest enemy (or creature, or else the objective), so
-- the game's own spell targeting, which favours what's in front of you, picks it up. The
-- turn happens over a few ticks with the same mouse turning autowalk uses.

local face = nil                -- { path = actor path or nil, x, y, until_t, what }

local compass = state.compass

local function face_tick()
    if not face or walking then return end
    if not world.in_game() or not input or not input.focused() then face = nil; return end
    if face.path then
        local p = world.locate(face.path)
        if p then face.x, face.y = p[1], p[2] end
    end
    local px, py = world.position()
    local want = face.yaw or math.deg(math.atan(face.y - py, face.x - px))
    local off = steer(want)
    if not off or math.abs(off) < 4 or os.clock() > face.until_t then
        log(string.format("facing %s: %s", face.what, off and string.format("%.0f degrees off", off) or "couldn't turn"))
        if face.say_after then
            local now = facing()
            if now then speech.say("Facing " .. compass(now)) end
        end
        face = nil
    end
end

local function turn_by(degrees)
    if not world.in_game() then return end
    if not (input and input.mouse_move) then return end
    if walking then stop("you turned") end
    local now = facing()
    if not now then return end
    last_dx, last_yaw = 0, nil
    -- Snap to the nearest 45 degrees, so turns land on the compass points.
    local target = math.floor((now + degrees) / 45 + 0.5) * 45
    face = { yaw = wrap(target), until_t = os.clock() + 3, what = "a turn", say_after = true }
    if audio and not speech.is_muted() and (not world.sounds_enabled or world.sounds_enabled()) then audio.play_ui("tick", 0.5) end
end

--- Turn to face a scanner entry (by object path). quiet: the caller has already spoken.
function M.face_to(path, name, quiet)
    if not world.in_game() then speech.say(world.not_ready_reason()) return end
    if not (input and input.mouse_move) then speech.say("Can't turn: the input module is missing or out of date.") return end
    local p = world.locate(path)
    if not p then speech.say(name .. " has gone.") return end
    last_dx, last_yaw = 0, nil
    face = { path = path, x = p[1], y = p[2], until_t = os.clock() + 3, what = name }
    if not quiet then speech.say("Turning to " .. name) end
end

--- Turn to face a fixed point (the objective).
function M.face_point(x, y, name)
    if not world.in_game() or not (input and input.mouse_move) then return end
    last_dx, last_yaw = 0, nil
    face = { x = x, y = y, until_t = os.clock() + 3, what = name }
end

--- The current objective as a scanner entry: { x, y, z, name }, or nil. Not the
--- nearest-person fallback or a scanner walk target: only what the game points at.
function M.objective()
    if not dest or dest_is_guide or chosen then return nil end
    return { x = dest[1], y = dest[2], z = dest[3],
             name = (last_objective and ("Objective: " .. last_objective)) or "Quest objective" }
end

--- Start autowalk to the objective (scanner: walk to the quest objective entry).
function M.walk_objective()
    if not walking then toggle_walk() end
end

-- The tracked quest and its current task, from the game's mission manager (a long-lived
-- object, asked only on a key press). GetMissionLogDataBP returns every quest's log entry and
-- the tracked one's index through an out parameter.
local last_quest_line = nil
-- Logs each distinct failure once per session (the objective watch asks every 4 s).
local logged_once = {}
local function once_log(s) if not logged_once[s] then logged_once[s] = true; log(s) end end
-- The quest as the HUD shows it: the tracked quest's title (the mission banner's
-- StepTitleText, "The Path to Hogwarts") and its open tasks (each live
-- UI_BP_MissionBannerCheckbox_C, "Follow Professor Fig"). Found with the developer console,
-- Oct 6: the mission manager only hands back localisation keys ("INT_01_Intro_AncientPath").
-- Widgets are looked up fresh each time and only read while the UI is settled.
local function widget_text(w)
    local ok, t = pcall(function() return w:GetText():ToString() end)
    if ok and t then t = t:gsub("<[^>]*>", ""):gsub("%s+", " "):match("^%s*(.-)%s*$") end
    return ok and t ~= "" and t or nil
end
local function visible(w)
    local ok, v = pcall(function() return w:IsValid() and w:IsVisible() end)
    return ok and v == true
end
-- Where the HUD's quest widgets live, so most checks are a quick StaticFindObject; a full
-- FindAllOf (about 50 ms) only every 15 s or when the remembered ones are gone.
local quest_paths, quest_scan_at = nil, -100
local function quest_widgets()
    local found = {}
    if quest_paths and os.clock() - quest_scan_at < 15 then
        for _, p in ipairs(quest_paths) do
            local o
            pcall(function() o = StaticFindObject(p.path) end)
            -- A widget the game has destroyed can come back from the lookup renamed None:
            -- calling IsVisible on it would crash. The full name must still end in the path.
            local same = o and path_of(o) == p.path
            if same and visible(o) then found[#found + 1] = { kind = p.kind, obj = o } end
        end
        -- Only the title showing: the next task may be in a widget not remembered yet, so look
        -- again sooner than the full 15 s.
        local has_task = false
        for _, f in ipairs(found) do if f.kind == "task" then has_task = true end end
        if #found > 0 and (has_task or os.clock() - quest_scan_at < 6) then return found end
    end
    quest_paths, quest_scan_at = {}, os.clock()
    for kind, cls in pairs({ task = "UI_BP_MissionBannerCheckbox_C", banner = "UI_BP_MissionBanner_New_C" }) do
        for _, o in ipairs(FindAllOf(cls) or {}) do
            if visible(o) then
                found[#found + 1] = { kind = kind, obj = o }
                local p = path_of(o)
                if p then quest_paths[#quest_paths + 1] = { kind = kind, path = p } end
            end
        end
    end
    return found
end
-- Tasks name actions the way the HUD's icons show them: "Tap to destroy statues with Basic
-- Cast" (the vault, Oct 8). Say the key that does it, in the player's current bindings.
local HUD_ACTIONS = { { "basic cast", "AM_Stupefy", "LeftMouseButton" } }
local function with_keys(t)
    local lower = t:lower()
    for _, a in ipairs(HUD_ACTIONS) do
        local _, e = lower:find(a[1], 1, true)
        if e then
            t = t:sub(1, e) .. " (" .. bindings.spoken(a[2], a[3]) .. ")" .. t:sub(e + 1)
            t = t:gsub("^Tap to (%l)", string.upper)
            break
        end
    end
    return t
end
local function objective_text()
    if world.ui_busy and world.ui_busy() then return nil end
    local tasks, seen, title = {}, {}, nil
    for _, w in ipairs(quest_widgets()) do
        if w.kind == "task" then
            local t
            pcall(function() t = widget_text(w.obj.CheckboxText) end)
            if t and not seen[t] then seen[t] = true; tasks[#tasks + 1] = with_keys(t) end
        elseif not title then
            pcall(function() title = widget_text(w.obj.StepTitleText) end)
        end
    end
    if #tasks == 0 and not title then once_log("quest text: no visible quest on the HUD") return nil end
    once_log("quest text from the HUD: " .. tostring(title) .. " | " .. table.concat(tasks, "; "))
    return "Quest: " .. (title or "current quest") .. (#tasks > 0 and (". " .. table.concat(tasks, ". ")) or ""), #tasks > 0
end

-- New objectives are announced as the game changes them (checked every 4 s in the world).
-- Only text that reads as words is spoken: localisation keys are logged instead.
local function looks_like_words(t) return t and t:find("%a") and not t:find("_", 1, true) end
dispatch.every(4000, function()
    if not world.in_game() or state.loading() then return end
    local q, has_task = objective_text()
    -- Between two tasks the HUD shows only the quest's title: not a new objective ("New
    -- objective: The Path to Hogwarts" was said after each step of the vault fight, Oct 8).
    if not q or not has_task or q == last_quest_line then return end
    local first = last_quest_line == nil
    last_quest_line = q
    local task = q:match("^Quest: .-%. (.+)$") or q:gsub("^Quest: ", "")
    if not looks_like_words(task) then log("objective text not spoken (not words?): " .. q) return end
    -- A counter moving on the same task ("Protego incoming enemy attacks (2/3)") is progress,
    -- not a new objective (Oct 8, the vault fight).
    local base, done, total = task:match("^(.-)%s*%((%d+)/(%d+)%)$")
    local was = last_objective and last_objective:match("^(.-)%s*%(%d+/%d+%)$")
    last_objective = task
    if first then return end
    if base and was == base then speech.say(done .. " of " .. total .. ".", true)
    elseif base then speech.say("New objective: " .. base .. ", " .. done .. " of " .. total .. ".", true)
    else speech.say("New objective: " .. task, true) end
end, "objective watch")

local function where_am_i()
    if state.steering then return end   -- steering a spell lesson's wand (spells.lua)
    -- In menus the up arrow moves up the list.
    if not world.in_game() then
        if state.menu_step and not world.gameplay() then state.menu_step(-1)
        else speech.say(world.not_ready_reason()) end
        return
    end
    local now = facing()
    local px, py, _, yaw = world.position()
    local t = { "Facing " .. compass(now or yaw) }
    if dest and not dest_is_guide then
        local w = state.where(px, py, now or yaw, dest[1], dest[2])
        t[#t + 1] = (dest_is_person() and "Person you're following " or "Objective ") .. w
    end
    local q = objective_text()
    if q then t[#t + 1] = q end
    speech.say(table.concat(t, ". "))
end

-- Teleport, a safety net from other access mods (Shift+End): when the way to the objective can't be
-- walked (a ledge that won't climb, a missing step), put the player on the route a few metres
-- short of the objective. K2_TeleportTo is the engine's own teleport: it checks the spot is
-- free and needs no out parameter. A deliberate, player-asked call on the player's character.
local function teleport()
    if not world.in_game() then speech.say(world.not_ready_reason()) return end
    refresh_route()
    if not dest or dest_is_guide then speech.say("There's no objective to go to.") return end
    if walking then stop("") end
    local px, py = world.position()
    -- A route point about 3 m short of the objective, on walkable ground; else the objective.
    local target = dest
    if #route > 1 then
        for i = #route, 1, -1 do
            if dist2d(route[i][1], route[i][2], dest) >= 300 then target = route[i]; break end
        end
    end
    local pawn = world.pawn()
    if not pawn then return end
    local ok, moved = pcall(function()
        local yaw = pawn.Controller.ControlRotation.Yaw
        return pawn:K2_TeleportTo({ X = target[1], Y = target[2], Z = target[3] + 100 },
                                  { Pitch = 0, Yaw = yaw, Roll = 0 })
    end)
    log(string.format("teleport to %.0f %.0f %.0f: %s", target[1] / 100, target[2] / 100, target[3] / 100,
                      ok and tostring(moved) or "failed"))
    if ok and moved then
        speech.say(string.format("Moved you %d metres, near the objective.",
                                 math.floor(dist2d(px, py, target) / 100 + 0.5)))
    else
        speech.say("Couldn't move you there.")
    end
end
keys.action{ id = "teleport", name = "Teleport near the objective, when you're stuck", group = "In the world",
             default = "shift+end", run = teleport }

keys.action{ id = "turn_left", name = "Turn left 45 degrees", group = "In the world", default = "left_arrow",
             run = function() turn_by(-45) end }
keys.action{ id = "turn_right", name = "Turn right 45 degrees", group = "In the world", default = "right_arrow",
             run = function() turn_by(45) end }
keys.action{ id = "turn_left_big", name = "Turn left 90 degrees", group = "In the world", default = "shift+left_arrow",
             run = function() turn_by(-90) end }
keys.action{ id = "turn_right_big", name = "Turn right 90 degrees", group = "In the world", default = "shift+right_arrow",
             run = function() turn_by(90) end }
keys.action{ id = "turn_around", name = "Turn around (in menus: next item)", group = "In the world", default = "down_arrow",
             run = function()
                 if state.steering then return end
                 if not world.in_game() then
                     if state.menu_step and not world.gameplay() then state.menu_step(1)
                     elseif world.gameplay() then speech.say(world.not_ready_reason()) end
                     return
                 end
                 turn_by(180)
             end }
keys.action{ id = "where_am_i", name = "Which way you're facing, where the objective is, and your current quest task", group = "In the world",
             default = "up_arrow", run = where_am_i }   -- in menus: previous item

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
    default = "f5", run = function()
        beacon_on = not beacon_on
        speech.say("Objective beacon " .. (beacon_on and "on" or "off"))
    end,
}

dispatch.every(1000, function() if world.in_game() then refresh_route() end end, "route")
dispatch.every(100, function() beacon(); walk_tick(); face_tick() end, "beacon and autowalk")
-- If the game stops ticking the dispatcher mid-walk (a load), never leave the key held.
dispatch.every(500, function()
    if generation ~= state.generation then
        generation = state.generation
        if walking then stop("loading") end
        route, dest, trail, chosen, crumb, guide_path, mgr_path, quest_paths, nav_cache = {}, nil, {}, nil, nil, nil, nil, nil, nil
        source, last_quest_line, last_objective, arrived_at, face, straight_to = nil, nil, nil, nil, nil, nil
        next_mgr_search = 0
    end
    if walking and state.loading() then stop("loading") end
    if not walking then release() end
end, "autowalk key guard", true)

--- The game's path-navigation manager (its route to the objective), looked up afresh.
M.manager = manager

log("loaded")
return M
