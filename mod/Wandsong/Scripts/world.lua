-- World: the zero-key layer. While the player is actually in gameplay, nearby things make
-- their own positioned sounds, without any key presses: doors knock, chests and collectibles
-- sparkle, people make a soft two-note sound, enemies growl more often. Sound follows the
-- camera, like any 3D game.
--
-- Rules followed here (from Hogwarts Legacy's own pitfalls):
--   * one FindAllOf per tick at most (each costs ~34 ms), rotating through the classes;
--   * nothing runs outside gameplay (menus, loading, pause, the intro flow);
--   * cached objects are re-validated before every use and dropped when the world changes.

local dispatch = require("dispatch")
local speech = require("speech")
local state = require("state")
local keys = require("keys")
local diag = require("diag")

local M = {}

local function log(s) print("[Wandsong world] " .. s .. "\n") end

local ok_audio, audio = pcall(require, "audio_bridge")
if ok_audio and type(audio) == "table" then
    local ok, msg = audio.init()
    log("audio: " .. tostring(msg))
    if not ok then audio = nil end
else
    log("audio unavailable: " .. tostring(audio))
    audio = nil
end

-- What makes a sound, most specific first; each actor is claimed by its first match.
-- Students, ghosts and companions inherit from the enemy class in this game, so they're
-- checked by name before the enemy category sees them.
local CATEGORIES = {
    { kind = "person",  sound = "person", every = 2.5, range = 1500, classes = { "BP_Student_C" } },
    { kind = "enemy",   sound = "enemy",  every = 1.2, range = 2500, classes = { "Enemy_Character" } },
    { kind = "beast",   sound = "person", every = 3.0, range = 1500, classes = { "Creature_Character" }, pitch = 0.7 },
    { kind = "chest",   sound = "item",   every = 3.0, range = 1500, classes = { "Container" }, pitch = 0.8 },
    { kind = "collect", sound = "item",   every = 2.5, range = 1500, classes = { "FieldGuidePage", "CooldownPickup" } },
    { kind = "door",    sound = "door",   every = 3.5, range = 1200, classes = { "Door" } },
    { kind = "person",  sound = "person", every = 2.5, range = 1500, classes = { "NPC_Character" } },
}
-- Class-name fragments that mean "a person, not a foe" even under Enemy_Character.
local FRIENDLY = { "Student", "Ghost", "Companion", "Professor", "Vendor", "Merchant" }

local SCAN_EVERY_MS = 600      -- one class query per this interval (~30 ms each)
local LISTENER_MS = 100
local GATE_MS = 1000
local GATE_STABLE = 5

-- --- Gameplay gate --------------------------------------------------------------------

-- Game objects are never kept between ticks: touching one the game has since destroyed
-- crashes inside UE4SS, where nothing can catch it. We keep each object's path and look it
-- up again (StaticFindObject is a quick hash lookup) every time it's needed.
local ui_path, pawn_path, ctrl_path
local in_game, stable, world_key = false, 0, nil

local function valid(o)
    if not o then return false end
    local ok, v = pcall(function() return o:IsValid() end)
    return ok and v
end

local function path_of(o)
    local full
    pcall(function() full = o:GetFullName() end)
    return full and full:match("^%S+%s+(.+)$") or nil
end

local function resolve(path)
    if not path then return nil end
    local o
    pcall(function() o = StaticFindObject(path) end)
    if valid(o) then return o end
    return nil
end

local function call_bool(o, fn)
    local ok, v = pcall(function() return o[fn](o) end)
    if ok and type(v) == "boolean" then return v end
    return nil
end

local nearby = {}   -- key -> { obj, kind, sound, every, range, pitch, next_at }

local function clear_world()
    nearby = {}
    ctrl_path = nil
    if audio then pcall(audio.stop_all) end
end

-- FindFirstOf can hand back the class's template object (Default__...) instead of the live
-- one; only accept a real instance.
local function find_live(cls)
    local o = FindFirstOf(cls)
    local name = ""
    pcall(function() name = o:GetFullName() end)
    if valid(o) and not name:find("Default__", 1, true) then return o end
    local all = FindAllOf(cls) or {}
    for _, a in ipairs(all) do
        local n = ""
        pcall(function() n = a:GetFullName() end)
        if valid(a) and not n:find("Default__", 1, true) then return a end
    end
    return nil
end

-- Crash fuse: a marker file exists exactly while world sounds are active in gameplay. If
-- the game crashes then, the marker survives, and the next launch starts with world sounds
-- off (and says so) instead of crashing again.
local FUSE = (function()
    local src = debug.getinfo(1, "S").source or ""
    local dir = src:gsub("^@", ""):gsub("/", "\\"):match("^(.*)\\[^\\]+$") or "."
    return dir .. "\\world_active.flag"
end)()
local enabled = true
local fuse_blown = false
do
    local f = io.open(FUSE, "r")
    if f then
        f:close()
        enabled, fuse_blown = false, true
        log("crash fuse: the game stopped while world sounds were on last time; starting with them off")
    end
end
local function fuse_set(on)
    if on then
        local f = io.open(FUSE, "w")
        if f then f:write("world sounds active\n"); f:close() end
    else
        os.remove(FUSE)
    end
end

local function close_gate(why)
    diag.event("world gate", "closed: " .. why)
    stable = 0
    if in_game then
        in_game = false
        fuse_set(false)
        log("gate closed (" .. why .. ")")
        if audio then pcall(audio.stop_all) end
    end
end

local function gate_check()
    if not enabled then
        if fuse_blown and not state.loading() then
            fuse_blown = false
            dispatch.later(8000, function()
                speech.say("Wandsong world sounds are off, because the game stopped while they " ..
                           "were running last time. Press " .. keys.describe_combo(keys.combo_of("world_toggle")) ..
                           " to turn them back on.", true)
            end)
        end
        close_gate("switched off")
        return
    end
    -- During a load nothing in the world may be touched (it's being torn down and rebuilt).
    if state.loading() then
        if in_game or pawn_path then log("loading: pausing the world layer") end
        close_gate("loading")
        clear_world()
        pawn_path = nil
        return
    end
    -- Ask the long-lived UI manager first; only look at the player once it says "playing".
    diag.trace("gate: UI manager")
    local ui_manager = resolve(ui_path)
    if not ui_manager then ui_manager = find_live("UIManager"); ui_path = path_of(ui_manager) end
    if not ui_manager then close_gate("no UI manager"); return end
    for _, fn in ipairs({ "IsInPreGameplayState", "IsAsyncScreenLoadInProgress",
                          "GetInMenuTransition", "InPauseMode" }) do
        if call_bool(ui_manager, fn) == true then
            if fn == "IsAsyncScreenLoadInProgress" then state.mark_loading(5) end
            close_gate(fn)
            return
        end
    end
    diag.trace("gate: player")
    local pawn = resolve(pawn_path)
    if not pawn then pawn = find_live("Biped_Player"); pawn_path = path_of(pawn) end
    local blocked = not valid(pawn)
    if not blocked then
        local okc, cine = pcall(function() return pawn.InCinematic end)
        if okc and cine == true then close_gate("cutscene"); return end
    end
    -- A new player object means a new world (level load, fast travel): drop everything held.
    local key
    pcall(function() key = pawn:GetAddress() end)
    if key and key ~= world_key then
        if world_key then log("player object changed: dropping cached objects") end
        world_key = key
        clear_world()
    end
    if blocked then
        diag.event("world gate", "closed: no player")
        stable = 0
        if in_game then in_game = false; log("gate closed"); if audio then pcall(audio.stop_all) end end
    else
        stable = stable + 1
        diag.event("world gate", in_game and "open" or ("settling " .. math.min(stable, GATE_STABLE)))
        if not in_game and stable >= GATE_STABLE then
            in_game = true
            fuse_set(true)
            log("gate open: in gameplay")
            if audio then audio.play_ui("chime", 0.4) end
        end
    end
end

function M.in_game() return in_game end

-- --- Reading actors ---------------------------------------------------------------------
-- Positions and rotations are read as plain reflected properties. Calling an actor's own
-- functions (K2_GetActorLocation and friends go through ProcessEvent) on something the game
-- is busy changing or destroying is what crashed the game three times.

-- World position of an actor's root (characters, chests and doors use an unattached root, so
-- its relative location is its world location).
local function location(actor)
    local ok, x, y, z = pcall(function()
        local v = actor.RootComponent.RelativeLocation
        return v.X, v.Y, v.Z
    end)
    if ok and type(x) == "number" then return x, y, z end
    return nil
end

-- --- Listener (follows the camera) ----------------------------------------------------

local px, py, pz = 0, 0, 0
local yaw_now = 0
local MOVE_MODES = { [0] = "none", "walking", "navmesh walking", "falling", "swimming", "flying", "custom" }
local function movement(pawn)
    local mode, custom
    pcall(function()
        local cm = pawn.CharacterMovement
        mode = cm.MovementMode
        custom = cm.CustomMovementMode
    end)
    if mode == nil then return nil end
    local s = MOVE_MODES[mode] or tostring(mode)
    if s == "custom" then s = s .. " " .. tostring(custom) end
    return s
end

local function update_listener()
    if not in_game or not audio or state.loading() then return end
    diag.trace("listener")
    local pawn = resolve(pawn_path)
    if not pawn then return end
    local x, y, z = location(pawn)
    if not x then return end
    local mv = movement(pawn)
    if mv then diag.event("movement", mv) end
    px, py, pz = x, y, z
    local yaw
    pcall(function()
        local controller = resolve(ctrl_path)
        if not controller then
            controller = pawn.Controller
            ctrl_path = path_of(controller)
        end
        yaw = controller.ControlRotation.Yaw
    end)
    if yaw == nil then pcall(function() yaw = pawn.RootComponent.RelativeRotation.Yaw end) end
    yaw_now = yaw or 0
    local r = math.rad(yaw or 0)
    audio.listener(px, py, pz + 60, math.cos(r), math.sin(r), 0)
end

-- --- Rotating scan ----------------------------------------------------------------------

local scan_list = {}
for _, cat in ipairs(CATEGORIES) do
    for _, cls in ipairs(cat.classes) do scan_list[#scan_list + 1] = { cls = cls, cat = cat } end
end
local scan_i = 0
local claimed_by = {}   -- actor address -> kind, for most-specific-first claiming

local function friendly(cls_name)
    for _, frag in ipairs(FRIENDLY) do
        if cls_name:find(frag, 1, true) then return true end
    end
    return false
end

local function scan_step()
    if not in_game or state.loading() then return end
    scan_i = scan_i % #scan_list + 1
    local entry = scan_list[scan_i]
    local t0 = os.clock()
    diag.trace("scan " .. entry.cls .. ": FindAllOf")
    local ok, actors = pcall(FindAllOf, entry.cls)
    if not ok or not actors then return end
    diag.trace("scan " .. entry.cls .. ": reading " .. #actors)
    local found = 0
    for i, a in ipairs(actors) do
        pcall(function()
            if not a:IsValid() then return end
            local key = a:GetAddress()
            local x, y, z = location(a)
            if not x then return end
            local dx, dy, dz = x - px, y - py, z - pz
            local d = math.sqrt(dx * dx + dy * dy + dz * dz)
            local cat = entry.cat
            if cat.kind == "enemy" and friendly(a:GetClass():GetFName():ToString()) then
                cat = CATEGORIES[1]   -- a student or ghost: a person
            end
            -- Earlier (more specific) categories win; don't let a later one relabel.
            local prev = claimed_by[key]
            if prev and prev ~= cat.kind and prev ~= "person" then return end
            if d > cat.range * 1.5 then nearby[key] = nil; return end
            claimed_by[key] = cat.kind
            local n = nearby[key]
            if not n then
                n = { next_at = os.clock() + math.random() * cat.every }
                nearby[key] = n
            end
            n.path, n.kind, n.sound, n.every, n.range, n.pitch = path_of(a), cat.kind, cat.sound, cat.every, cat.range, cat.pitch or 1.0
            n.dist = d
            found = found + 1
        end)
    end
    diag.trace("scan " .. entry.cls .. ": done")
    local ms = math.floor((os.clock() - t0) * 1000 + 0.5)
    if found > 0 or ms > 50 then log(string.format("scan %s: %d nearby (%d ms)", entry.cls, found, ms)) end
end

-- --- Ambient sounds ---------------------------------------------------------------------

-- Only the nearest few things make sounds, one at a time (after another access mod):
-- overlapping cues from everything in range were hard to tell apart.
local MAX_AUDIBLE = 8
local function ambient()
    if not in_game or not audio or speech.is_muted() or state.loading() then return end
    local now = os.clock()
    local order = {}
    for key, n in pairs(nearby) do order[#order + 1] = key end
    table.sort(order, function(a, b) return (nearby[a].dist or 1e9) < (nearby[b].dist or 1e9) end)
    local played = 0
    for rank, key in ipairs(order) do
        local n = nearby[key]
        if rank > MAX_AUDIBLE or played >= 1 then break end
        if now >= n.next_at then
            n.next_at = now + n.every
            diag.trace("ambient " .. n.kind .. " " .. tostring(n.path))
            local ok = pcall(function()
                local obj = resolve(n.path)
                if not obj then error("gone") end
                local x, y, z = location(obj)
                if not x then error("no position") end
                local dx, dy, dz = x - px, y - py, z - pz
                if math.sqrt(dx * dx + dy * dy + dz * dz) > n.range then return end
                audio.play(n.sound, x, y, z + 60, 0.7, n.pitch)
                local names = { person = "Person", enemy = "Enemy", beast = "Creature", chest = "Chest",
                                collect = "Collectible", door = "Door" }
                state.cue((names[n.kind] or n.kind) .. " " .. state.where(px, py, yaw_now, x, y))
                played = played + 1
            end)
            if not ok then nearby[key] = nil; claimed_by[key] = nil end
        end
    end
end

-- A snapshot every 10 seconds: where the player is and what the world layer is doing.
local function status()
    local counts = {}
    local total = 0
    for _, n in pairs(nearby) do
        counts[n.kind or "?"] = (counts[n.kind or "?"] or 0) + 1
        total = total + 1
    end
    local parts = {}
    for k, v in pairs(counts) do parts[#parts + 1] = k .. "=" .. v end
    table.sort(parts)
    local q, t = dispatch.counts()
    diag.log(string.format(
        "status: world %s%s%s, at %.0f %.0f %.0f facing %.0f, tracking %d (%s), lua %.0f KB, tasks %d queued %d timers",
        enabled and "on" or "OFF", in_game and " in game" or " gate shut", state.loading() and " loading" or "",
        px / 100, py / 100, pz / 100, yaw_now, total, table.concat(parts, " "),
        collectgarbage("count"), q, t))
end

--- The player's pawn, looked up fresh (nil outside gameplay). Use it within one task only.
function M.pawn()
    if not in_game or state.loading() then return nil end
    return resolve(pawn_path)
end

--- Last known player position (cm) and camera yaw (degrees), as the listener uses them.
function M.position() return px, py, pz, yaw_now end

--- Play one of the world sounds centred, for the sound legend.
function M.preview(name, pitch)
    if audio then return audio.play_ui(name, 0.8, pitch or 1.0) end
    return false
end

keys.action{
    id = "world_toggle", name = "Turn world sounds off or on", group = "In the world",
    default = "ctrl+shift+\\",
    run = function()
        enabled = not enabled
        if not enabled then close_gate("switched off"); nearby = {} end
        log("world sounds switched " .. (enabled and "on" or "off") .. " by the player")
        speech.say("World sounds " .. (enabled and "on" or "off"))
    end,
}

dispatch.every(GATE_MS, gate_check, "world gate")
dispatch.every(LISTENER_MS, update_listener, "world listener")
dispatch.every(SCAN_EVERY_MS, scan_step, "world scan")
dispatch.every(250, ambient, "world ambient")
dispatch.every(10000, status, "world status")

log("loaded")
return M
