-- World: the zero-key layer. While the player is actually in gameplay, nearby things make
-- their own positioned sounds, without any key presses: doors knock, chests and collectibles
-- sparkle, people make a soft two-note sound, enemies growl more often. Sound follows the
-- camera, like any 3D game.
--
-- Rules followed here (from Hogwarts Legacy's own pitfalls):
--   * one FindAllOf per tick at most (each costs ~30 ms);
--   * nothing runs outside gameplay (menus, loading, pause, the intro flow);
--   * world things are known only from snapshots taken during a scan pass: every property any
--     module needs is read from the fresh objects in that same tick, and nothing looks a world
--     actor up again between passes (see "Scanning" below). Only long-lived objects (the
--     player, the UI manager, the tutorial system) are looked up by path.
--   * the one exception, off unless lifetime_enabled.txt is in the mod folder: the objects a
--     pass found are held, and the nearest are read again between passes, each only after the
--     game's own deletion record says it hasn't been deleted since (see "Holding" below).

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

-- The deletion record (lifetime_bridge.dll), only when lifetime_enabled.txt exists. Started on
-- the game thread by the first dispatcher tick; nothing is held until it has started.
local lifetime, holding = nil, false
do
    local f = io.open(require("files").runtime("lifetime_enabled.txt"), "r")
    if f then
        f:close()
        local ok, mod = pcall(require, "lifetime_bridge")
        if ok and type(mod) == "table" then lifetime = mod else log("lifetime: unavailable: " .. tostring(mod)) end
    end
end

-- What each kind of thing sounds like, how often, and from how far.
local KINDS = {
    person  = { sound = "person", every = 2.5, range = 1500 },
    enemy   = { sound = "enemy",  every = 1.2, range = 2500 },
    beast   = { sound = "person", every = 3.0, range = 1500, pitch = 0.7 },
    -- Puzzle knights (the Gringotts vault) are enemies too, but until one comes alive it's a
    -- statue to work out, not something to fight: no growl, no enemy tip, its own scanner
    -- name. statues.lua plays the puzzle.
    statue  = { sound = nil,      every = 99,  range = 2500 },
    chest   = { sound = "item",   every = 3.0, range = 1500, pitch = 0.8 },
    collect = { sound = "item",   every = 2.5, range = 1500 },
    door    = { sound = "door",   every = 3.5, range = 1200 },
    -- Things to use: levers, pedestals, things to examine. Scanner only (no sound).
    usable  = { sound = nil,      every = 99,  range = 1500 },
    -- Breakable props (pots, jugs, kitchenware) are interactive objects too, but they're
    -- scenery to a player looking for what to use: their own category, not "Things to use".
    prop    = { sound = nil,      every = 99,  range = 1500 },
    -- Ancient magic hotspots: the game leads sighted players to them with wisps of light (the
    -- hotspot's own hint effect), from far off, across the vault's dark (Oct 8). A deep bell
    -- from the hotspot is the same guidance by ear.
    magic   = { sound = "note",   every = 2.0, range = 15000, pitch = 0.6 },
}
-- Every moving character but the player is an NPC_Character: students, Fig and ghosts
-- (through the enemy class), enemies, creatures. One query finds them all.
local CHARACTERS = "NPC_Character"
-- The rest, one class per pass, in order of precedence: a thing two classes both return
-- belongs to the earlier one.
local STATICS = {
    { cls = "AncientMagicHotSpot", kind = "magic" },
    { cls = "Container", kind = "chest" },
    { cls = "FieldGuidePage", kind = "collect" },
    { cls = "CooldownPickup", kind = "collect" },
    { cls = "Door", kind = "door" },
    { cls = "InteractiveObjectActor", kind = "usable" },
    { cls = "SimpleInteractObject", kind = "usable" },
    { cls = "WorldInteractObject", kind = "usable" },
}
local PROP_CLASSES = { "BCProps", "KitchenItems", "Ceramic" }
-- Class-name fragments that mean "a person, not a foe" even under Enemy_Character.
local FRIENDLY = { "Student", "Ghost", "Companion", "Professor", "Vendor", "Merchant" }
local STATUE_CLASS = "HogwartsProtector"

local SCAN_EVERY_MS = 600      -- one query per this interval (~30 ms each), alternating
local LISTENER_MS = 100
local GATE_MS = 250
local GATE_SETTLE_SECONDS = 5   -- elapsed time, independent of frame rate or dispatcher jitter

-- --- Gameplay gate --------------------------------------------------------------------

-- Game objects are never kept between ticks without the deletion record: touching one the game
-- has since destroyed crashes inside UE4SS, where nothing can catch it. Long-lived ones are
-- kept by path and looked up again (StaticFindObject is a quick hash lookup) when needed.
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

-- key (object address) -> { path, kind, name, name_src, x, y, z, dist, seen_at, pass,
-- priority, sound, every, range, pitch, next_at, heard_at, near_heard, extra, cn }: snapshots.
-- Only while holding (see "Holding") also obj, the object, and serial, its watch in the
-- deletion record.
local nearby = {}
local by_path = {}  -- path -> key
local spoken_names, logged_names = {}, {}
-- The scanner's current thing, by path (see "Ambient sounds"), and whether it has sounded yet.
local tracked, tracked_heard = nil, false

-- Forget one thing: its snapshot, its path, and its watch.
local function drop(key)
    local n = nearby[key]
    if not n then return end
    if n.path and by_path[n.path] == key then by_path[n.path] = nil end
    if n.serial and lifetime then lifetime.forget(key) end
    nearby[key] = nil
end

local function clear_world(reset_names)
    nearby, by_path, tracked = {}, {}, nil
    if holding then lifetime.clear() end
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
-- off (and says so) instead of crashing again. Quitting the game in the middle of play
-- (Alt+F4) left the marker too; the game instance's shutdown, which a crash never reaches,
-- now clears it, where the game sends it (unproven: its Blueprint may not implement the
-- event). A crash dump can't tell instead: the Oct 8 13:48 crash left none.
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
do
    local ok, err = pcall(RegisterHook, "/Script/Engine.GameInstance:ReceiveShutdown", function()
        pcall(os.remove, FUSE)
        log("the game is shutting down: crash fuse cleared")
    end)
    if not ok then log("shutdown hook unavailable: " .. tostring(err)) end
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
    if state.spell_lesson then state.ui_blocker = "spell lesson"; return "spell lesson" end
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
        -- The Sorting Hat's house screen (Oct 9): up in a scene the UI manager doesn't report,
        -- with the player's cinematic flag off, so the world opened over it and the arrows turned
        -- the camera. Menus noted its path (sorting.lua); it's a menu while it's in the viewport.
        if not why and state.sorting_path then
            diag.trace("gate: house screen")
            local up = false
            local scr = resolve(state.sorting_path)
            if scr then pcall(function() up = scr:IsInViewport() == true end) end
            if up then why = "sorting" else state.sorting_path = nil end
        end
    end
    if why ~= ui_last_why then ui_last_why, ui_changed_at = why, os.clock() end
    state.ui_blocker = why
    return why
end

-- The game's pre-rendered films (Content\Movies\FMV: the Pensieve memories, the seasons, the
-- credits) play through the cinematic scene actions' own Bink player. During the vault's
-- memory the player's cinematic flag was off and the gate opened over the film (Oct 9): world
-- sounds played over it and its descriptions ended with the "scene". The player says when a
-- film plays (an asset as long-lived as the game; IsPlaying checked in game, Oct 9). One said
-- to play for over MOVIE_MAX is no longer believed: a stuck player must never shut the world.
local MOVIE_PLAYER = "/Game/Cinematics/SceneActions/PlayBinkMedia/MP_PlayBinkMedia.MP_PlayBinkMedia"
local MOVIE_MAX = 900
local movie_since = nil
local function movie_playing()
    local mp = resolve(MOVIE_PLAYER)
    local playing = false
    if mp then
        local ok, v = pcall(function() return mp:IsPlaying() end)
        playing = ok and v == true
    end
    if not playing then
        if movie_since then log("film ended"); movie_since = nil end
        return false
    end
    if not movie_since then
        movie_since = os.clock()
        local url = ""
        pcall(function() url = mp.URL:ToString() end)
        log("film playing: " .. (url:match("[^/\\]+[/\\][^/\\]+$") or url))
    end
    return os.clock() - movie_since < MOVIE_MAX
end
M.movie_playing = movie_playing

local function gate_check()
    -- This barrier applies to recovery mode too: the UI manager can be torn down while
    -- world features are crash-paused. Ticks alone do not make an explicit load safe.
    if state.loading() then
        if in_game or pawn_path then log("loading: pausing the world layer") end
        close_gate("loading")
        clear_world(true)
        pawn_path, world_key = nil, nil
        return
    end
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
        if dispatch.ticking() then
            diag.trace("gate: UI manager")
            ui_blocker()
        end
        return
    end
    -- The game has stopped ticking: this is the fallback's tick, perhaps inside UEngine::LoadMap
    -- with the player being destroyed, where looking the player up crashed the game three times
    -- (dispatch.ticking). Leave everything as it is: a hitch passes, and a load is marked soon.
    if not dispatch.ticking() then diag.trace("gate: no game ticks, nothing looked up"); return end
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
        if okc and cine ~= true and movie_playing() then cine = true end
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
            state.world = state.world + 1
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

function M.in_game()
    return in_game and enabled and not state.loading() and not state.spell_lesson and dispatch.ticking()
end
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
    if state.loading() then return true end
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
                    prop = "Object", magic = "Ancient magic hotspot" }
-- Class names that say nothing about the thing ("BP_INT_Interact_C" was read as "Interact";
-- the vault's loot boxes, BP_S_Container_C, as "Container": they're chests, Oct 8).
local GENERIC = { ["Interact"] = true, ["Simple Interact Object"] = true, ["Interactive Object Actor"] = true,
                  ["World Interact Object"] = true, ["Something to use"] = true, ["Container"] = true }
-- Placeholder labels say no more than the class ("Player Interact" on the vault's vial, Oct 8):
-- the next source of a name gets its turn.
local function generic(h)
    return h == nil or GENERIC[h] == true or h:match("^%a* ?Interact%a*$") ~= nil
end

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
-- ("Template": every ordinary door is BP_Door_Template_C, read out as "Door Template", Oct 8.)
local NOISE_WORDS = { Default = true, Base = true, Character = true, Actor = true, Generic = true,
                      Phoenix = true, Int = true, Props = true, Prop = true, Items = true, Item = true,
                      Template = true }

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
            if id and id ~= "" and id ~= "None" then
                local h = humanize(id)
                if not generic(h) then name, src = h, label end
            end
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
        if generic(h) then
            -- Generic class: the thing's own label, its beacon name, or the name it was placed with.
            try("label", function() return actor.Text:ToString() end)
            try("beacon name", function() return actor.BeaconName:ToString() end)
            try("placed as", function() return placed_name(actor) end)
        end
        -- A class name that only repeats the category ("Enemy") adds nothing.
        if not name and not generic(h) and h:lower() ~= (KIND_NOUN[kind] or ""):lower() then
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

-- --- Scanning: snapshots, never lookups -------------------------------------------------
-- Everything the mod knows about the world's things comes from scan passes: one FindAllOf,
-- and every property any module needs read from those fresh objects in the same tick (modules
-- add their own reads with M.on_scan). Nothing looks a world actor up by path between passes:
-- on Oct 7 the lookup itself (StaticFindObject) crashed the game twice on knights the vault
-- fight had just destroyed, before any validity check could run. A thing its pass no longer
-- returns is dropped at once, so it is never touched again: the scan is its own sentinel.
-- Passes alternate: all characters in one query, then the next static class, so people and
-- enemies are never more than about 1.2 s old.

-- Things are kept for the scanner up to this far, even when they're too far to make a sound.
local KEEP_CM = 4000
-- Characters the story has named (learned from their subtitles) are kept much further: an
-- objective like "Find Professor Fig" can point at someone 100 m away in the dark (Oct 8, the
-- vault), and path.lua walks there.
local NAMED_KEEP_CM = 30000

local readers = {}   -- { fragment, fn }
--- Read more from a fresh object during a scan pass: fn(actor, entry) runs for every actor
--- whose class name contains `fragment`, in the pass's own tick (and, while holding, again at
--- each refresh, once the deletion record has vouched for the object). It may fill
--- entry.extra; it must never keep the actor.
function M.on_scan(fragment, fn) readers[#readers + 1] = { fragment = fragment, fn = fn } end

local function read_extra(a, n)
    for _, r in ipairs(readers) do
        if n.cn:find(r.fragment, 1, true) then
            local ok, err = pcall(r.fn, a, n)
            if not ok then diag.trace("scan reader " .. r.fragment .. ": " .. tostring(err)) end
        end
    end
end

local function enemy_tip()
    require("tips").once("enemy", function()
        local t = require("tips")
        -- One thing at a time, two seconds before the first attack (Oct 9: four keys in one
        -- sentence, cut off by the first alarm). How to fight back comes after the first block
        -- (combat.lua).
        return "An enemy is nearby: the low growl. When the alarm sounds, press " ..
               require("bindings").spoken("AM_Protego", "Q") .. " to block."
    end)
end

-- One fresh actor from a pass: its snapshot, created or refreshed. Returns true if kept.
local function take(a, kind, cn, pass, priority, seen)
    local key = a:GetAddress()
    if seen[key] then return false end
    local x, y, z = location(a)
    if not x then return false end
    local dx, dy, dz = x - px, y - py, z - pz
    local d = math.sqrt(dx * dx + dy * dy + dz * dz)
    local n = nearby[key]
    -- Held, and a deletion was noted at this address since: a new object took its place.
    if n and n.serial and not lifetime.alive(key, n.serial) then drop(key); n = nil end
    -- Without the deletion record, a new actor can take a gone one's address between passes:
    -- the snapshot (path, name, extra) is the old actor's unless this fresh object's own path
    -- and class still match it.
    local p = path_of(a)
    if n and ((n.path and p ~= n.path) or (n.cn and n.cn ~= cn)) then drop(key); n = nil end
    -- A thing an earlier (more specific) pass already holds stays with that pass.
    if n and n.pass ~= pass and (n.priority or 99) < priority then return false end
    local k = KINDS[kind]
    if d > math.max(k.range * 1.5, KEEP_CM) then
        if not (p and spoken_names[p] and d <= NAMED_KEEP_CM) then
            drop(key)
            return false
        end
    end
    seen[key] = true
    if not n or n.kind ~= kind then
        local was = n
        n = { next_at = os.clock() + math.random() * k.every, extra = was and was.extra or {} }
        if cn:find(STATUE_CLASS, 1, true) then
            n.name, n.name_src = kind == "statue" and "Knight statue" or "Stone knight", "statue"
        elseif kind == "magic" then
            n.name, n.name_src = KIND_NOUN.magic, "category"
        else
            n.name, n.name_src = name_of(a, kind)
        end
        nearby[key] = n
        if kind == "enemy" then enemy_tip() end
    end
    if not n.path then n.path = p end
    if n.path then by_path[n.path] = key end
    n.kind, n.pass, n.priority, n.cn = kind, pass, priority, cn
    n.sound, n.every, n.range, n.pitch = k.sound, k.every, k.range, k.pitch or 1.0
    n.x, n.y, n.z, n.dist, n.seen_at = x, y, z, d, os.clock()
    -- Holding: keep the object, watched from now on (it came fresh from this pass's query).
    if holding then
        if not n.serial then n.serial = lifetime.watch(key) end
        n.obj = a
    end
    read_extra(a, n)
    return true
end

-- The sentinel: what a pass held and didn't see again is gone, and is never touched again.
local function drop_unseen(pass, seen)
    for key, n in pairs(nearby) do
        if n.pass == pass and not seen[key] then drop(key) end
    end
end

local function character_kind(a, cn, creature_cls, enemy_cls)
    if friendly(cn) then return "person" end
    if cn:find(STATUE_CLASS, 1, true) then
        -- Only a knight that's a puzzle: the fight after it spawns the same class.
        if a.bPuzzleActive == true and a.bHasBeenReleased ~= true then return "statue" end
        return "enemy"
    end
    if creature_cls and a:IsA(creature_cls) then return "beast" end
    if enemy_cls and a:IsA(enemy_cls) then return "enemy" end
    return "person"
end

-- An empty result is believed only the second time in a row: one blip (UE4SS answers nil for
-- "none" and for a failed query alike) must not wipe every person and enemy for a pass.
local empty_streak = {}
local function run_pass(cls, pass, priority, classify)
    local t0 = os.clock()
    diag.trace("scan " .. cls .. ": FindAllOf")
    local ok, actors = pcall(FindAllOf, cls)
    if not ok then return end
    actors = actors or {}
    if #actors == 0 then
        empty_streak[pass] = (empty_streak[pass] or 0) + 1
        if empty_streak[pass] < 2 then return end
    else
        empty_streak[pass] = 0
    end
    diag.trace("scan " .. cls .. ": reading " .. #actors)
    local seen, found = {}, 0
    for _, a in ipairs(actors) do
        pcall(function()
            if not a:IsValid() then return end
            -- Hidden by the game: out of play for the player, like the vault's spare knights,
            -- which were growling as enemies where nothing stood (Oct 8).
            if a.bHidden == true then return end
            local cn = a:GetClass():GetFName():ToString()
            local kind = classify(a, cn)
            if kind and take(a, kind, cn, pass, priority, seen) then found = found + 1 end
        end)
    end
    drop_unseen(pass, seen)
    diag.trace("scan " .. cls .. ": done")
    local ms = math.floor((os.clock() - t0) * 1000 + 0.5)
    if found > 0 or ms > 50 then log(string.format("scan %s: %d nearby (%d ms)", cls, found, ms)) end
end

-- --- Holding ----------------------------------------------------------------------------
-- With the deletion record running (lifetime_enabled.txt), the objects passes find are held,
-- and every 200 ms the nearest are read again, positions and every on_scan reader: moving
-- people and enemies, and the knights' reflections, are heard where they are now, not where
-- the last pass saw them. A held object is touched only after the record says the game hasn't
-- deleted it since it was found. Then UE4SS's IsValid is safe to ask (it reads the object,
-- which is still there), and says whether it's on its way out. Passes still decide what
-- exists: a thing its pass doesn't return is dropped, held or not. The character pass is then
-- only for newcomers: every turn (1.2 to 1.4 s) while enemies are about or were in the last
-- 10 s, else at the first turn 2.5 s after the last pass (so every 2.5 to 3.6 s), or at the
-- next turn after 5 m of walking.
local REFRESH_MS = 200
local REFRESH_MAX = 24          -- the nearest this many are read again each time
local CALM_PASS_S, FOE_RECENT_S, MOVED_CM = 2.5, 10, 500
local life = { refreshed = 0, deleted = 0, invalid = 0, passes = 0, skipped = 0 }
local lifetime_why = lifetime and "starting" or "off (no lifetime_enabled.txt, or the module is missing)"
local last_chars_at, last_chars_x, last_chars_y, foe_at = -math.huge, 0, 0, -math.huge

local function refresh()
    if not holding or not in_game or state.loading() then return end
    local order = {}
    for key, n in pairs(nearby) do if n.obj then order[#order + 1] = key end end
    table.sort(order, function(a, b) return (nearby[a].dist or 1e9) < (nearby[b].dist or 1e9) end)
    for i = 1, math.min(#order, REFRESH_MAX) do
        local key = order[i]
        local n = nearby[key]
        if n and not lifetime.alive(key, n.serial) then
            life.deleted = life.deleted + 1     -- deleted since its pass: dropped untouched
            drop(key)
        elseif n and not valid(n.obj) then
            life.invalid = life.invalid + 1
            drop(key)
        elseif n then
            local x, y, z = location(n.obj)
            if x then
                local dx, dy, dz = x - px, y - py, z - pz
                n.x, n.y, n.z, n.dist, n.seen_at = x, y, z, math.sqrt(dx * dx + dy * dy + dz * dz), os.clock()
                read_extra(n.obj, n)
                life.refreshed = life.refreshed + 1
            end
        end
    end
end

-- Whether this turn's character pass runs (always, unless holding).
local function characters_due()
    if not holding then return true end
    local now = os.clock()
    for _, n in pairs(nearby) do
        if n.kind == "enemy" or n.kind == "statue" then foe_at = now; break end
    end
    if now - foe_at < FOE_RECENT_S or now - last_chars_at >= CALM_PASS_S then return true end
    return (px - last_chars_x) ^ 2 + (py - last_chars_y) ^ 2 >= MOVED_CM ^ 2
end

local turn, static_i = 0, 0
local function scan_step()
    if not in_game or state.loading() then return end
    turn = turn + 1
    if turn % 2 == 1 then
        if not characters_due() then life.skipped = life.skipped + 1; return end
        last_chars_at, last_chars_x, last_chars_y = os.clock(), px, py
        if holding then life.passes = life.passes + 1 end
        -- Native classes are never destroyed: safe to look up, fresh each pass anyway.
        local creature_cls, enemy_cls
        pcall(function() creature_cls = StaticFindObject("/Script/Phoenix.Creature_Character") end)
        pcall(function() enemy_cls = StaticFindObject("/Script/Phoenix.Enemy_Character") end)
        if not valid(creature_cls) then creature_cls = nil end
        if not valid(enemy_cls) then enemy_cls = nil end
        run_pass(CHARACTERS, "characters", 0, function(a, cn) return character_kind(a, cn, creature_cls, enemy_cls) end)
    else
        static_i = static_i % #STATICS + 1
        local st = STATICS[static_i]
        run_pass(st.cls, st.cls, static_i, function(a, cn)
            -- A fake hotspot is set dressing, not ancient magic to gather.
            if st.kind == "magic" then return a.FakeHotSpot ~= true and "magic" or nil end
            if st.kind ~= "usable" then return st.kind end
            -- Stations are spots characters stand at to act something out: not for the player.
            if cn:find("Station", 1, true) then return nil end
            -- Loot boxes with a lid (BP_S_Container) aren't Container actors, but to a player
            -- they're chests.
            if cn:find("Container", 1, true) then return "chest" end
            for _, frag in ipairs(PROP_CLASSES) do
                if cn:find(frag, 1, true) then return "prop" end
            end
            return "usable"
        end)
    end
end

-- --- Ambient sounds ---------------------------------------------------------------------

-- Two layers, so a busy place doesn't beep all at once (Matt, Oct 9: "a bit overwhelming with
-- everything beeping at once"):
--   * steady: the scanner's current thing (M.track) keeps a beat from as far as the scanner
--     reaches until the player is beside it, then the arrival sound; enemies keep theirs;
--   * background: everything else sounds once as it comes into range, once more as the player
--     passes close to a door, chest, collectible or ancient magic, and otherwise only every
--     REST_S while still in range: quieter, the nearest few of each kind (a crowd doesn't hide
--     the chest behind it), never two within BG_GAP_S.
-- Either way one sound per turn at most (after another access mod: overlapping cues from
-- everything in range were hard to tell apart).
local MAX_FOES = 8                -- enemies keep a beat: the nearest this many
local BG_EACH = 4                 -- background: the nearest this many of each kind
local BG_GAP_S = 0.8
local REST_S = 20
local NEAR_CM = 400
local NEAR_KINDS = { door = true, chest = true, collect = true, magic = true }
local TRACK_EVERY = 1.5
local TRACK_RANGE_CM = 4000       -- the scanner's reach (ancient magic: its own, further)
local TRACK_ARRIVE_CM = 200
local STEADY_VOLUME, BG_VOLUME = 0.7, 0.45
-- A picked thing without a sound of its own (something to use, an object): a higher sparkle.
-- Puzzle knights have statues.lua's bells instead.
local TRACK_SOUND, TRACK_PITCH = "item", 1.25
local bg_at = -math.huge

--- Picks the thing (by path, nil for none) whose sound keeps a steady beat until the player
--- is beside it: the scanner's current thing.
function M.track(path)
    if path == tracked then return end
    tracked, tracked_heard = path, false
    local n = path and nearby[by_path[path]]
    if n then n.next_at = os.clock() + 0.3 end
end

--- The tracked thing's path, or nil (none picked, or reached).
function M.tracked() return tracked end

local function sound_at(x, y, z, volume, sound, pitch, label)
    audio.play(sound, x, y, z + 60, volume, pitch)
    state.cue(label .. " " .. state.where(px, py, yaw_now, x, y))
end

local function ambient()
    if not in_game or not audio or not M.sounds_enabled() or state.loading() then return end
    local now = os.clock()
    local order = {}
    for key, n in pairs(nearby) do
        -- Silent kinds (things to use, objects, statues) are for the scanner, unless picked there.
        if n.sound or (tracked and n.path == tracked) then order[#order + 1] = key end
    end
    table.sort(order, function(a, b) return (nearby[a].dist or 1e9) < (nearby[b].dist or 1e9) end)
    local foes, ranks, best, best_why, best_d = 0, {}, nil, nil, nil
    for _, key in ipairs(order) do
        local n = nearby[key]
        -- From the last pass's snapshot: no lookup of the thing itself.
        local x, y, z = n.x, n.y, n.z
        local dx, dy, dz = x - px, y - py, z - pz
        local d = math.sqrt(dx * dx + dy * dy + dz * dz)
        if tracked and n.path == tracked then
            if d <= TRACK_ARRIVE_CM then
                -- Reached: back to the background, as if just heard. Picked while already
                -- beside it, it was never heard: no arrival either.
                tracked, n.heard_at, n.near_heard = nil, now, true
                if tracked_heard then
                    audio.play_ui("arrive", 0.5)
                    state.cue("Arrived at " .. n.name)
                    return
                end
            elseif now >= n.next_at then
                n.next_at = now + math.min(TRACK_EVERY, n.every)
                local sound = n.sound or (n.kind ~= "statue" and TRACK_SOUND)
                if sound and d <= math.max(TRACK_RANGE_CM, n.range) then
                    tracked_heard, n.heard_at = true, now
                    sound_at(x, y, z, STEADY_VOLUME, sound, n.sound and n.pitch or TRACK_PITCH, n.name)
                    return
                end
            end
        elseif n.kind == "enemy" then
            foes = foes + 1
            if foes <= MAX_FOES and now >= n.next_at then
                n.next_at = now + n.every
                if d <= n.range then
                    sound_at(x, y, z, STEADY_VOLUME, n.sound, n.pitch, KIND_NOUN.enemy)
                    return
                end
            end
        else
            -- Passing close counts again once well away.
            if n.near_heard and d > NEAR_CM * 2 then n.near_heard = false end
            ranks[n.kind] = (ranks[n.kind] or 0) + 1
            if ranks[n.kind] <= BG_EACH and d <= n.range then
                local why
                if NEAR_KINDS[n.kind] and not n.near_heard and d <= NEAR_CM then why = 1   -- close by
                elseif not n.heard_at then why = 2                                       -- came into range
                elseif now - n.heard_at >= REST_S then why = 3 end                       -- still there
                if why and (not best or why < best_why) then best, best_why, best_d = n, why, d end
            end
        end
    end
    if best and now - bg_at >= BG_GAP_S then
        bg_at, best.heard_at = now, now
        if best_d <= NEAR_CM then best.near_heard = true end
        sound_at(best.x, best.y, best.z, BG_VOLUME, best.sound, best.pitch, KIND_NOUN[best.kind] or best.kind)
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
    if lifetime then diag.log(M.lifetime_report()) end
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

--- How holding is going: the deletion record's counts and the refresh's (tools/probe_lifetime.lua,
--- and the 10-second status line).
function M.lifetime_report()
    if not lifetime then return "lifetime: " .. lifetime_why end
    local s = lifetime.stats()
    local held = 0
    for _, n in pairs(nearby) do if n.obj then held = held + 1 end end
    return string.format("lifetime: %s; deletions the engine reported %d, of watched objects %d; watching %d, holding %d; " ..
        "refreshed %d, dropped as deleted %d, as invalid %d; character passes %d, skipped %d",
        holding and "holding" or lifetime_why, s.notified, s.noted, s.watched, held,
        life.refreshed, life.deleted, life.invalid, life.passes, life.skipped)
end

--- The player's pawn, looked up fresh (nil outside gameplay). Use it within one task only.
function M.pawn()
    if not in_game or state.loading() then return nil end
    return resolve(pawn_path)
end

--- Everything the world scan is tracking: { key, path, kind, name, name_src, x, y, z, dist
--- (cm, at the last pass), seen_at, extra (what M.on_scan readers recorded) }. All of it is a
--- snapshot from the last pass that saw the thing.
function M.entries()
    local out = {}
    if not in_game or state.loading() then return out end
    for key, n in pairs(nearby) do
        if n.path then
            out[#out + 1] = { key = tostring(key), path = n.path, kind = n.kind, name = n.name,
                              name_src = n.name_src, x = n.x, y = n.y, z = n.z, dist = n.dist,
                              seen_at = n.seen_at, extra = n.extra }
        end
    end
    return out
end

--- Last known player position (cm) and camera yaw (degrees), as the listener uses them.
function M.position() return px, py, pz, yaw_now end

--- Position of the nearest tracked thing of one kind ("person", ...) within max_cm (from the
--- last passes, measured from where the player is now); nil if there's none.
function M.nearest(kind, max_cm)
    if not in_game or state.loading() then return nil end
    local best, best_d
    for _, n in pairs(nearby) do
        if n.kind == kind and n.x then
            local d = math.sqrt((n.x - px) ^ 2 + (n.y - py) ^ 2 + (n.z - pz) ^ 2)
            if d <= max_cm and (not best or d < best_d) then best, best_d = n, d end
        end
    end
    if not best then return nil end
    return { best.x, best.y, best.z }, best.path
end

--- Where a tracked thing was at the last pass that saw it, by its path, or nil once a pass no
--- longer finds it. Nothing is looked up.
function M.locate(path)
    if not in_game or state.loading() or not path then return nil end
    local n = nearby[by_path[path]]
    if not n or n.path ~= path or not n.x then return nil end
    return { n.x, n.y, n.z }
end

--- One tracked thing's snapshot by its path ({ path, kind, name, x, y, z, extra }), or nil once
--- a pass no longer finds it. Nothing is looked up.
function M.entry(path)
    if not in_game or state.loading() or not path then return nil end
    local n = nearby[by_path[path]]
    if not n or n.path ~= path then return nil end
    return { path = n.path, kind = n.kind, name = n.name, x = n.x, y = n.y, z = n.z, extra = n.extra }
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

-- The delete listener registers on the game thread, at the first tick.
if lifetime then
    dispatch.run(function()
        local ok, msg = lifetime.start()
        log("lifetime: " .. tostring(msg))
        if ok then
            lifetime.clear()
            holding = true
        else
            lifetime_why, lifetime = "start failed: " .. tostring(msg), nil
        end
    end, "lifetime start", true)
end

dispatch.every(GATE_MS, gate_check, "world gate", true)
dispatch.every(LISTENER_MS, update_listener, "world listener")
dispatch.every(SCAN_EVERY_MS, scan_step, "world scan")
dispatch.every(REFRESH_MS, refresh, "world refresh")
dispatch.every(250, ambient, "world ambient")
dispatch.every(10000, status, "world status")

log("loaded")
return M
