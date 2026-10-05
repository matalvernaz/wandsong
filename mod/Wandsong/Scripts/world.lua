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

local function close_gate(why)
    stable = 0
    if in_game then
        in_game = false
        log("gate closed (" .. why .. ")")
        if audio then pcall(audio.stop_all) end
    end
end

local function gate_check()
    -- During a load nothing in the world may be touched (it's being torn down and rebuilt).
    if state.loading() then
        if in_game or pawn_path then log("loading: pausing the world layer") end
        close_gate("loading")
        clear_world()
        pawn_path = nil
        return
    end
    -- Ask the long-lived UI manager first; only look at the player once it says "playing".
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
    local pawn = resolve(pawn_path)
    if not pawn then pawn = find_live("Biped_Player"); pawn_path = path_of(pawn) end
    local blocked = not valid(pawn)
    -- A new player object means a new world (level load, fast travel): drop everything held.
    local key
    pcall(function() key = pawn:GetAddress() end)
    if key and key ~= world_key then
        if world_key then log("player object changed: dropping cached objects") end
        world_key = key
        clear_world()
    end
    if blocked then
        stable = 0
        if in_game then in_game = false; log("gate closed"); if audio then pcall(audio.stop_all) end end
    else
        stable = stable + 1
        if not in_game and stable >= GATE_STABLE then
            in_game = true
            log("gate open: in gameplay")
            if audio then audio.play_ui("chime", 0.4) end
        end
    end
end

function M.in_game() return in_game end

-- --- Listener (follows the camera) ----------------------------------------------------

local px, py, pz = 0, 0, 0
local function update_listener()
    if not in_game or not audio or state.loading() then return end
    local pawn = resolve(pawn_path)
    if not pawn then return end
    local ok = pcall(function()
        local loc = pawn:K2_GetActorLocation()
        px, py, pz = loc.X, loc.Y, loc.Z
    end)
    if not ok then return end
    local yaw
    pcall(function()
        local controller = resolve(ctrl_path)
        if not controller then
            controller = pawn:GetController()
            ctrl_path = path_of(controller)
        end
        yaw = controller:GetControlRotation().Yaw
    end)
    if yaw == nil then pcall(function() yaw = pawn:K2_GetActorRotation().Yaw end) end
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
    local ok, actors = pcall(FindAllOf, entry.cls)
    if not ok or not actors then return end
    local found = 0
    for _, a in ipairs(actors) do
        pcall(function()
            if not a:IsValid() then return end
            local key = a:GetAddress()
            local loc = a:K2_GetActorLocation()
            local dx, dy, dz = loc.X - px, loc.Y - py, loc.Z - pz
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
            found = found + 1
        end)
    end
    local ms = math.floor((os.clock() - t0) * 1000 + 0.5)
    if found > 0 or ms > 50 then log(string.format("scan %s: %d nearby (%d ms)", entry.cls, found, ms)) end
end

-- --- Ambient sounds ---------------------------------------------------------------------

local MAX_PER_TICK = 3
local function ambient()
    if not in_game or not audio or speech.is_muted() or state.loading() then return end
    local now = os.clock()
    local played = 0
    for key, n in pairs(nearby) do
        if played >= MAX_PER_TICK then break end
        if now >= n.next_at then
            n.next_at = now + n.every
            local ok = pcall(function()
                local obj = resolve(n.path)
                if not obj then error("gone") end
                local loc = obj:K2_GetActorLocation()
                local dx, dy, dz = loc.X - px, loc.Y - py, loc.Z - pz
                if math.sqrt(dx * dx + dy * dy + dz * dz) > n.range then return end
                audio.play(n.sound, loc.X, loc.Y, loc.Z + 60, 0.7, n.pitch)
                played = played + 1
            end)
            if not ok then nearby[key] = nil; claimed_by[key] = nil end
        end
    end
end

dispatch.every(GATE_MS, gate_check)
dispatch.every(LISTENER_MS, update_listener)
dispatch.every(SCAN_EVERY_MS, scan_step)
dispatch.every(250, ambient)

log("loaded")
return M
