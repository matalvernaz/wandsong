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
local state = require("state")
local keys = require("keys")
local speech = require("speech")

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
-- Drop-off cues fire only when the ground ahead is missing on two checks in a row, by both
-- the visibility and the camera channel (the first version used one ray and fired every
-- second on real floors).
local LEDGE_CUES = true

-- Sixteen rays around the camera's facing. Each listens furthest straight ahead and least
-- behind; neighbouring hits are grouped into at most four wall regions (after another access mod's
-- radar), so a corridor is two sounds, not eight.
local RAYS = {}
for i = 0, 15 do
    local ang = (i * 22.5 + 180) % 360 - 180
    RAYS[#RAYS + 1] = { ang = ang, range = 170 + 280 * math.max(0, math.cos(math.rad(ang))) }
end

local kismet_path = "/Script/Engine.Default__KismetSystemLibrary"
local no_color = { R = 0, G = 0, B = 0, A = 0 }

local function kismet()
    local k
    pcall(function() k = StaticFindObject(kismet_path) end)
    return k
end

-- One collision ray. Returns the hit distance and point, or nil when nothing is in the way.
-- channel: 0 = Visibility (default), 1 = Camera.
local function ray(k, pawn, sx, sy, sz, ex, ey, ez, channel)
    local hit = {}
    -- call_out frees the registry reference UE4SS leaks for the hit table.
    local ok, blocked = dispatch.call_out(function()
        return k:LineTraceSingle(pawn, { X = sx, Y = sy, Z = sz }, { X = ex, Y = ey, Z = ez },
                                 channel or 0, false, {}, 0, hit, true, no_color, no_color, 0.0)
    end, hit)
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

local wall_regions = {}  -- current audible wall regions: { ang, d, x, y, z, misses }
local side_wall = {}     -- side ray (90 / -90) -> consecutive samples with a wall
local side_clear = {}    -- side ray -> consecutive samples without
local terrain   -- defined below
local MAX_REGIONS = 4
local MISS_TOLERANCE = 2

local function stop_walls()
    if audio then for i = 1, MAX_REGIONS do pcall(audio.stop, "wall" .. i) end end
    wall_regions = {}
end

local function norm(a) return (a + 180) % 360 - 180 end

-- Neighbouring rays that all hit become one wall region: its direction is the hits'
-- distance-weighted average and its distance the nearest hit.
local function cluster(hits)
    local n = #RAYS
    local first_gap
    for i = 1, n do if not hits[i] then first_gap = i; break end end
    local groups, group = {}, {}
    local function close_group()
        if #group == 0 then return end
        local sx, sy, wsum, best = 0, 0, 0, nil
        for _, h in ipairs(group) do
            local w = 1 / math.max(h.d, 1)
            local r = math.rad(h.ang)
            sx, sy, wsum = sx + math.cos(r) * w, sy + math.sin(r) * w, wsum + w
            if not best or h.d < best.d then best = h end
        end
        groups[#groups + 1] = { ang = math.deg(math.atan(sy, sx)), d = best.d, x = best.x, y = best.y, z = best.z,
                                width = #group, misses = 0 }
        group = {}
    end
    if not first_gap then
        for i = 1, n do group[#group + 1] = hits[i] end
        close_group()
        return groups
    end
    for k = 1, n do
        local i = (first_gap - 1 + k) % n + 1
        if hits[i] then group[#group + 1] = hits[i] else close_group() end
    end
    close_group()
    return groups
end

-- Match new regions to the previous ones (same side within 45 degrees) so a region keeps
-- its sound; a region that vanishes is kept for a couple of samples so walls don't flicker.
local function stabilise(regions)
    local out, used = {}, {}
    for _, r in ipairs(regions) do
        local best, diff = nil, 46
        for j, old in ipairs(wall_regions) do
            local dd = math.abs(norm(r.ang - old.ang))
            if not used[j] and dd < diff then best, diff = j, dd end
        end
        if best then used[best] = true end
        out[#out + 1] = r
    end
    for j, old in ipairs(wall_regions) do
        if not used[j] and old.misses < MISS_TOLERANCE then
            old.misses = old.misses + 1
            out[#out + 1] = old
        end
    end
    table.sort(out, function(a, b) return a.d < b.d end)
    while #out > MAX_REGIONS do table.remove(out) end
    return out
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
    local hits = {}
    for i, r in ipairs(RAYS) do
        local a = math.rad(yaw + r.ang)
        local ex, ey = px + math.cos(a) * r.range, py + math.sin(a) * r.range
        local d, hx, hy, hz = ray(k, pawn, px, py, sz, ex, ey, sz)
        if d then hits[i] = { ang = r.ang, d = d, range = r.range, x = hx, y = hy, z = hz } end

        -- A side wall that has ended while walking: an opening on that side.
        if r.ang == 90 or r.ang == -90 then
            if d then
                side_wall[i], side_clear[i] = (side_wall[i] or 0) + 1, 0
            else
                side_clear[i] = (side_clear[i] or 0) + 1
                if side_clear[i] == 2 and (side_wall[i] or 0) >= 3 and moving then
                    audio.play("opening", px + math.cos(a) * 150, py + math.sin(a) * 150, sz, 0.8, 1.0)
                    state.cue("Opening on your " .. (r.ang > 0 and "right" or "left"))
                    diag.trace("opening " .. (r.ang > 0 and "right" or "left"))
                end
                if side_clear[i] >= 2 then side_wall[i] = 0 end
            end
        end
    end

    wall_regions = stabilise(cluster(hits))
    for i = 1, MAX_REGIONS do
        local w = wall_regions[i]
        if w then
            local range = 450
            for _, r in ipairs(RAYS) do if math.abs(norm(r.ang - w.ang)) <= 12 then range = r.range end end
            local near = 1 - math.min(1, w.d / range)
            audio.loop("wall" .. i, "wall", w.x, w.y, w.z, 0.12 + 0.55 * near * near, 1.0)
        else
            pcall(audio.stop, "wall" .. i)
        end
    end

    terrain(k, pawn, px, py, pz, yaw)
end

-- --- Jumps, climbs and drop-offs ahead ------------------------------------------------------
-- Every 0.4 s, a few rays straight ahead (the way you're moving, or the camera's way when
-- standing): knee, waist and head height 1.2 m out, and down from above whatever was hit.
--   knee blocked, waist clear              -> something low: jump or vault (hop sound)
--   knee and waist blocked, top 1.1-3 m up -> a ledge you can climb (rising notes)
--   no ground ahead, twice in a row        -> a drop-off (falling notes)
-- Each cue plays from where the thing is, and once per spot; a tick follows when it's
-- within 15 degrees of where the camera faces, so you know you're lined up.
local AHEAD_CM = 120
local next_terrain = 0
local last_cue = {}          -- kind -> { x, y, at }
local drop_seen = 0

local function cue_once(kind, x, y, z, sound, pitch, text, yaw, px, py)
    local last = last_cue[kind]
    -- Once per spot: walking along a cliff edge mustn't repeat the cue every couple of metres.
    if last and os.clock() - last.at < 8 and math.sqrt((x - last.x) ^ 2 + (y - last.y) ^ 2) < 800 then return end
    last_cue[kind] = { x = x, y = y, at = os.clock() }
    audio.play(sound, x, y, z, 0.8, pitch or 1.0)
    state.cue(text)
    -- The first time each one comes up, say what it means.
    require("tips").once("terrain_" .. kind, text .. ". " .. ({
        hop = "That two-note hop means something low ahead you can jump over.",
        climb = "Those rising notes mean a ledge you can climb.",
        drop = "Those falling notes mean the ground drops away ahead.",
    })[kind] .. " " .. require("tips").key("what_was_that") .. " names the last sounds.")
    local off = math.abs(norm(math.deg(math.atan(y - py, x - px)) - yaw))
    if off <= 15 then dispatch.later(250, function() audio.play_ui("tick", 0.35) end, "lined up tick") end
    diag.event("terrain", text)
end

function terrain(k, pawn, px, py, pz, yaw)
    local now = os.clock()
    if now < next_terrain then return end
    next_terrain = now + 0.4
    local cm = pawn.CharacterMovement
    local vx, vy = vec(cm, "Velocity")
    local heading = math.rad(yaw)
    if vx and (vx * vx + vy * vy) > 40 * 40 then heading = math.atan(vy, vx) end
    local cx, cy = math.cos(heading), math.sin(heading)
    local ax, ay = px + cx * AHEAD_CM, py + cy * AHEAD_CM
    local half = 90
    pcall(function() half = pawn.RootComponent.CapsuleHalfHeight end)
    local feet = pz - half
    diag.trace("terrain rays")

    local knee = ray(k, pawn, px, py, feet + 45, ax, ay, feet + 45)
    local waist = ray(k, pawn, px, py, feet + 110, ax, ay, feet + 110)
    if knee and not waist then
        local hx, hy = px + cx * knee, py + cy * knee
        local top_d, _, _, top_z = ray(k, pawn, hx + cx * 30, hy + cy * 30, feet + 110, hx + cx * 30, hy + cy * 30, feet)
        local h = top_z and (top_z - feet) or 50
        cue_once("hop", hx, hy, feet + h, "hop", 1.0,
                 string.format("Low obstacle ahead, %d centimetres high: space jumps over it", math.floor(h / 10 + 0.5) * 10),
                 yaw, px, py)
        drop_seen = 0
        return
    end
    if knee and waist then
        local d = math.min(knee, waist)
        local hx, hy = px + cx * (d + 30), py + cy * (d + 30)
        local head = ray(k, pawn, px, py, feet + 330, hx, hy, feet + 330)
        if not head then
            local top_d, _, _, top_z = ray(k, pawn, hx, hy, feet + 330, hx, hy, feet)
            local h = top_d and top_z and (top_z - feet) or nil
            if h and h > 100 and h <= 300 then
                cue_once("climb", hx, hy, top_z, "climb", 1.0,
                         string.format("Ledge ahead, %.1f metres up: walk into it and press space to climb", h / 100),
                         yaw, px, py)
            end
        end
        drop_seen = 0
        return
    end
    -- Nothing in the way: is there ground ahead?
    local d, _, _, hz = ray(k, pawn, ax, ay, feet + 50, ax, ay, feet - 600)
    if not d then d, _, _, hz = ray(k, pawn, ax, ay, feet + 50, ax, ay, feet - 600, 1) end
    local drop = d and (feet - hz) or 600
    if drop > 180 then drop_seen = drop_seen + 1 else drop_seen = 0 end
    diag.event("ledge", string.format("%s: feet z %.0f, hit %s", drop > 180 and "drop" or "floor", feet,
        d and string.format("%.0f cm down", feet - hz) or "nothing"))
    if LEDGE_CUES and drop_seen >= 2 and moving then
        cue_once("drop", ax, ay, feet, "ledge", drop > 500 and 0.8 or 1.0,
                 drop >= 600 and "Big drop ahead, more than 6 metres"
                             or string.format("Drop-off ahead, about %d metres", math.max(2, math.floor(drop / 100 + 0.5))),
                 yaw, px, py)
    end
end

-- --- "What was that?" -------------------------------------------------------------------

local function what_was_that()
    local parts = {}
    local now = os.clock()
    for _, c in ipairs(state.cues) do
        if now - c.at <= 6 and #parts < 3 then parts[#parts + 1] = c.text end
    end
    if #parts == 0 then parts[1] = "No sounds in the last few seconds" end
    local walls_list = {}
    for _, w in ipairs(wall_regions) do
        local a = (w.ang + 360) % 360
        local side = ({ "ahead", "ahead right", "right", "behind right", "behind", "behind left", "left", "ahead left" })
                     [math.floor((a + 22.5) / 45) % 8 + 1]
        local m = math.floor(w.d / 100 + 0.5)
        walls_list[#walls_list + 1] = side .. (m <= 1 and " close" or (" " .. m .. " metres"))
    end
    local s = table.concat(parts, ". ") .. ". "
    s = s .. (#walls_list > 0 and ("Walls: " .. table.concat(walls_list, ", ")) or "No walls near")
    speech.say(s)
end

keys.action{
    id = "what_was_that", name = "What was that sound? Names recent sounds and nearby walls",
    group = "In the world", default = "`", run = what_was_that,
}

-- --- Status -----------------------------------------------------------------------------

local function status()
    local n = #wall_regions
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
