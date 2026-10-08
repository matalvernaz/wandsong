-- Game cues: Hogwarts Legacy's own accessibility "audio cues" (the sound visualizer it has for
-- deaf players), turned into what a blind player hears.
--
-- The game marks what's audible and who made it: being spotted while sneaking, a beast noticing
-- you, a hit and where it came from, loot, an alerted enemy, a door, Revelio and more.
-- gamesettings.lua switches the feature on at every start, before the HUD is built. Every
-- source feeds M.event:
--   * the accessibility manager's Trigger* functions and the map subsystem's
--     TriggerAccessibility, when Blueprint code calls them. RegisterHook only sees calls made
--     through the game's script layer; the game's own C++ callers bypass it, so these may stay
--     quiet. Which ones fire is the first thing to learn in game (tools/probe_gamecues.lua);
--   * ActivateAudioCues / DeactivateAudioCues: logged, to show the switch took;
--   * the HUD's cue panel (BP_HUD_Audio_C.CuePanel): what it draws is logged when it changes,
--     to learn its shape. Nothing reacts to it yet.
-- Reactions (speak little, sound a lot; each kind at most every few seconds, only in gameplay):
-- spotted is said, so is a beast noticing you and where a hit came from; loot plays the item
-- sound from where it lies. The rest are logged and counted.
-- Hooks stay trivial: the type, the actor's path and position, and plain numbers.

local dispatch = require("dispatch")
local diag = require("diag")
local state = require("state")
local speech = require("speech")
local world = require("world")

local M = {}

local function log(s) print("[Wandsong gamecues] " .. s .. "\n") end

local TYPES = {
    [0] = "interact", "footsteps", "spellcaster", "alert", "beast roar", "destructible",
    "running water", "door", "negative interaction", "broom", "loot", "beast aware", "hit",
    "ambient conversation", "stealth detected", "revelio bell", "none",
}

-- What a blind player gets from each kind; the others are only logged and counted.
local REACT = {
    ["stealth detected"] = { say = "Spotted!", every = 5 },
    ["beast aware"] = { say = "A beast noticed you.", every = 8 },
    ["hit"] = { hit = true, every = 1.5 },
    ["loot"] = { sound = "item", every = 0.5 },
}
local NEAR_CM = 150             -- a hit location this close to the player says nothing about where

local audio
do
    local ok, a = pcall(require, "audio_bridge")
    if ok and type(a) == "table" and a.init() then audio = a end
end

local pending = {}    -- events recorded by hooks, waiting for the next tick
local counts = {}     -- "<source> <kind>" -> count this session
local logged = {}     -- the first few of each are logged in full
local last = {}       -- kind -> when it last reacted
local activations = {}
local hits_logged = 0

local function num(p)
    local v
    pcall(function() v = p:get() end)
    if type(v) == "number" and v == v and math.abs(v) < 1e12 then return v end
end

-- The actor a hook was handed: its path and where it is, read while the game hands it over.
local function actor_info(p)
    local path, x, y, z
    pcall(function()
        local a = p:get()
        if a and a:IsValid() then
            path = a:GetFullName():match("^%S+%s+(.+)$")
            local v = a.RootComponent.RelativeLocation
            x, y, z = v.X, v.Y, v.Z
        end
    end)
    if not (type(x) == "number" and type(y) == "number" and type(z) == "number") then x, y, z = nil, nil, nil end
    return path, x, y, z
end

local function record(e)
    if #pending < 64 then e.at = os.clock(); pending[#pending + 1] = e end
end
local function take(source, type_param, actor_param)
    local path, x, y, z = actor_info(actor_param)
    record({ source = source, type = num(type_param), path = path, x = x, y = y, z = z })
end
local function take_damage(_, actor_param, loc_param, angle_param, damage_param)
    local path, x, y, z = actor_info(actor_param)
    local lx, ly, lz
    pcall(function() local v = loc_param:get(); lx, ly, lz = v.X, v.Y, v.Z end)
    if not (type(lx) == "number" and type(ly) == "number") then lx, ly, lz = nil, nil, nil end
    record({ source = "damage", type = 12, path = path, x = x, y = y, z = z, lx = lx, ly = ly, lz = lz,
             angle = num(angle_param), damage = num(damage_param) })
end

-- Where a hit came from, in the camera's terms: from the hit's location, or else from the
-- actor the game named, when either is away from the player. "Hit." when neither is.
local function hit_words(e)
    local px, py, _, yaw = world.position()
    local pawn_path
    pcall(function() pawn_path = world.pawn():GetFullName():match("^%S+%s+(.+)$") end)
    local function away(x, y) return x and (x - px) ^ 2 + (y - py) ^ 2 > NEAR_CM ^ 2 end
    local x, y
    if away(e.lx, e.ly) then x, y = e.lx, e.ly
    elseif e.path ~= pawn_path and away(e.x, e.y) then x, y = e.x, e.y end
    local words = x and ("Hit from " .. state.where(px, py, yaw, x, y):match("^[^,]+") .. ".") or "Hit."
    if hits_logged < 10 then
        hits_logged = hits_logged + 1
        log(string.format("hit: angle %s, location %s, actor %s at %s, said %q", tostring(e.angle),
            e.lx and string.format("%.0f %.0f", e.lx, e.ly) or "none", tostring(e.path),
            e.x and string.format("%.0f %.0f", e.x, e.y) or "?", words))
    end
    return words
end

--- One cue from any source: kind is the game's cue name ("stealth detected"), e.path/x/y/z the
--- actor involved when known.
function M.event(e)
    local kind = TYPES[e.type] or tostring(e.type)
    e.kind = kind
    local key = e.source .. " " .. kind
    counts[key] = (counts[key] or 0) + 1
    logged[key] = (logged[key] or 0) + 1
    if logged[key] <= 5 then log(key .. " from " .. tostring(e.path)) end
    local r = REACT[kind]
    if not r or e.source == "leave" or not world.in_game() then return end
    local now = os.clock()
    if now - (last[kind] or -100) < r.every then return end
    if r.say then
        last[kind] = now
        speech.say(r.say)
        state.cue(r.say)
    elseif r.hit then
        last[kind] = now
        local words = hit_words(e)
        speech.say(words)
        state.cue(words)
    elseif r.sound and audio and e.x and world.sounds_enabled() then
        last[kind] = now
        audio.play(r.sound, e.x, e.y, e.z + 60, 0.6, 1.0)
        local px, py, _, yaw = world.position()
        state.cue("Loot " .. state.where(px, py, yaw, e.x, e.y))
    end
end

-- --- Hooks: only on functions this game version has (a missing one would leak a reference
-- each time UE4SS tried) ---------------------------------------------------------------------
local HOOKS = {
    { "/Script/Phoenix.UIAccessibilityManager:TriggerAccessibilityEvent", function(_, t, a) take("event", t, a) end },
    { "/Script/Phoenix.UIAccessibilityManager:TriggerAccessibilityEventEnter", function(_, t, a) take("enter", t, a) end },
    { "/Script/Phoenix.UIAccessibilityManager:TriggerAccessibilityEventLeave", function(_, t, a) take("leave", t, a) end },
    { "/Script/Phoenix.UIAccessibilityManager:TriggerAccessibilityEventDamage", take_damage },
    { "/Script/Phoenix.MapSubSystem:TriggerAccessibility", function(_, t, a) take("map", t, a) end },
    { "/Script/Phoenix.UIAccessibilityManager:ActivateAudioCues",
      function() activations[#activations + 1] = { what = "activated", at = os.clock() } end },
    { "/Script/Phoenix.UIAccessibilityManager:DeactivateAudioCues",
      function() activations[#activations + 1] = { what = "deactivated", at = os.clock() } end },
}
for _, h in ipairs(HOOKS) do
    local fn
    pcall(function() fn = StaticFindObject(h[1]) end)
    local exists = false
    pcall(function() exists = fn ~= nil and fn:IsValid() end)
    if not exists then
        log("not in this game version: " .. h[1])
    else
        local name = h[1]:match(":(.+)$")
        local ok, err = pcall(RegisterHook, h[1], function(...)
            diag.trace("hook " .. name)
            h[2](...)
        end)
        log((ok and "hooked " or "could not hook ") .. h[1] .. (ok and "" or (": " .. tostring(err))))
    end
end

dispatch.every(100, function()
    if #activations > 0 then
        for _, a in ipairs(activations) do log("the game's audio cues were " .. a.what) end
        M.last_activation = activations[#activations].what
        activations = {}
    end
    if #pending == 0 then return end
    local batch = pending
    pending = {}
    for _, e in ipairs(batch) do
        -- A cue that waited out a stalled tick is old news: counted, not reacted to.
        if os.clock() - e.at > 1 then
            local key = e.source .. " " .. (TYPES[e.type] or tostring(e.type))
            counts[key] = (counts[key] or 0) + 1
        else
            M.event(e)
        end
    end
end, "game cues", true)

dispatch.every(30000, function()
    local parts = {}
    for k, v in pairs(counts) do parts[#parts + 1] = k .. "=" .. v end
    if #parts > 0 then
        table.sort(parts)
        log("totals: " .. table.concat(parts, ", "))
    end
end, "game cue totals", true)

-- --- The HUD's cue panel, logged to learn its shape ------------------------------------------
local hud_path, next_find, last_panel, panel_logs = nil, 0, nil, 0
local function path_of(o)
    local full
    pcall(function() full = o:GetFullName() end)
    return full and full:match("^%S+%s+(.+)$") or nil
end
local function cue_widget()
    local w
    if hud_path then
        pcall(function() w = StaticFindObject(hud_path) end)
        local ok = false
        pcall(function() ok = w:IsValid() and path_of(w) == hud_path end)
        if ok then return w end
        hud_path = nil
    end
    if os.clock() < next_find then return nil end
    next_find = os.clock() + 10
    pcall(function()
        for _, o in ipairs(FindAllOf("BP_HUD_Audio_C") or {}) do
            local p = path_of(o)
            if p and not p:find("Default__", 1, true) and o:IsValid() then w, hud_path = o, p end
        end
    end)
    return w
end
dispatch.every(1000, function()
    if panel_logs >= 40 or not world.in_game() or world.ui_busy() then return end
    local w = cue_widget()
    if not w then return end
    local parts = {}
    pcall(function()
        w.CuePanel.Slots:ForEach(function(_, e)
            local c
            pcall(function() c = e:get().Content end)
            if c then
                local cls, name, n = "?", nil, nil
                pcall(function() cls = c:GetClass():GetFName():ToString() end)
                pcall(function() name = c.Name:ToString() end)
                pcall(function() n = c.NumIcons end)
                parts[#parts + 1] = cls .. (name and (" " .. name) or "") .. (type(n) == "number" and (" x" .. n) or "")
            end
        end)
    end)
    local shape = #parts .. (#parts > 0 and (": " .. table.concat(parts, "; ")) or "")
    if shape ~= last_panel then
        last_panel = shape
        panel_logs = panel_logs + 1
        log("cue panel " .. shape)
    end
end, "game cue panel")

--- What arrived so far, for tools/probe_gamecues.lua.
function M.report()
    local parts = {}
    for k, v in pairs(counts) do parts[#parts + 1] = k .. "=" .. v end
    table.sort(parts)
    return "audio cues " .. tostring(M.last_activation or "never activated") .. "; cue panel " ..
        tostring(last_panel or "not seen") .. "; events: " .. (#parts > 0 and table.concat(parts, ", ") or "none")
end

return M
