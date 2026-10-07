-- Statues: the knight-statue puzzles of the Gringotts vault ("Discover the statue's secret",
-- later "Activate the statues"), made playable by ear.
--
-- How the game does it (BP_HogwartsProtector_C in the class dump): a puzzle knight kneels with
-- a reflection in the floor that turns toward a light (TargetActor), CurrentAngle easing
-- toward TargetAngle. The knight is aligned, and comes alive, when the light stands in its
-- AlignmentCorridor, a box in front of it, so that the reflection faces the way the knight
-- does (AlignToAngle). Sighted players see a white hint line along the corridor. With three
-- knights, the corridors cross at one spot that aligns them all.
--
-- What the mod does, with no keys: while a puzzle is active, a low chime sounds from the spot
-- to stand on (inside the corridor, or where the corridors cross), and the beacon's autowalk
-- (Shift+grave) leads there. Once your own wand light is the one the reflection follows,
-- ticks quicken as the reflection turns into line. A knight that only shows as a reflection
-- is mentioned once, with the Revelio key.
--
-- Rules kept: statues come from the world scan (no extra FindAllOf), are looked up by path
-- every time, and only their properties are read. Hooks (by event name, registered once at
-- startup) record an event name and a path, nothing else.

local dispatch, state, diag = require("dispatch"), require("state"), require("diag")
local speech, keys, world = require("speech"), require("keys"), require("world")
local bindings = require("bindings")

local M = {}
local function log(s) print("[Wandsong statues] " .. s .. "\n") end

local audio
do
    local ok, mod = pcall(require, "audio_bridge")
    if ok and type(mod) == "table" and mod.init() then audio = mod end
end

local CLASS = "HogwartsProtector"
local CHIME_EVERY = 1.2          -- seconds between chimes from the spot
local IN_LINE_INSET_CM = 15      -- stand this far inside a corridor's edge to count as in line
local ALIGNED_DEG = 5            -- reflection within this of the knight's angle: lined up
local HIDDEN_HINT_CM = 2000

local function num(v) return type(v) == "number" and v == v and math.abs(v) < 1e12 end
local function vec(v)
    local x, y, z
    pcall(function() x, y, z = v.X, v.Y, v.Z end)
    if num(x) and num(y) and num(z) then return { x, y, z } end
end
local function rot(r)
    local p, y, ro
    pcall(function() p, y, ro = r.Pitch, r.Yaw, r.Roll end)
    if num(p) and num(y) and num(ro) then return { p, y, ro } end
end
local function path_of(o)
    local full
    pcall(function() full = o:GetFullName() end)
    return full and full:match("^%S+%s+(.+)$") or nil
end
local function valid(o)
    if not o then return false end
    local ok, v = pcall(function() return o:IsValid() end)
    return ok and v == true
end
local function wrap(a) return (a + 180) % 360 - 180 end
local function dist2(a, b) return math.sqrt((a[1] - b[1]) ^ 2 + (a[2] - b[2]) ^ 2) end

-- --- Geometry: a component's world transform from its reflected relative transforms ------
-- Unreal's rotation matrix (FRotationMatrix): the X, Y and Z axes of a rotator.
local function axes(r)
    local p, y, ro = math.rad(r[1]), math.rad(r[2]), math.rad(r[3])
    local sp, cp, sy, cy, sr, cr = math.sin(p), math.cos(p), math.sin(y), math.cos(y), math.sin(ro), math.cos(ro)
    return { { cp * cy, cp * sy, sp },
             { sr * sp * cy - cr * sy, sr * sp * sy + cr * cy, -sr * cp },
             { -(cr * sp * cy + sr * sy), cy * sr - cr * sp * sy, cr * cp } }
end
local function turn(t, v)
    local a = t.ax
    return { v[1] * a[1][1] + v[2] * a[2][1] + v[3] * a[3][1],
             v[1] * a[1][2] + v[2] * a[2][2] + v[3] * a[3][2],
             v[1] * a[1][3] + v[2] * a[2][3] + v[3] * a[3][3] }
end
local function apply(t, v)
    local d = turn(t, { v[1] * t.scale[1], v[2] * t.scale[2], v[3] * t.scale[3] })
    return { t.loc[1] + d[1], t.loc[2] + d[2], t.loc[3] + d[3] }
end
local function relative(c)
    local l, r, s = vec(c.RelativeLocation), rot(c.RelativeRotation), vec(c.RelativeScale3D)
    if not l or not r then return nil end
    local t = { loc = l, ax = axes(r), scale = s or { 1, 1, 1 }, yaw = r[2] }
    pcall(function()
        t.abs_loc, t.abs_rot, t.abs_scale = c.bAbsoluteLocation == true, c.bAbsoluteRotation == true, c.bAbsoluteScale == true
    end)
    return t
end
--- World transform of a scene component: its relative transforms composed up the attachment
--- chain (property reads only). Socket offsets are not included.
local function world_of(c)
    local chain, cur = {}, c
    for _ = 1, 8 do
        local t
        pcall(function() t = relative(cur) end)
        if not t then return nil end
        chain[#chain + 1] = t
        local parent
        pcall(function() parent = cur.AttachParent end)
        if not valid(parent) then break end
        cur = parent
    end
    local w = chain[#chain]
    for i = #chain - 1, 1, -1 do
        local rel = chain[i]
        local n = { loc = apply(w, rel.loc),
                    ax = { turn(w, rel.ax[1]), turn(w, rel.ax[2]), turn(w, rel.ax[3]) },
                    scale = { w.scale[1] * rel.scale[1], w.scale[2] * rel.scale[2], w.scale[3] * rel.scale[3] } }
        if rel.abs_loc then n.loc = rel.loc end
        if rel.abs_rot then n.ax = rel.ax end
        if rel.abs_scale then n.scale = rel.scale end
        w = n
    end
    return w
end
M.world_of = world_of

-- The alignment corridor as a box: centre, axes and half sizes (cm).
local function corridor(statue)
    local box
    pcall(function() box = statue.AlignmentCorridor end)
    if not valid(box) then return nil end
    local w, e
    pcall(function() w = world_of(box); e = vec(box.BoxExtent) end)
    if not w or not e then return nil end
    return { c = w.loc, ax = w.ax,
             h = { math.abs(e[1] * w.scale[1]), math.abs(e[2] * w.scale[2]), math.abs(e[3] * w.scale[3]) } }
end

-- Inside the box's horizontal footprint, at least `inset` cm from its sides.
local function inside(cor, p, inset)
    local d = { p[1] - cor.c[1], p[2] - cor.c[2], p[3] - cor.c[3] }
    for i = 1, 2 do
        local a = cor.ax[i]
        local along = d[1] * a[1] + d[2] * a[2] + d[3] * a[3]
        if math.abs(along) > math.max(0, cor.h[i] - (inset or 0)) then return false end
    end
    return true
end
M.inside = inside

-- The corridor's long horizontal axis: a point on it and a unit direction (2D).
local function long_axis(cor)
    local i = cor.h[1] >= cor.h[2] and 1 or 2
    local a = cor.ax[i]
    local len = math.sqrt(a[1] ^ 2 + a[2] ^ 2)
    if len < 1e-3 then return nil end
    return { cor.c[1], cor.c[2] }, { a[1] / len, a[2] / len }, cor.h[i]
end

-- Where to stand for one knight: the corridor's centre, or, when the box sits on the knight
-- itself, a few metres out along it on the side the knight faces.
local function spot_for(s)
    local cor = s.cor
    if not cor then return nil end
    local c, dir, half = long_axis(cor)
    if not c then return nil end
    local root = s.root or cor.c
    if dist2(c, root) > 100 then return { c[1], c[2], cor.c[3] } end
    local r = math.rad(s.yaw or 0)
    local fx, fy = math.cos(r), math.sin(r)
    if dir[1] * fx + dir[2] * fy < 0 then dir = { -dir[1], -dir[2] } end
    local out = math.max(0, math.min(half - 50, 300))
    return { c[1] + dir[1] * out, c[2] + dir[2] * out, cor.c[3] }
end

-- Where several corridors cross: each pair of long axes is intersected, and the crossing
-- inside the most corridors wins.
local function crossing(list)
    local best, best_n
    for i = 1, #list - 1 do
        for j = i + 1, #list do
            local p1, d1 = long_axis(list[i].cor)
            local p2, d2 = long_axis(list[j].cor)
            if p1 and p2 then
                local cross = d1[1] * d2[2] - d1[2] * d2[1]
                if math.abs(cross) > 1e-3 then
                    local t = ((p2[1] - p1[1]) * d2[2] - (p2[2] - p1[2]) * d2[1]) / cross
                    local q = { p1[1] + d1[1] * t, p1[2] + d1[2] * t, (list[i].cor.c[3] + list[j].cor.c[3]) / 2 }
                    local n = 0
                    for _, s in ipairs(list) do if inside(s.cor, q, 0) then n = n + 1 end end
                    if not best_n or n > best_n then best, best_n = q, n end
                end
            end
        end
    end
    if best and best_n >= 2 then return best end
end
M.crossing = crossing

-- --- Reading the knights ----------------------------------------------------------------

local function read(path, pawn_path, px, py, pz)
    local o = world.resolve and world.resolve(path)
    if not o then return nil end
    local s = { path = path }
    pcall(function() s.active = o.bPuzzleActive == true end)
    pcall(function() s.released = o.bHasBeenReleased == true end)
    pcall(function() s.statue_visible = o.bStatueVisible == true end)
    pcall(function() s.reflection_visible = o.bReflectionVisible == true end)
    pcall(function() s.align_to = o.AlignToAngle end)
    pcall(function() s.target_angle = o.TargetAngle end)
    pcall(function() s.current = o.CurrentAngle end)
    pcall(function() s.root = vec(o.RootComponent.RelativeLocation) end)
    pcall(function() s.yaw = o.RootComponent.RelativeRotation.Yaw end)
    pcall(function() s.cor = corridor(o) end)
    pcall(function()
        local t = o.TargetActor
        if valid(t) then
            s.target = path_of(t)
            local w = world_of(t.RootComponent)
            if w then s.target_at = w.loc end
        end
    end)
    -- Whose light the reflection follows: the player's own, or someone else's (Fig's).
    s.mine = s.target ~= nil and (s.target == pawn_path
        or (s.target_at ~= nil and dist2(s.target_at, { px, py }) < 150 and math.abs(s.target_at[3] - pz) < 200))
    if num(s.current) and num(s.align_to) then s.off = math.abs(wrap(s.current - s.align_to)) end
    return s
end

local known = {}                 -- path -> { said_intro, said_hidden, was_active, released }
local puzzle = nil               -- { spot = {x,y,z}, list = {statues}, in_line, mine, off }
local generation = state.generation
local next_chime, next_tick, next_log = 0, 0, 0
local was_in_line, was_aligned = false, false

local function lumos_key() return bindings.spoken("AM_SpellButton1", "One") end
local function walk_key() return keys.describe_combo(keys.combo_of("autowalk")) end

local function intro(many)
    return (many and "Statue puzzle: each knight's reflection in the floor turns toward the light. " ..
        "Light Lumos with " .. lumos_key() .. " and stand where all the knights line up with their reflections. "
        or "Statue puzzle: the knight's reflection in the floor turns toward the light. " ..
        "Light Lumos with " .. lumos_key() .. " and stand where the knight lines up with its reflection. ") ..
        "A low chime marks the spot, and " .. walk_key() .. " walks you there."
end

local function sounds_ok()
    return audio and world.sounds_enabled and world.sounds_enabled() and not speech.is_muted()
end

local function snapshot(s, why)
    local function f(v) return num(v) and string.format("%.1f", v) or tostring(v) end
    local function p3(v) return v and string.format("%.0f %.0f %.0f", v[1], v[2], v[3]) or "?" end
    local cor = s.cor
    log(string.format("%s %s: active %s released %s statue %s reflection %s; angles align %s target %s current %s off %s; " ..
        "root %s yaw %s; light %s (%s) at %s; corridor %s", why, s.path:match("[^.:]+$") or s.path,
        tostring(s.active), tostring(s.released), tostring(s.statue_visible), tostring(s.reflection_visible),
        f(s.align_to), f(s.target_angle), f(s.current), f(s.off), p3(s.root), f(s.yaw),
        tostring(s.target), s.mine and "yours" or "not yours", p3(s.target_at),
        cor and string.format("centre %s half %.0f %.0f %.0f x-axis %.2f %.2f", p3(cor.c), cor.h[1], cor.h[2], cor.h[3],
            cor.ax[1][1], cor.ax[1][2]) or "none"))
end

local function tick()
    if generation ~= state.generation then
        generation = state.generation
        known, puzzle, was_in_line, was_aligned = {}, nil, false, false
    end
    if not world.in_game() then puzzle = nil; return end
    local px, py, pz = world.position()
    local pawn = world.pawn and world.pawn()
    local pawn_path = pawn and path_of(pawn)
    local active, hidden = {}, nil
    for _, e in ipairs(world.entries()) do
        if e.kind == "statue" or (e.path and e.path:find(CLASS, 1, true)) then
            local s = read(e.path, pawn_path, px, py, pz)
            if s then
                local k = known[s.path] or {}
                known[s.path] = k
                if s.active ~= k.was_active or s.statue_visible ~= k.was_visible then
                    k.was_active, k.was_visible = s.active, s.statue_visible
                    snapshot(s, "state")
                end
                if s.active and not s.released and s.cor then active[#active + 1] = s end
                if s.reflection_visible and not s.statue_visible and not s.released and s.root
                   and dist2(s.root, { px, py }) < HIDDEN_HINT_CM and not k.said_hidden then
                    hidden = hidden or { s = s, k = k }
                end
            end
        end
    end
    if hidden then
        hidden.k.said_hidden = true
        speech.say("Only a knight's reflection shows in the floor. Cast Revelio with " ..
            bindings.spoken("AM_Revelio", "R") .. " to reveal the knight.", true)
    end
    if #active == 0 then
        if puzzle then log("puzzle ended") end
        puzzle, was_in_line, was_aligned = nil, false, false
        return
    end
    local spot = #active > 1 and crossing(active) or nil
    if not spot then
        table.sort(active, function(a, b) return dist2(a.root or a.cor.c, { px, py }) < dist2(b.root or b.cor.c, { px, py }) end)
        spot = spot_for(active[1])
    end
    if not spot then return end
    -- Stand at your own height on that floor (the box's centre can be well above the ground).
    local cor1 = active[1].cor
    if math.abs(cor1.c[3] - pz) <= cor1.h[3] + 200 then spot[3] = pz end
    local me = { px, py, pz }
    local in_line, mine, off = true, true, 0
    for _, s in ipairs(active) do
        if not inside(s.cor, me, IN_LINE_INSET_CM) then in_line = false end
        if not s.mine then mine = false end
        off = math.max(off, s.off or 180)
    end
    puzzle = { spot = spot, list = active, in_line = in_line, mine = mine, off = off }
    -- Explained once per knight: a new set of knights (the next puzzle) is explained again.
    local untold = false
    for _, s in ipairs(active) do if not known[s.path].told then untold = true end end
    if untold then
        for _, s in ipairs(active) do known[s.path].told = true; snapshot(s, "puzzle") end
        log(string.format("spot %.0f %.0f %.0f for %d knight(s)", spot[1], spot[2], spot[3], #active))
        speech.say(intro(#active > 1), true)
    end
    local aligned = mine and off <= ALIGNED_DEG
    if in_line ~= was_in_line then
        was_in_line = in_line
        if in_line then
            speech.say((#active > 1 and "In line with the knights." or "In line with the knight.") ..
                (mine and " Hold your light still." or (" Light Lumos with " .. lumos_key() .. ".")))
        end
    end
    if aligned ~= was_aligned then
        was_aligned = aligned
        if aligned then speech.say("Lined up.") end
    end
    local now = os.clock()
    if now >= next_log then
        next_log = now + 2
        for _, s in ipairs(active) do snapshot(s, "watch") end
        log(string.format("player %.0f %.0f %.0f; in line %s, light yours %s, off %.1f", px, py, pz,
            tostring(in_line), tostring(mine), off))
    end
    if not sounds_ok() then return end
    if not in_line and now >= next_chime then
        next_chime = now + CHIME_EVERY
        audio.play("chime", spot[1], spot[2], spot[3] + 60, 0.7, 0.6)
        state.cue("Statue puzzle spot " .. state.where(px, py, select(4, world.position()), spot[1], spot[2]))
    end
    -- Parking-sensor ticks while your light leads the reflection: quicker and higher as it
    -- turns into line.
    if mine and now >= next_tick then
        local f = math.min(off, 90) / 90
        next_tick = now + 0.1 + f * 0.8
        audio.play_ui("tick", 0.45, 1.6 - f * 0.8)
    end
end

--- The spot to stand on while a statue puzzle is active: { x, y, z, name }, else nil.
function M.target()
    if not puzzle or not world.in_game() then return nil end
    local s = puzzle.spot
    return { s[1], s[2], s[3], name = #puzzle.list > 1 and "where the knights line up" or "where the knight lines up" }
end
--- True while the player stands in line with every active puzzle knight (this module says so
--- itself when it happens).
function M.in_line() return puzzle ~= nil and puzzle.in_line and world.in_game() end
--- What to say on reaching the spot without being in line by the corridor's measure.
function M.arrival_text()
    if puzzle and not puzzle.mine then return "At the spot. Light Lumos with " .. lumos_key() .. "." end
    return "At the spot."
end

-- --- Game events (logged; they confirm what the game decided) ----------------------------
local EVENTS = { "ToggleReflectionPuzzle", "SetupReflectionPuzzle", "ActivateStatue", "ToggleStatueState",
    "SignalForRelease", "Branch to Release", "Unmark Ready for Release", "StandingArrived",
    "ProtectorPuzzleComplete", "SetupProtegoTutorial", "ProtegoTutorialComplete", "GoParryEvent",
    "OnParryWindow", "OnParryWindowEnd", "OnHiddenObjectRevealed", "OnEndReveal", "OnBeginRevealFade",
    "OnHiddenObjectHinted", "SpawnComplete", "SetToStanding", "SetToKneeling", "DetermineAlignmentAngle" }
local pending = {}
for _, event in ipairs(EVENTS) do
    if type(RegisterCustomEvent) == "function" then
        local ok, err = pcall(RegisterCustomEvent, event, function(ctx)
            local p
            pcall(function() p = path_of(ctx:get()) end)
            if p and p:find(CLASS, 1, true) and #pending < 64 then
                pending[#pending + 1] = { event = event, path = p, at = os.clock(), generation = state.generation }
            end
        end)
        if not ok then log("hook failed " .. event .. ": " .. tostring(err)) end
    end
end
local function events()
    if #pending == 0 then return end
    local list = pending
    pending = {}
    for _, e in ipairs(list) do
        if e.generation == state.generation then
            log("event " .. e.event .. " " .. (e.path:match("[^.:]+$") or e.path))
        end
    end
end

dispatch.every(250, tick, "statue puzzle")
dispatch.every(200, events, "statue events")

log("loaded")
return M
