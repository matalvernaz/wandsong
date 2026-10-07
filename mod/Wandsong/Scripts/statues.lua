-- Statues: the knight-statue puzzles of the Gringotts vault ("Discover the statue's secret",
-- later "Activate the statues"), as an audio puzzle.
--
-- The game (BP_HogwartsProtector_C, measured in the vault on Oct 7): a puzzle knight kneels
-- with a reflection in the floor. The reflection turns toward the light it follows
-- (TargetActor): TargetAngle is the compass bearing from the knight to that light, and
-- CurrentAngle eases toward it. The knight itself faces AlignToAngle. With your own light in
-- front of the knight, inside its alignment corridor (a box about 1 to 7 m out and a metre
-- wide), the reflection matches the knight and the knight comes alive. Sighted players watch
-- the reflection turn; in the three-knight version they also see white hint lines.
--
-- The audio version gives the same information, and no more:
--   * each visible knight sounds its note now and then, from where it kneels;
--   * while your own light leads a knight's reflection, the reflection's note follows the
--     knight's: the further the reflection is turned from the way the knight faces, the
--     further its pitch from the knight's (above when it's turned to the knight's right,
--     below when to its left). In unison: lined up.
--   * where the game shows a knight's hint line, standing on that line adds a soft hum;
--   * a knight that shows only as a reflection is described once, and the scanner (Home on
--     a knight) says which way the knight and its reflection face.
-- No spot is marked and nothing walks you there: finding it is the puzzle (Matt, Oct 7).
--
-- Rules kept: knights come from the world scan (no extra FindAllOf), are looked up by path
-- every time, and only their properties are read. Hooks (by event name, registered once at
-- startup) record an event name and a path, nothing else.

local dispatch, state, diag = require("dispatch"), require("state"), require("diag")
local speech, world = require("speech"), require("world")

local M = {}
local function log(s) print("[Wandsong statues] " .. s .. "\n") end

local audio
do
    local ok, mod = pcall(require, "audio_bridge")
    if ok and type(mod) == "table" and mod.init() then audio = mod end
end

local CLASS = "HogwartsProtector"
local CYCLE = 1.4                -- seconds between one knight's notes
local REFLECTION_AFTER = 0.2     -- the reflection's note this long after the knight's
local ALIGNED_DEG = 3            -- reflection within this of the knight's facing: lined up
local NEAR_CM = 2500             -- knights further than this stay quiet
local SETTLE = 3                 -- seconds of uninterrupted play before describing anything
local BASES = { 1.0, 1.26, 1.5 } -- each knight's own note: a major chord across three knights

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
    local t = { loc = l, ax = axes(r), scale = s or { 1, 1, 1 } }
    pcall(function()
        t.abs_loc, t.abs_rot, t.abs_scale = c.bAbsoluteLocation == true, c.bAbsoluteRotation == true, c.bAbsoluteScale == true
    end)
    return t
end
--- World transform of a scene component: its relative transforms composed up the attachment
--- chain (property reads only). Socket offsets are not included. The vault knights are scaled
--- (0.75), which this accounts for.
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
local function corridor(knight)
    local box
    pcall(function() box = knight.AlignmentCorridor end)
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

-- --- Reading the knights ----------------------------------------------------------------

-- Only a knight that is a puzzle right now is read beyond its two flags: the fight after the
-- first puzzle spawns knights of the same class, and reading deeper into them (their light,
-- its components) as they spawned and shattered crashed the game (Oct 7, 09:16). Each step
-- leaves a breadcrumb in trace.log.
local function read(path, pawn_path)
    diag.trace("statue lookup " .. path)
    local o = world.resolve and world.resolve(path)
    if not o then return nil end
    local s = { path = path }
    diag.trace("statue flags " .. path)
    pcall(function() s.active = o.bPuzzleActive == true end)
    pcall(function() s.released = o.bHasBeenReleased == true end)
    if not s.active or s.released then return s end
    pcall(function() s.statue_visible = o.bStatueVisible == true end)
    pcall(function() s.reflection_visible = o.bReflectionVisible == true end)
    pcall(function() s.align_to = o.AlignToAngle end)
    pcall(function() s.target_angle = o.TargetAngle end)
    pcall(function() s.current = o.CurrentAngle end)
    pcall(function() s.hint = o.VFX_HintLine_Alpha end)
    diag.trace("statue root " .. path)
    pcall(function() s.root = vec(o.RootComponent.RelativeLocation) end)
    pcall(function() s.yaw = o.RootComponent.RelativeRotation.Yaw end)
    -- Whose light the reflection follows: the player's own (TargetActor is the player), or
    -- someone else's (Fig's). Only the path is compared; nothing of that actor is read.
    diag.trace("statue light " .. path)
    pcall(function()
        local t = o.TargetActor
        if valid(t) then s.target = path_of(t) end
    end)
    if num(s.hint) and s.hint > 0.05 then
        diag.trace("statue corridor " .. path)
        pcall(function() s.cor = corridor(o) end)
    end
    s.mine = s.target ~= nil and s.target == pawn_path
    if num(s.current) and num(s.align_to) then s.off = wrap(s.current - s.align_to) end
    s.visible = (s.statue_visible or s.reflection_visible) and s.active and not s.released
    return s
end

local known = {}                 -- path -> { base, next_at, said_hidden, said_intro, aligned, gone }
-- Knights that have come alive are never looked up again this load: Fig shatters them seconds
-- later, and the world scan may still list one as a statue until its next pass.
local gone = {}
local knights = {}               -- the visible puzzle knights at the last check
local generation = state.generation
local playing_since = nil        -- uninterrupted gameplay since
local next_log = 0
local loops = {}                 -- hum loops playing, by id

local function sounds_ok()
    return audio and world.sounds_enabled and world.sounds_enabled() and not speech.is_muted()
end

local function stop_loops()
    if audio then for id in pairs(loops) do pcall(audio.stop, id) end end
    loops = {}
end

local function snapshot(s, why)
    local function f(v) return num(v) and string.format("%.1f", v) or tostring(v) end
    local function p3(v) return v and string.format("%.0f %.0f %.0f", v[1], v[2], v[3]) or "?" end
    log(string.format("%s %s: active %s released %s statue %s reflection %s; angles align %s target %s current %s off %s; " ..
        "root %s yaw %s; light %s (%s); hint line %s", why, s.path:match("[^.:]+$") or s.path,
        tostring(s.active), tostring(s.released), tostring(s.statue_visible), tostring(s.reflection_visible),
        f(s.align_to), f(s.target_angle), f(s.current), f(s.off), p3(s.root), f(s.yaw),
        tostring(s.target), s.mine and "yours" or "not yours", f(s.hint)))
end

local function tick()
    if generation ~= state.generation then
        generation = state.generation
        known, knights, playing_since, gone = {}, {}, nil, {}
        stop_loops()
    end
    if not world.in_game() then
        knights, playing_since = {}, nil
        stop_loops()
        return
    end
    playing_since = playing_since or os.clock()
    local settled = os.clock() - playing_since >= SETTLE
    local px, py, pz = world.position()
    local me = { px, py, pz }
    local pawn = world.pawn and world.pawn()
    local pawn_path = pawn and path_of(pawn)
    local now = os.clock()
    local seen, hums = {}, {}
    for _, e in ipairs(world.entries and world.entries() or {}) do
        -- Only what the world scan, reading fresh objects, found to be a live puzzle knight.
        -- Looking up every knight of the class (the fight's too, as they shattered) crashed
        -- the game twice (Oct 7, 09:16 and 09:26): a destroyed object can come back from the
        -- lookup, and UE4SS 3.0.1's IsValid then dereferences freed memory.
        if e.kind == "statue" and not gone[e.path] then
            local s = read(e.path, pawn_path)
            if s and s.released then gone[s.path] = true end
            if s and not s.released then
                local k = known[s.path]
                if not k then
                    local n = 0
                    for _ in pairs(known) do n = n + 1 end
                    k = { base = BASES[n % #BASES + 1], next_at = now + (n % #BASES) * CYCLE / #BASES }
                    known[s.path] = k
                end
                if s.visible ~= k.was_visible or s.statue_visible ~= k.was_statue then
                    k.was_visible, k.was_statue = s.visible, s.statue_visible
                    snapshot(s, "state")
                end
                if s.visible and s.root and dist2(s.root, me) < NEAR_CM then
                    seen[#seen + 1] = s
                    s.k = k
                    if s.cor and inside(s.cor, me, 10) and s.mine then hums[s.path] = s end
                end
            end
        end
    end
    knights = seen
    -- Descriptions wait for play to settle and the dialogue to pause (not over a cutscene's
    -- last lines, nor over Fig).
    local ok_sub, subtitles = pcall(require, "subtitles")
    local quiet = not (ok_sub and type(subtitles) == "table" and subtitles.quiet_for) or subtitles.quiet_for(1.5)
    if settled and quiet then
        for _, s in ipairs(seen) do
            local k = s.k
            if s.reflection_visible and not s.statue_visible and not k.said_hidden then
                k.said_hidden = true
                speech.say("Only a knight's reflection shows in the floor. No knight stands above it.", true)
            elseif s.statue_visible and not k.said_intro then
                k.said_intro, k.said_hidden = true, true
                speech.say("A stone knight kneels here, with its reflection in the floor. You hear the knight's note. " ..
                    "While your own light leads the reflection, the reflection's note follows the knight's, " ..
                    "and the two sound as one when the reflection lines up with the knight.", true)
            end
        end
    end
    -- "Lined up" once per alignment, as a sighted player would see it: from where the light
    -- is now (TargetAngle), not the eased reflection, which sweeps through the knight's angle
    -- while you circle it.
    for _, s in ipairs(seen) do
        local k = s.k
        -- ...and only within the corridor's reach (1.1 to 7.1 m out for the vault's knights):
        -- in line but further off, the game does nothing.
        local reach = s.root and dist2(s.root, me) or 0
        local aligned = s.mine and num(s.target_angle) and num(s.align_to)
            and math.abs(wrap(s.target_angle - s.align_to)) <= ALIGNED_DEG and reach >= 80 and reach <= 800
        if aligned and not k.aligned then speech.say(#seen > 1 and "That knight is lined up." or "Lined up.") end
        k.aligned = aligned
    end
    if now >= next_log and #seen > 0 then
        next_log = now + 3
        for _, s in ipairs(seen) do snapshot(s, "watch") end
        log(string.format("player %.0f %.0f %.0f", px, py, pz))
    end
    if not sounds_ok() then stop_loops(); return end
    for _, s in ipairs(seen) do
        local k = s.k
        if now >= k.next_at then
            k.next_at = now + CYCLE
            local x, y, z = s.root[1], s.root[2], s.root[3] + 60
            audio.play("note", x, y, z, 0.6, k.base)
            if s.mine and s.off then
                -- Up to an octave away when the reflection faces the opposite way.
                local pitch = k.base * 2 ^ (s.off / 180)
                dispatch.later(REFLECTION_AFTER * 1000, function()
                    if sounds_ok() and world.in_game() then audio.play("note", x, y, z, 0.5, pitch) end
                end, "statue reflection note")
            end
        end
    end
    -- Hint lines: standing on one (with your light) hums the knight's note.
    for id in pairs(loops) do
        if not hums[id:sub(7)] then pcall(audio.stop, id); loops[id] = nil end
    end
    for path, s in pairs(hums) do
        local id = "statue" .. path
        audio.loop(id, "hum", s.root[1], s.root[2], s.root[3] + 60, 0.25, s.k.base)
        loops[id] = true
    end
end

--- What a sighted player sees of a knight: which way it faces, and its reflection.
function M.describe(path)
    if not world.in_game() or gone[path] then return nil end
    local px, py, pz = world.position()
    local pawn = world.pawn and world.pawn()
    local s = read(path, pawn and path_of(pawn))
    if not s or not num(s.yaw) then return nil end
    if s.released then return "standing, alive" end
    if not s.statue_visible and s.reflection_visible then
        return "only its reflection shows, facing " .. state.compass(s.current or s.yaw)
    end
    local t = "kneeling, facing " .. state.compass(s.yaw)
    if s.reflection_visible and num(s.current) then
        t = t .. (s.off and math.abs(s.off) <= ALIGNED_DEG and "; its reflection faces the same way"
            or ("; its reflection faces " .. state.compass(s.current)))
    end
    return t
end

-- --- Game events (logged: they show what the game decided) -------------------------------
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
                pending[#pending + 1] = { event = event, path = p, generation = state.generation }
            end
            if p and (event == "StandingArrived" or event == "Branch to Release" or event == "SignalForRelease") then
                gone[p] = true
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

-- Home on a knight in the scanner says what a glance would show.
local ok_scanner, scanner = pcall(require, "scanner")
if ok_scanner and type(scanner) == "table" and scanner.details then scanner.details.statue = M.describe end

dispatch.every(250, tick, "statue puzzle")
dispatch.every(200, events, "statue events")

log("loaded")
return M
