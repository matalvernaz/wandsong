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
    -- Things to use: levers, pedestals, things to examine. Scanner only for now (no sound):
    -- which classes really hold what the game prompts for still needs checking in the dumps.
    { kind = "usable",  sound = nil,      every = 99,  range = 1500,
      classes = { "InteractiveObjectActor", "SimpleInteractObject", "WorldInteractObject" } },
}
-- Breakable props (pots, jugs, kitchenware) are interactive objects too, but they're scenery to
-- a player looking for what to use: they get their own category instead of crowding it.
local PROP = { kind = "prop", sound = nil, every = 99, range = 1500, classes = {} }
local PROP_CLASSES = { "BCProps", "KitchenItems", "Ceramic" }
-- Class-name fragments that mean "a person, not a foe" even under Enemy_Character.
local FRIENDLY = { "Student", "Ghost", "Companion", "Professor", "Vendor", "Merchant" }
-- Puzzle knights (the Gringotts vault) are enemies too, but until one comes alive it's a
-- statue to work out, not something to fight: no growl, no enemy tip, its own scanner name.
-- statues.lua plays the puzzle.
local STATUE = { kind = "statue", sound = nil, every = 99, range = 2500, classes = {} }
local STATUE_CLASS = "HogwartsProtector"

local SCAN_EVERY_MS = 600      -- one class query per this interval (~30 ms each)
local LISTENER_MS = 100
local GATE_MS = 250
local GATE_SETTLE_SECONDS = 5   -- elapsed time, independent of frame rate or dispatcher jitter

-- --- Gameplay gate --------------------------------------------------------------------

-- Game objects are never kept between ticks: touching one the game has since destroyed
-- crashes inside UE4SS, where nothing can catch it. We keep each object's path and look it
-- up again (StaticFindObject is a quick hash lookup) every time it's needed.
local ui_path, pawn_path, ctrl_path, ts_path
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
    if not valid(o) then return nil end
    -- An object the game has just destroyed can still come back from the lookup, its name
    -- already cleared (the Field Guide screen, 200 ms after the pause menu closed, Oct 6
    -- 10:15 PM: calling a function on it crashed the game). Its full name no longer matches.
    local now_path = path_of(o)
    if now_path and now_path ~= path then diag.trace("stale object " .. path); return nil end
    return o
end

local function call_bool(o, fn)
    local ok, v = pcall(function() return o[fn](o) end)
    if ok and type(v) == "boolean" then return v end
    return nil
end

local nearby = {}   -- key -> { obj, kind, sound, every, range, pitch, next_at }
local claimed_by, spoken_names, logged_names = {}, {}, {}

local function clear_world(reset_names)
    nearby = {}
    claimed_by = {}
    -- Names learned from subtitles stay: object paths are unique for the whole run, and the
    -- pause menu's screen load counts as a load (Fig was "Student" again after it, Oct 7).
    if reset_names then logged_names = {} end
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
local FUSE = require("files").runtime("world_active.flag", true)
local enabled = true
local sounds_on = true
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

-- Why the UI isn't plain gameplay (a menu, pause, a load, a modal tutorial), or nil when it
-- is. Asks only the long-lived UI manager and tutorial system, never the player or the world.
-- Asked afresh every time, never cached: menu code asks right before each widget read, and a
-- menu that has just closed must count as gameplay at once, not after the gate's next tick.
-- (Oct 6, 10:15 PM: the focus poller called a function on the Field Guide screen 200 ms after
-- the pause menu closed; the game had already freed it, and crashed.)
local UI_SETTLE = 0.75              -- seconds after any UI change in which widgets may still be dying
local ui_last_why, ui_changed_at = false, -10
local function ui_blocker()
    if state.spell_lesson then return "spell lesson" end
    local why
    local ui_manager = resolve(ui_path)
    if not ui_manager then ui_manager = find_live("UIManager"); ui_path = path_of(ui_manager) end
    if not ui_manager then
        why = "no UI manager"
    else
        state.paused = false
        for _, fn in ipairs({ "IsInPreGameplayState", "IsAsyncScreenLoadInProgress",
                              "GetInMenuTransition", "InPauseMode" }) do
            if call_bool(ui_manager, fn) == true then
                state.paused = fn == "InPauseMode" or fn == "GetInMenuTransition"
                if fn == "IsAsyncScreenLoadInProgress" then state.mark_loading(5) end
                why = fn
                break
            end
        end
        -- A modal tutorial is up (menus saw it): closed until the game's tutorial system no longer
        -- shows a modal screen. Only property reads and the class name; nothing is called.
        if not why and state.modal_since then
            diag.trace("gate: tutorial")
            local ts = resolve(ts_path)
            if not ts then ts = find_live("TutorialSystem"); ts_path = path_of(ts) end
            local modal = false
            pcall(function()
                local scr = ts.CurrentTutorialScreen
                if scr and scr:IsValid() then
                    local cn = scr:GetClass():GetFName():ToString()
                    modal = cn:find("Modal", 1, true) ~= nil and not cn:find("NonModal", 1, true)
                end
            end)
            if modal and os.clock() - state.modal_since < 600 then why = "tutorial" else state.modal_since = nil end
        end
        -- Quest failed or defeated (Oct 7, vault: arrows kept turning the camera and the review
        -- keys found nothing while "Try Again" waited). The UI manager holds that screen.
        if not why and state.fail_screen_since then
            diag.trace("gate: fail screen")
            local up = false
            pcall(function()
                local scr = ui_manager.MissionFailedScreen
                if scr and scr:IsValid() and scr.Visibility ~= 1 and scr.Visibility ~= 2 then up = scr:IsInViewport() == true end
            end)
            if up and os.clock() - state.fail_screen_since < 600 then why = "quest failed" else state.fail_screen_since = nil end
        end
    end
    if why ~= ui_last_why then ui_last_why, ui_changed_at = why, os.clock() end
    return why
end

local function gate_check()
    if not enabled then
        if fuse_blown and not state.loading() then
            fuse_blown = false
            dispatch.later(8000, function()
                speech.say("Wandsong world features are paused after the previous game stopped. Press " ..
                           keys.describe_combo(keys.combo_of("world_resume")) .. " to resume them.", true)
            end)
        end
        close_gate("switched off")
        -- Keep the pause and load state current (gameplay() asks the UI manager itself).
        diag.trace("gate: UI manager")
        ui_blocker()
        return
    end
    -- During a load nothing in the world may be touched (it's being torn down and rebuilt).
    if state.loading() then
        if in_game or pawn_path then log("loading: pausing the world layer") end
        close_gate("loading")
        clear_world(true)
        pawn_path, world_key = nil, nil
        return
    end
    -- Ask the long-lived UI manager first; only look at the player once it says "playing".
    diag.trace("gate: UI manager")
    local why = ui_blocker()
    if why then close_gate(why); return end
    diag.trace("gate: player")
    local pawn = resolve(pawn_path)
    if not pawn then pawn = find_live("Biped_Player"); pawn_path = path_of(pawn) end
    local blocked = not valid(pawn)
    if not blocked then
        local okc, cine = pcall(function() return pawn.InCinematic end)
        if okc then state.set_cinematic(cine) end
        if okc and cine == true then close_gate("cutscene"); return end
    end
    -- A new player object means a new world (level load, fast travel): drop everything held.
    local key
    pcall(function() key = pawn:GetAddress() end)
    if key and key ~= world_key then
        if world_key then
            log("player object changed: dropping cached objects")
            state.generation = state.generation + 1
            close_gate("player object changed")
        end
        clear_world(world_key ~= nil)
        world_key = key
    end
    if blocked then
        diag.event("world gate", "closed: no player")
        stable = 0
        if in_game then in_game = false; log("gate closed"); if audio then pcall(audio.stop_all) end end
    else
        if stable == 0 then stable = os.clock() end
        local elapsed = os.clock() - stable
        diag.event("world gate", in_game and "open" or string.format("settling %.1f s", elapsed))
        if not in_game and elapsed >= GATE_SETTLE_SECONDS then
            in_game = true
            fuse_set(true)
            log("gate open: in gameplay")
            if audio and sounds_on and not speech.is_muted() then audio.play_ui("chime", 0.4) end
            dispatch.later(2500, function()
                require("tips").once("welcome", require("guide").welcome)
            end, "welcome tip")
        end
    end
end

function M.in_game() return in_game and enabled and not state.loading() and not state.spell_lesson end
--- True whenever no menu is up: gameplay, a scene or dialogue, the gate still settling, or
--- world features off. Menu code must not walk widget trees then; in_game() alone is false in
--- all of those, and up arrow walking the HUD crashed the game twice (Oct 6). The UI manager
--- is asked now, so a menu that closed a moment ago already counts as gameplay.
function M.gameplay()
    if state.loading() then return false end
    return M.in_game() or ui_blocker() == nil
end
function M.sounds_enabled() return sounds_on and not speech.is_muted() end

--- True while the game is swapping screens (opening or closing a menu, loading one) and for a
--- moment after any such change: widget trees are being torn down then, and reading them
--- crashed the game (Oct 6, pause menu, twice).
function M.ui_busy()
    ui_blocker()
    if os.clock() - ui_changed_at < UI_SETTLE then return true end
    local ui = resolve(ui_path)
    if not ui then return false end
    return call_bool(ui, "GetInMenuTransition") == true or call_bool(ui, "IsAsyncScreenLoadInProgress") == true
end
--- False while world sounds (and everything that needs the world) are switched off.
function M.enabled() return enabled end
--- What to tell the player when a world feature can't run right now.
function M.not_ready_reason()
    if state.spell_lesson then
        return "A spell lesson is open. Press " .. keys.describe_combo(keys.combo_of("press")) .. " for tracing assistance."
    end
    if not enabled then
        return "World features are off, after the game stopped while they were running. Press " ..
               keys.describe_combo(keys.combo_of("world_resume")) .. " to resume them."
    end
    if state.modal_since then
        return "A tutorial is open. Hold space for a moment to continue, or find Continue with " ..
               keys.describe_combo(keys.combo_of("review_next")) .. " and press " ..
               keys.describe_combo(keys.combo_of("press")) .. "."
    end
    if state.cinematic then return "That works once this scene ends." end
    return "That works in the world, not in menus or scenes."
end

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
    if ok and type(x) == "number" and type(y) == "number" and type(z) == "number" then return x, y, z end
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
    if not in_game or state.loading() then return end
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
    -- UE4SS can return an invalid UObject wrapper for a missing property while possession
    -- changes. It is truthy, but cannot be used as an angle (seen entering Gringotts).
    if type(yaw) ~= "number" then
        ctrl_path = nil
        pcall(function() yaw = pawn.RootComponent.RelativeRotation.Yaw end)
    end
    if type(yaw) == "number" and yaw == yaw and math.abs(yaw) < math.huge then yaw_now = yaw end
    local r = math.rad(yaw_now)
    if audio then audio.listener(px, py, pz + 60, math.cos(r), math.sin(r), 0) end
end

-- --- Rotating scan ----------------------------------------------------------------------

local scan_list = {}
for _, cat in ipairs(CATEGORIES) do
    for _, cls in ipairs(cat.classes) do scan_list[#scan_list + 1] = { cls = cls, cat = cat } end
end
local scan_i = 0

local function friendly(cls_name)
    for _, frag in ipairs(FRIENDLY) do
        if cls_name:find(frag, 1, true) then return true end
    end
    return false
end

-- --- Names ------------------------------------------------------------------------------
-- What the scanner calls each thing, from the first source with real words: a character's
-- id (OverrideCharacterID, e.g. "ProfessorFig"), else its class name cleaned up
-- ("BP_OL_Chest_C" -> "Chest"), else the category's noun. Worked out once per actor, from
-- property reads only, and logged with its source so missing names can be fixed.
local KIND_NOUN = { person = "Person", enemy = "Enemy", beast = "Creature", chest = "Chest",
                    collect = "Collectible", door = "Door", usable = "Something to use", statue = "Statue",
                    prop = "Object" }
-- Class names that say nothing about the thing ("BP_INT_Interact_C" was read as "Interact").
local GENERIC = { ["Interact"] = true, ["Simple Interact Object"] = true, ["Interactive Object Actor"] = true,
                  ["World Interact Object"] = true, ["Something to use"] = true }

-- The level designer's own name for a placed thing ("Interact_VaultDoor" -> "Vault Door"),
-- unless it's an automatic one ("BP_INT_Interact_C_2147450000").
local function placed_name(actor)
    local p = path_of(actor)
    local leaf = p and p:match("[^.:]+$")
    if not leaf then return nil end
    leaf = leaf:gsub("_C_%d+$", ""):gsub("^BP_", ""):gsub("^INT_", ""):gsub("^Int_", "")
    leaf = leaf:gsub("^Interact_", ""):gsub("_Interact$", ""):gsub("^Interact$", "")
    return leaf ~= "" and leaf or nil
end
local NOISE_WORDS = { Default = true, Base = true, Character = true, Actor = true, Generic = true,
                      Phoenix = true, Int = true, Props = true, Prop = true, Items = true, Item = true }

local function humanize(id)
    local words = {}
    id = id:gsub("_C$", ""):gsub("%d+", " "):gsub("_", " ")
    id = id:gsub("(%l)(%u)", "%1 %2"):gsub("(%u)(%u%l)", "%1 %2")
    for w in id:gmatch("%S+") do
        -- Developer codes: short all-capitals tokens (BP, OL, BC, W, NPC).
        if not NOISE_WORDS[w] and not (w:match("^%u+$") and #w <= 3) then words[#words + 1] = w end
    end
    local out = table.concat(words, " ")
    if out == "" then return nil end
    return out:sub(1, 1):upper() .. out:sub(2)
end

-- Names learned from subtitles: the speaker's on-screen name ("Professor Fig") by object path.

--- A character's real name, learned when they speak (subtitles.lua). Renames them in the scan.
function M.name_actor(path, name)
    if not path or not name or name == "" or spoken_names[path] == name then return end
    spoken_names[path] = name
    log("name: " .. name .. " (from subtitles) for " .. path)
    for _, n in pairs(nearby) do
        if n.path == path then n.name, n.name_src = name, "subtitles" end
    end
end

local function name_of(actor, kind)
    local name, src
    pcall(function()
        local p = path_of(actor)
        if p and spoken_names[p] then name, src = spoken_names[p], "subtitles" end
    end)
    local function try(label, fn)
        if name then return end
        pcall(function()
            local id = fn()
            if id and id ~= "" and id ~= "None" then name, src = humanize(id), label end
        end)
    end
    try("character id", function() return actor.OverrideCharacterID:ToString() end)
    try("world id", function() return actor.DefaultWorldID:ToString() end)
    -- Characters keep their real identity (ProfessorFig) behind a getter. It's a call on the
    -- actor, made once per character, right after FindAllOf handed it over this tick.
    if kind == "person" or kind == "enemy" or kind == "beast" then
        try("GetCharacterID", function()
            local id = actor:GetCharacterID():ToString()
            if not logged_names["id:" .. tostring(id)] then
                logged_names["id:" .. tostring(id)] = true
                log("GetCharacterID gave " .. tostring(id))
            end
            return id
        end)
    end
    if not name then
        local cls = "?"
        pcall(function() cls = actor:GetClass():GetFName():ToString() end)
        local h = humanize(cls)
        if not h or GENERIC[h] then
            -- Generic class: the thing's own label, its beacon name, or the name it was placed with.
            try("label", function() return actor.Text:ToString() end)
            try("beacon name", function() return actor.BeaconName:ToString() end)
            try("placed as", function() return placed_name(actor) end)
            if name and GENERIC[name] then name, src = nil, nil end
        end
        -- A class name that only repeats the category ("Enemy") adds nothing.
        if not name and h and not GENERIC[h] and h:lower() ~= (KIND_NOUN[kind] or ""):lower() then
            name, src = h, "class " .. cls
        end
    end
    if not name then name, src = KIND_NOUN[kind] or "Something", "category" end
    if not logged_names[name .. src] then
        logged_names[name .. src] = true
        log("name: " .. name .. " (from " .. src .. ")")
    end
    return name, src
end

-- Things are kept for the scanner up to this far, even when they're too far to make a sound.
local KEEP_CM = 4000

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
            -- Stations are spots characters stand at to act something out: not for the player.
            if cat.kind == "usable" then
                local cn = a:GetClass():GetFName():ToString()
                if cn:find("Station", 1, true) then return end
                for _, frag in ipairs(PROP_CLASSES) do
                    if cn:find(frag, 1, true) then cat = PROP; break end
                end
            end
            local statue_class = false
            if cat.kind == "enemy" then
                local cn = a:GetClass():GetFName():ToString()
                statue_class = cn:find(STATUE_CLASS, 1, true) ~= nil
                if friendly(cn) then
                    cat = CATEGORIES[1]   -- a student or ghost: a person
                elseif statue_class and a.bHasBeenReleased ~= true then
                    cat = STATUE
                end
            end
            -- Earlier (more specific) categories win; don't let a later one relabel. A statue
            -- that comes alive does become an enemy.
            local prev = claimed_by[key]
            if prev and prev ~= cat.kind and prev ~= "person" and prev ~= "statue" and prev ~= "prop" then return end
            if d > math.max(cat.range * 1.5, KEEP_CM) then nearby[key] = nil; return end
            claimed_by[key] = cat.kind
            local n = nearby[key]
            if not n or n.kind ~= cat.kind then
                n = { next_at = os.clock() + math.random() * cat.every }
                if statue_class then
                    n.name, n.name_src = cat.kind == "statue" and "Knight statue" or "Stone knight", "statue"
                else
                    n.name, n.name_src = name_of(a, cat.kind)
                end
                nearby[key] = n
                if cat.kind == "enemy" then
                    require("tips").once("enemy", function()
                        local t = require("tips")
                        return "An enemy is nearby: the low growl. " .. t.key("face_target") .. " turns you to face " ..
                               "the nearest enemy, " .. require("bindings").spoken("AM_Stupefy", "Slash") ..
                               " casts, " .. require("bindings").spoken("LockOn", "Period") .. " locks on, and " ..
                               require("bindings").spoken("AM_Protego", "Q") .. " blocks."
                    end)
                end
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
    if not in_game or not audio or not M.sounds_enabled() or state.loading() then return end
    local now = os.clock()
    local order = {}
    for key, n in pairs(nearby) do if n.sound then order[#order + 1] = key end end   -- silent kinds: scanner only
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
local status_n = 0
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
    local driver, posts, freed, missed = dispatch.driver_stats()
    diag.log(string.format("dispatcher: %s, fallback posts %d, callbacks freed %d, missed %d", driver, posts, freed, missed))
    diag.log(string.format(
        "status: world %s%s%s, at %.0f %.0f %.0f facing %.0f, tracking %d (%s), lua %.0f KB, tasks %d queued %d timers",
        enabled and "on" or "OFF", in_game and " in game" or " gate shut", state.loading() and " loading" or "",
        px / 100, py / 100, pz / 100, yaw_now, total, table.concat(parts, " "),
        collectgarbage("count"), q, t))
    -- Every 30 s: a full collection, to tell garbage from memory that's really held, plus the
    -- Lua registry's length (UE4SS leaks references there) and who allocated what.
    status_n = status_n + 1
    if status_n % 3 == 0 then
        local before, t0 = collectgarbage("count"), os.clock()
        collectgarbage("collect")
        local freed, missed = dispatch.out_stats()
        diag.log(string.format("memory: %.0f KB before collect, %.0f KB live after (%.0f ms), registry length %d, out references freed %d, missed %d; allocated KB by task: %s",
            before, collectgarbage("count"), (os.clock() - t0) * 1000, rawlen(debug.getregistry()),
            freed, missed, dispatch.alloc_report()))
    end
end

--- The player's pawn, looked up fresh (nil outside gameplay). Use it within one task only.
function M.pawn()
    if not in_game or state.loading() then return nil end
    return resolve(pawn_path)
end

--- Everything the world scan is tracking, for the scanner: { key, path, kind, name,
--- name_src, dist (at the last scan, cm) }. Positions must be looked up fresh (M.locate).
function M.entries()
    local out = {}
    if not in_game or state.loading() then return out end
    for key, n in pairs(nearby) do
        if n.path then
            out[#out + 1] = { key = tostring(key), path = n.path, kind = n.kind, name = n.name,
                              name_src = n.name_src, dist = n.dist }
        end
    end
    return out
end

--- Last known player position (cm) and camera yaw (degrees), as the listener uses them.
function M.position() return px, py, pz, yaw_now end

--- Position of the nearest tracked thing of one kind ("person", ...) within max_cm, looked
--- up fresh; nil if there's none.
function M.nearest(kind, max_cm)
    if not in_game or state.loading() then return nil end
    local best
    for _, n in pairs(nearby) do
        if n.kind == kind and n.dist and n.dist <= max_cm and (not best or n.dist < best.dist) then best = n end
    end
    if not best then return nil end
    local p = M.locate(best.path)
    if not p then return nil end
    return p, best.path
end

--- An actor by its path, looked up fresh and checked to still be that object, during
--- gameplay only (nil otherwise). Use it within one task; never keep it.
function M.resolve(path)
    if not in_game or state.loading() then return nil end
    return resolve(path)
end

--- Current position of an actor by its path, or nil if it's gone. Nothing is kept.
function M.locate(path)
    if not in_game or state.loading() or not path then return nil end
    local x, y, z
    pcall(function()
        local obj = resolve(path)
        if obj then x, y, z = location(obj) end
    end)
    if not x then return nil end
    return { x, y, z }
end

--- Play one of the world sounds centred, for the sound legend.
function M.preview(name, pitch)
    if audio and not speech.is_muted() then return audio.play_ui(name, 0.8, pitch or 1.0) end
    return false
end

keys.action{
    id = "world_toggle", name = "Turn world sounds off or on", group = "In the world",
    default = "shift+f5",
    run = function()
        sounds_on = not sounds_on
        if not sounds_on and audio then audio.stop_all() end
        speech.say("World sounds " .. (sounds_on and "on" or "off"))
    end,
}
keys.action{
    id = "world_resume", name = "Resume world features after a crash", group = "In the world",
    default = "shift+f8", run = function()
        enabled, fuse_blown = true, false
        fuse_set(false)
        speech.say("World features enabled.")
    end,
}

dispatch.every(GATE_MS, gate_check, "world gate", true)
dispatch.every(LISTENER_MS, update_listener, "world listener")
dispatch.every(SCAN_EVERY_MS, scan_step, "world scan")
dispatch.every(250, ambient, "world ambient")
dispatch.every(10000, status, "world status")

log("loaded")
return M
