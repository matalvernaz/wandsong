-- AI walk: when the key-driven autowalk is stuck, an AI controller takes over the player's
-- character and walks it along the game's navigation mesh, then hands it straight back.
--
-- OFF until it has been checked once in the game: it only runs while the file
-- ai_walk_enabled.txt exists in the mod folder (tools/probe_ai_walk.lua is the first check:
-- spawn, possess, hand back and destroy, without moving). A blind player left without control
-- of their character by an unverified possession is the one outcome to rule out.
--
-- This calls functions on world objects, a deliberate exception like the teleport: only on
-- the player's own long-lived character, on the player's controller, and on the AI controller
-- this module spawns (looked up by its path; it lives until this module destroys it).
-- Every step is its own logged, pcall'd function. The hand-back runs in a fixed order on
-- every way out (arrival, stuck, timeout, scene, menu, a movement key): stop the character,
-- stop and unpossess the AI controller, give the character back to the player's controller,
-- destroy the AI controller, put back the walk speed and capsule if they changed.
-- A map load ends it without a hand-back: the world (controllers included) is rebuilt then,
-- and nothing of the old one is looked up. A load mark in the same world (a menu's screen
-- loading) only delays the hand-back until objects may be touched again.

local dispatch, state, diag = require("dispatch"), require("state"), require("diag")
local speech, keys, world = require("speech"), require("keys"), require("world")
local bindings = require("bindings")
local files = require("files")

local M = {}
local function log(s) print("[Wandsong ai walk] " .. s .. "\n") end

local FLAG = files.runtime("ai_walk_enabled.txt")
local ARRIVE_CM = 120
local TIMEOUT = 40          -- seconds
local NO_PROGRESS = 4       -- seconds without moving half a metre: stuck
local GIVE_UP_HEIGHT = 250

local walk = nil            -- { pawn_path, pc_path, ai_path, dest, name, started, world, ... }
local owed = nil            -- { w, why, said }: a hand-back waiting for a load in the same world

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
-- Only for the long-lived objects this module works with (the player's character and
-- controller) and the controller it spawned itself, never for world things in general.
local function resolve(path)
    if not path then return nil end
    local o
    pcall(function() o = StaticFindObject(path) end)
    if not valid(o) or path_of(o) ~= path then return nil end
    return o
end
local function step(label, fn)
    diag.trace("ai walk: " .. label)
    local ok, a = pcall(fn)
    log(label .. (ok and " ok" or (" failed: " .. tostring(a))))
    return ok, a
end
local function dist(a, b)
    return math.sqrt((a[1] - b[1]) ^ 2 + (a[2] - b[2]) ^ 2), math.abs(a[3] - b[3])
end

function M.enabled()
    local f = io.open(FLAG, "r")
    if f then f:close(); return true end
    return false
end
function M.active() return walk ~= nil or owed ~= nil end

-- The hand-back, in a fixed order, every step attempted whatever failed before it.
-- Returns true once the player's controller holds the character again.
local function hand_back(w, why)
    local pawn = resolve(w.pawn_path)
    if not pawn then
        -- The character itself is gone (defeated, or the world changing): the game decides what
        -- holds the next one. Still remove the AI controller if it's there.
        local ai = w.ai_path and resolve(w.ai_path)
        if ai then step("destroy the AI controller", function() ai:K2_DestroyActor() end) end
        log("handed back (" .. why .. "): the character is gone; nothing to hand back")
        return true
    end
    if pawn then step("stop the character", function() pawn.CharacterMovement:StopMovementImmediately() end) end
    local ai = w.ai_path and resolve(w.ai_path)
    if ai then
        step("stop the AI controller", function() ai:StopMovement() end)
        step("unpossess", function() ai:UnPossess() end)
    end
    local pc = resolve(w.pc_path)
    if pc and pawn then step("give the character back", function() pc:Possess(pawn) end) end
    if ai then step("destroy the AI controller", function() ai:K2_DestroyActor() end) end
    if pawn and w.saved then
        step("restore walk speed", function()
            local cm = pawn.CharacterMovement
            if w.saved.max_walk and cm.MaxWalkSpeed ~= w.saved.max_walk then cm.MaxWalkSpeed = w.saved.max_walk end
        end)
        step("restore capsule", function()
            local cap = pawn.RootComponent
            if w.saved.radius and (cap.CapsuleRadius ~= w.saved.radius or cap.CapsuleHalfHeight ~= w.saved.half) then
                cap:SetCapsuleSize(w.saved.radius, w.saved.half, true)
            end
        end)
    end
    local back = false
    pcall(function() back = path_of(resolve(w.pawn_path).Controller) == w.pc_path end)
    log("handed back (" .. why .. "): " .. (back and "the player has control" or "control NOT confirmed"))
    return back
end

local function finish(why, said)
    local w = walk
    if not w then return end
    walk = nil
    -- A map load rebuilt the world, controllers included: nothing to hand back, nothing to touch.
    if w.world ~= state.world then log("ended by a map load (" .. why .. ")"); return end
    -- The same world, but objects may not be touched now: hand back once they may (the watch).
    if state.loading() or not dispatch.ticking() then
        owed = { w = w, why = why, said = said }
        log("hand-back waits for the load to settle (" .. why .. ")")
        return
    end
    local back = hand_back(w, why)
    if not back then
        -- One more try a moment later; then say so plainly.
        dispatch.later(500, function()
            if hand_back(w, why .. ", second try") then return end
            speech.say("The game may not have given you your character back. Open the pause menu and load your last save if you can't move.")
        end, "ai walk second hand-back")
    end
    if said then speech.say(said) end
end

--- Stop an AI walk (a movement key, a menu, the walk key again).
function M.stop(why) finish(why or "stopped", "AI walk stopped.") end

--- Walk to dest ({x, y, z}) with an AI controller. Returns true if it started (or was
--- already there). Never starts when switched off, outside gameplay, or while one runs.
function M.start(dest, name)
    if walk or owed or not M.enabled() or not world.in_game() or state.loading() or not dest then return false end
    local pawn = world.pawn and world.pawn()
    if not pawn then return false end
    local w = { dest = dest, name = name or "the objective", started = os.clock(), world = state.world }
    w.pawn_path = path_of(pawn)
    step("find the player's controller", function()
        local pc = pawn.Controller
        assert(valid(pc), "no controller")
        -- Only ever hand back to a player controller (never to a leftover AI controller).
        local full = pc:GetFullName()
        assert(full:find("PlayerController", 1, true), "the character isn't held by the player's controller")
        w.pc_path = path_of(pc)
    end)
    if not w.pawn_path or not w.pc_path then return false end
    step("remember speed and capsule", function()
        w.saved = { max_walk = pawn.CharacterMovement.MaxWalkSpeed }
        w.saved.radius, w.saved.half = pawn.RootComponent.CapsuleRadius, pawn.RootComponent.CapsuleHalfHeight
    end)
    step("spawn an AI controller", function()
        local statics = StaticFindObject("/Script/Engine.Default__GameplayStatics")
        local class = StaticFindObject("/Script/AIModule.AIController")
        assert(valid(statics) and valid(class), "spawn functions unavailable")
        local px, py, pz = world.position()
        local at = { Rotation = { X = 0, Y = 0, Z = 0, W = 1 }, Translation = { X = px, Y = py, Z = pz },
                     Scale3D = { X = 1, Y = 1, Z = 1 } }
        local ai = statics:BeginDeferredActorSpawnFromClass(pawn, class, at, 1, nil)
        assert(valid(ai), "nothing spawned")
        ai = statics:FinishSpawningActor(ai, at)
        assert(valid(ai), "spawn not finished")
        w.ai_path = path_of(ai)
    end)
    if not w.ai_path then hand_back(w, "could not spawn"); return false end
    walk = w   -- from here on, every way out hands the character back
    local possessed = step("possess", function()
        local ai = resolve(w.ai_path)
        assert(ai, "controller gone")
        ai:Possess(pawn)
        assert(path_of(pawn.Controller) == w.ai_path, "possession didn't take")
    end)
    if not possessed then finish("could not possess", nil); return false end
    local ok, result = step("move", function()
        local ai = resolve(w.ai_path)
        return ai:MoveToLocation({ X = dest[1], Y = dest[2], Z = dest[3] }, ARRIVE_CM / 2, true, true, true, false, nil, true)
    end)
    if not ok or result == 0 then finish("no path", nil); return false end
    if result == 1 then finish("already there", "Arrived.") return true end
    w.last_progress, w.last_pos = os.clock(), { world.position() }
    speech.say("Stuck, so the game's own pathfinding is walking you to " .. w.name .. ". Any movement key takes back control.")
    return true
end

--- What the check in tools/probe_ai_walk.lua runs: spawn, possess, hand back and destroy,
--- without moving. Works even while switched off (it's how it gets switched on).
function M.probe()
    if walk then return "an AI walk is running" end
    if not world.in_game() then return "not in gameplay" end
    local pawn = world.pawn and world.pawn()
    if not pawn then return "no player character" end
    local w = { dest = { world.position() }, name = "probe", started = os.clock(), world = state.world }
    w.pawn_path = path_of(pawn)
    pcall(function()
        local pc = pawn.Controller
        if valid(pc) and pc:GetFullName():find("PlayerController", 1, true) then w.pc_path = path_of(pc) end
    end)
    if not w.pc_path then return "the character isn't held by the player's controller" end
    pcall(function()
        w.saved = { max_walk = pawn.CharacterMovement.MaxWalkSpeed }
        w.saved.radius, w.saved.half = pawn.RootComponent.CapsuleRadius, pawn.RootComponent.CapsuleHalfHeight
    end)
    local report = {}
    local function note(label, ok, err) report[#report + 1] = label .. ": " .. (ok and "ok" or ("FAILED " .. tostring(err))) end
    local ok, err = step("probe spawn", function()
        local statics = StaticFindObject("/Script/Engine.Default__GameplayStatics")
        local class = StaticFindObject("/Script/AIModule.AIController")
        local px, py, pz = world.position()
        local at = { Rotation = { X = 0, Y = 0, Z = 0, W = 1 }, Translation = { X = px, Y = py, Z = pz },
                     Scale3D = { X = 1, Y = 1, Z = 1 } }
        local ai = statics:BeginDeferredActorSpawnFromClass(pawn, class, at, 1, nil)
        ai = statics:FinishSpawningActor(ai, at)
        assert(valid(ai), "nothing spawned")
        w.ai_path = path_of(ai)
    end)
    note("spawn", ok, err)
    if w.ai_path then
        ok, err = step("probe possess", function()
            resolve(w.ai_path):Possess(pawn)
            assert(path_of(pawn.Controller) == w.ai_path, "possession didn't take")
        end)
        note("possess", ok, err)
    end
    local back = hand_back(w, "probe")
    note("hand back", back, "the player's controller doesn't hold the character")
    return table.concat(report, "; ")
end

-- Watching the walk.
dispatch.every(200, function()
    if owed then
        local o = owed
        if o.w.world ~= state.world then owed = nil; log("ended by a map load (" .. o.why .. ")"); return end
        if state.loading() or not dispatch.ticking() then return end
        owed, walk = nil, o.w
        finish(o.why, o.said)
        return
    end
    local w = walk
    if not w then return end
    if w.world ~= state.world then
        walk = nil   -- a map load rebuilt the world, controllers included; nothing to hand back
        log("ended by a map load")
        return
    end
    -- A load mark in the same world (a menu's screen loading), or no game ticks (perhaps inside
    -- a map load, where handing the character back could crash): wait, the clock for getting
    -- stuck stopped. A map load ends the walk above.
    if state.loading() or not dispatch.ticking() then
        w.last_progress, w.last_pos = os.clock(), { world.position() }
        return
    end
    if not world.in_game() then finish("the game paused or a scene started", nil); return end
    local now = os.clock()
    if now - w.started > TIMEOUT then finish("took too long", "The AI walk took too long and stopped.") return end
    local px, py, pz = world.position()
    local d, dz = dist({ px, py, pz }, w.dest)
    if d < ARRIVE_CM and dz < GIVE_UP_HEIGHT then finish("arrived", "Arrived at " .. w.name .. ".") return end
    local moved = dist({ px, py, pz }, w.last_pos)
    if moved > 50 then w.last_progress, w.last_pos = now, { px, py, pz } end
    if now - w.last_progress > NO_PROGRESS then
        finish("no progress", string.format("The AI walk got stuck too, %d metres from %s.", math.floor(d / 100 + 0.5), w.name))
        return
    end
    local status
    pcall(function() status = resolve(w.ai_path):GetMoveStatus() end)
    if status == 0 and now - w.started > 1.5 then
        finish("the game's path ended", d < 300 and ("Arrived near " .. w.name .. ".")
            or string.format("The AI walk stopped %d metres from %s.", math.floor(d / 100 + 0.5), w.name))
    end
end, "ai walk", true)

-- Any movement key takes back control at once.
local STOP_KEYS = { A = true, S = true, D = true, W = true, SPACE = true, ESCAPE = true }
keys.observe(function(_, key)
    if not walk or os.clock() - walk.started < 0.5 then return end
    if STOP_KEYS[key] or bindings.movement_vk(Key[key]) then dispatch.run(function() M.stop("you moved") end, "ai walk stop") end
end)

log("loaded (" .. (M.enabled() and "ON: ai_walk_enabled.txt is present" or "off") .. ")")
return M
