-- Surroundings: what's around the player's body, conveyed without keys (Swamp style).
--
--   Footsteps   a soft step every stride while walking, so moving is audible; a heavier
--               thump on landing.
--   Blocked     pushing to move but not moving: a low bump.
--   Walls       eight collision rays around the camera's facing; each direction with a wall
--               in range plays a soft rushing loop from the wall itself, louder as it nears.
--               Silence means open space.
--   Openings    a side wall that ends while walking (a doorway, a corridor branch): a short
--               airy rush from that side.
--   Drop-offs   the ground ahead falling away (a ledge, a stairwell edge): a falling
--               three-note cue from where it starts.
--
-- Rays go through KismetSystemLibrary's LineTraceSingle on its class default object, which
-- lives for the whole session; actor functions are never called. Everything runs only while
-- the world layer's gate is open (in gameplay, not paused, not in a cutscene, not loading).

local dispatch = require("dispatch")
local diag = require("diag")
local world = require("world")

local M = {}

local function log(s) print("[Wandsong surroundings] " .. s .. "\n") end

local audio
do
    local ok, mod = pcall(require, "audio_bridge")
    if ok and type(mod) == "table" and mod.init() then audio = mod end
end

local TICK_MS = 100
local WALL_MS = 200
local STRIDE_CM = 75           -- one footstep per this much walking
local CHEST_CM = 30            -- rays start this far above the capsule centre

-- Ray directions relative to the camera, and how far each one listens for walls.
local RAYS = {
    { ang = 0,    range = 450 }, { ang = 45,   range = 300 }, { ang = -45, range = 300 },
    { ang = 90,   range = 220 }, { ang = -90,  range = 220 },
    { ang = 135,  range = 150 }, { ang = -135, range = 150 }, { ang = 180, range = 150 },
}

local kismet_path = "/Script/Engine.Default__KismetSystemLibrary"
local no_color = { R = 0, G = 0, B = 0, A = 0 }

local function kismet()
    local k
    pcall(function() k = StaticFindObject(kismet_path) end)
    return k
end

-- One collision ray. Returns the hit distance and point, or nil when nothing is in the way.
local function ray(k, pawn, sx, sy, sz, ex, ey, ez)
    local hit = {}
    local ok, blocked = pcall(function()
        return k:LineTraceSingle(pawn, { X = sx, Y = sy, Z = sz }, { X = ex, Y = ey, Z = ez },
                                 0, false, {}, 0, hit, true, no_color, no_color, 0.0)
    end)
    if not (ok and blocked) then return nil end
    local d, x, y, z
    pcall(function()
        d = hit.Distance
        local p = hit.ImpactPoint
        x, y, z = p.X, p.Y, p.Z
    end)
    if type(d) ~= "number" then return nil end
    return d, x, y, z
end

local function vec(o, field)
    local x, y, z
    pcall(function()
        local v = o[field]
        x, y, z = v.X, v.Y, v.Z
    end)
    return x, y, z
end

-- --- Footsteps, landing, blocked --------------------------------------------------------

local last_x, last_y, stride = nil, nil, 0
local last_mode = nil
local stuck_ticks, next_bump = 0, 0
local moving = false
local stats = { speed = 0, accel = 0 }

local function body()
    local pawn = world.pawn()
    if not pawn or not audio then last_x = nil; return end
    local px, py, pz = world.position()
    local cm
    pcall(function() cm = pawn.CharacterMovement end)
    if not cm then return end
    local mode
    pcall(function() mode = cm.MovementMode end)
    local vx, vy = vec(cm, "Velocity")
    local ax, ay = vec(cm, "Acceleration")
    local speed = (vx and math.sqrt(vx * vx + vy * vy)) or 0
    local accel = (ax and math.sqrt(ax * ax + ay * ay)) or 0
    stats.speed, stats.accel = speed, accel
    moving = speed > 40

    -- Landing: falling, then back on the ground.
    if last_mode == 3 and mode == 1 then audio.play_ui("land", 0.6) end
    last_mode = mode

    -- Footsteps by distance walked (teleports and fast travel don't count).
    if last_x and mode == 1 then
        local d = math.sqrt((px - last_x) ^ 2 + (py - last_y) ^ 2)
        if d < 300 then stride = stride + d end
        if stride >= STRIDE_CM then
            stride = stride % STRIDE_CM
            audio.play_ui("step", 0.35, 0.9 + math.random() * 0.2)
        end
    end
    last_x, last_y = px, py

    -- Blocked: trying to move (input acceleration) but barely moving, for a few ticks.
    if mode == 1 and accel > 100 and speed < 25 then
        stuck_ticks = stuck_ticks + 1
        local now = os.clock()
        if stuck_ticks >= 3 and now >= next_bump then
            audio.play_ui("step_blocked", 0.6)
            next_bump = now + 0.5
            diag.trace("blocked")
        end
    else
        stuck_ticks = 0
    end
end

-- --- Walls, openings, drop-offs ---------------------------------------------------------

local wall_on = {}       -- ray index -> true while its loop plays
local was_wall = {}      -- ray index -> consecutive samples with a wall
local was_clear = {}     -- ray index -> consecutive samples without
local next_ledge = 0

local function stop_walls()
    if not audio then return end
    for i in pairs(wall_on) do pcall(audio.stop, "wall" .. i) end
    wall_on = {}
end

local function walls()
    local pawn = world.pawn()
    if not pawn or not audio then stop_walls(); return end
    local k = kismet()
    if not k then return end
    local px, py, pz, yaw = world.position()
    local mode
    pcall(function() mode = pawn.CharacterMovement.MovementMode end)
    if mode ~= 1 then stop_walls(); return end   -- walking only (not climbing, swimming, falling)
    local sz = pz + CHEST_CM

    diag.trace("walls: rays")
    for i, r in ipairs(RAYS) do
        local a = math.rad(yaw + r.ang)
        local ex, ey = px + math.cos(a) * r.range, py + math.sin(a) * r.range
        local d, hx, hy, hz = ray(k, pawn, px, py, sz, ex, ey, sz)
        if d then
            was_wall[i], was_clear[i] = (was_wall[i] or 0) + 1, 0
            local near = 1 - math.min(1, d / r.range)
            audio.loop("wall" .. i, "wall", hx, hy, hz, 0.12 + 0.55 * near * near, 1.0)
            wall_on[i] = true
        else
            was_clear[i] = (was_clear[i] or 0) + 1
            -- Keep a wall through one missed sample so it doesn't flicker.
            if wall_on[i] and was_clear[i] >= 2 then
                pcall(audio.stop, "wall" .. i)
                wall_on[i] = nil
            end
            -- A side wall that has ended while walking: an opening on that side.
            if (r.ang == 90 or r.ang == -90) and was_clear[i] == 2 and (was_wall[i] or 0) >= 3 and moving then
                audio.play("opening", px + math.cos(a) * 150, py + math.sin(a) * 150, sz, 0.8, 1.0)
                diag.trace("opening " .. (r.ang > 0 and "right" or "left"))
            end
            if was_clear[i] >= 2 then was_wall[i] = 0 end
        end
    end

    -- Drop-off ahead, in the direction of travel (or the camera's, standing still).
    local now = os.clock()
    if now < next_ledge then return end
    local cm = pawn.CharacterMovement
    local vx, vy = vec(cm, "Velocity")
    local heading = math.rad(yaw)
    if vx and (vx * vx + vy * vy) > 40 * 40 then heading = math.atan(vy, vx) end
    local ax, ay = px + math.cos(heading) * 150, py + math.sin(heading) * 150
    if ray(k, pawn, px, py, sz, ax, ay, sz) then return end   -- a wall, not a ledge
    local half = 90
    pcall(function() half = pawn.RootComponent.CapsuleHalfHeight end)
    local feet = pz - half
    diag.trace("walls: ledge ray")
    local d, _, _, hz = ray(k, pawn, ax, ay, sz, ax, ay, feet - 600)
    local drop = d and (feet - hz) or 600
    if drop > 180 then
        audio.play("ledge", ax, ay, feet, 0.8, drop > 500 and 0.8 or 1.0)
        next_ledge = now + 0.8
        diag.event("ledge", string.format("drop of %.1f m ahead", drop / 100))
    else
        diag.event("ledge", "none")
    end
end

-- --- Status -----------------------------------------------------------------------------

local function status()
    local n = 0
    for _ in pairs(wall_on) do n = n + 1 end
    log(string.format("speed %.0f, input %.0f, walls %d, moving %s", stats.speed, stats.accel, n, tostring(moving)))
end

dispatch.every(TICK_MS, function()
    if not world.in_game() then stop_walls(); last_x = nil; return end
    body()
end, "body sounds")
dispatch.every(WALL_MS, function()
    if not world.in_game() then stop_walls(); return end
    walls()
end, "walls")
dispatch.every(10000, function() if world.in_game() then status() end end, "surroundings status")

log("loaded" .. (audio and "" or " (no audio)"))
return M
