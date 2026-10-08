-- Target: the enemy the game itself is aiming at, the way its HUD shows it, and the shield that
-- enemy carries.
--
-- The HUD widget's SetCurrentTargetActor (a Blueprint event the game calls whenever its target
-- changes) is hooked; the hook keeps only the target's path. Locking on (the controller's
-- TargetingMode) says the target's name, as the game shows it (the health meter's TargetName),
-- and its shield; an auto-target change only clicks from where the new target is. End (the
-- gauges key) adds the current target. The target object itself is never touched after the
-- hook: where it is and what shield it has come from the world scan's snapshot of it.
--
-- Shields: a reader in the world scan's pass copies each enemy's shield type
-- (EnemyAIComponent.ProtegoDefenseLevel). Which colour each type shows comes from the game's
-- own shield effects (the dark wizards' Protego spell lists, per type, the effects it plays,
-- whose names carry the colour), read once from that spell's class default object. Which kind
-- of spell breaks each colour is the game's rule as players know it (not in the game's data):
-- yellow, control spells; red, damage spells; purple, force spells. Unverified in game.

local dispatch = require("dispatch")
local state = require("state")
local speech = require("speech")
local world = require("world")

local M = {}

local function log(s) print("[Wandsong target] " .. s .. "\n") end

local LOCK_ON = 2               -- ETargetingMode: 0 none, 1 auto target, 2 lock on
local PROTEGO_SPELL = "/Game/Gameplay/ToolSet/Spells/DarkWizardSpells/BP_ProtegoSpell_DW.Default__BP_ProtegoSpell_DW_C"
-- Colour words in the shield effects' names, and what each colour is called and broken by.
local COLOURS = {
    { word = "Orange", name = "yellow", breaks = "control spells break it, like Levioso" },
    { word = "Yellow", name = "yellow", breaks = "control spells break it, like Levioso" },
    { word = "Purple", name = "purple", breaks = "force spells break it, like Accio" },
    { word = "Red", name = "red", breaks = "damage spells break it, like Incendio" },
    { word = "Blue", name = "blue" },
    { word = "White", name = "white" },
}

local audio
do
    local ok, a = pcall(require, "audio_bridge")
    if ok and type(a) == "table" and a.init() then audio = a end
end

-- --- Shields --------------------------------------------------------------------------------
world.on_scan("", function(a, e)
    if e.kind ~= "enemy" then return end
    local level
    pcall(function() level = a.EnemyAIComponent.ProtegoDefenseLevel end)
    e.extra.shield = type(level) == "number" and level or nil
end)

local shield_colours = nil      -- ProtegoDefenseLevel -> COLOURS entry, once read
local next_colour_try = 0
local function read_colours()
    local spell
    pcall(function() spell = StaticFindObject(PROTEGO_SPELL) end)
    local ok = false
    pcall(function() ok = spell ~= nil and spell:IsValid() end)
    if not ok then return nil end
    local map, found = {}, 0
    pcall(function()
        spell.DWShieldEffectData:ForEach(function(_, d)
            local data = d:get()
            local words = {}
            pcall(function() words[#words + 1] = data.ShieldSkinEffectName:ToString() end)
            pcall(function()
                data.ShieldLoopFX2:ForEach(function(_, fx)
                    local o = fx:get()
                    pcall(function() words[#words + 1] = o:GetFullName() end)
                    pcall(function() words[#words + 1] = o.NiagaraVFX:GetFullName() end)
                end)
            end)
            local text = table.concat(words, " ")
            local colour
            for _, c in ipairs(COLOURS) do
                if not colour and text:find(c.word, 1, true) then colour = c end
            end
            pcall(function()
                data.ShieldTypes:ForEach(function(_, t)
                    local v = t:get()
                    if type(v) == "number" and colour then map[v] = colour; found = found + 1 end
                end)
            end)
            log("shield effects: types for " .. (colour and colour.name or "no colour") .. " from " .. text)
        end)
    end)
    if found == 0 then return nil end
    return map
end

--- What a shield type means to the player: "yellow shield, control spells break it, like
--- Levioso", "blue shield", "shielded" (a type whose colour isn't known), or nil (no shield).
function M.shield_words(level)
    if type(level) ~= "number" or level <= 0 then return nil end
    local c = shield_colours and shield_colours[level]
    if not c then return "shielded" end
    return c.name .. " shield" .. (c.breaks and (", " .. c.breaks) or "")
end

-- --- The game's target ------------------------------------------------------------------------
local pending = nil             -- { path, hud } from the hook, for the next tick
local current = nil             -- { path, hud, name }
local mode = 0
local generation = state.generation

local function context_path(ctx, fragment)
    local ok, name = pcall(function() return ctx:get():GetFullName() end)
    if ok and type(name) == "string" and name:find(fragment, 1, true) then return name:match("^%S+%s+(.+)$") end
end
if type(RegisterCustomEvent) == "function" then
    local ok, err = pcall(RegisterCustomEvent, "SetCurrentTargetActor", function(ctx, target)
        local hud = context_path(ctx, "PhoenixHUDWidget")
        if not hud then return end
        local path
        pcall(function()
            local a = target:get()
            if a and a:IsValid() then path = a:GetFullName():match("^%S+%s+(.+)$") end
        end)
        pending = { path = path, hud = hud }
    end)
    log((ok and "hooked " or "hook failed ") .. "SetCurrentTargetActor" .. (ok and "" or (": " .. tostring(err))))
end

local function clean(s)
    if type(s) ~= "string" then return nil end
    s = s:gsub("<[^>]*>", ""):gsub("%s+", " "):match("^%s*(.-)%s*$")
    return s ~= "" and s or nil
end
-- The name as the HUD shows it: the health meter's TargetName (the boss meter's for a boss).
local function hud_name(hud_path)
    local name
    pcall(function()
        local hud = StaticFindObject(hud_path)
        if not (hud and hud:IsValid()) then return end
        local full = hud:GetFullName()
        if not full:find(hud_path, 1, true) then return end     -- a destroyed widget, renamed
        pcall(function() name = clean(hud.NPCHealthMeter.TargetName.Text:ToString()) end)
        if not name then pcall(function() name = clean(hud.BossHealthMeter.TargetName.Text:ToString()) end) end
    end)
    return name
end

local function targeting_mode()
    local m
    pcall(function() m = world.pawn().Controller.TargetingMode end)
    return type(m) == "number" and m or 0
end

local function words_for(t)
    local e = world.entry(t.path)
    local name = t.name or (e and e.name) or "an enemy"
    local shield = e and e.extra and M.shield_words(e.extra.shield)
    return name .. (shield and (", " .. shield) or "")
end

--- The current target in words ("Goblin Trapper, yellow shield, ..."), or nil.
function M.describe()
    if not current or not current.path or not world.in_game() then return nil end
    return words_for(current)
end

--- For tools/probe_target.lua: the target, the targeting mode and the shield colours learned.
function M.report()
    local colours = {}
    for level, c in pairs(shield_colours or {}) do colours[#colours + 1] = level .. "=" .. c.name end
    table.sort(colours)
    return "target " .. tostring(current and current.path) .. " (" .. tostring(M.describe()) .. "), mode " ..
        tostring(targeting_mode()) .. ", shield colours " .. (#colours > 0 and table.concat(colours, " ") or "not read yet")
end

dispatch.every(200, function()
    if generation ~= state.generation then
        generation, current, pending, mode = state.generation, nil, nil, 0
    end
    if not world.in_game() then pending = nil; return end
    if not shield_colours and os.clock() >= next_colour_try then
        next_colour_try = os.clock() + 10
        shield_colours = read_colours()
    end
    local m = targeting_mode()
    if pending then
        if not current or current.path ~= pending.path then
            current = pending
            -- The health meter fills its name a moment after the target changes: read it then.
            current.fresh = current.path ~= nil
            if current.fresh and m ~= LOCK_ON and audio and world.sounds_enabled() then
                local e = world.entry(current.path)
                if e and e.x then audio.play("tick", e.x, e.y, e.z + 90, 0.5, 1.3) end
            end
        end
        pending = nil
    elseif current and current.fresh then
        current.fresh = false
        current.name = hud_name(current.hud)
        if m == LOCK_ON then current.said = false end
    end
    if current and current.path and not current.fresh and m == LOCK_ON and (mode ~= LOCK_ON or current.said == false) then
        current.said = true
        if not current.name then current.name = hud_name(current.hud) end
        local said = "Locked on: " .. words_for(current)
        speech.say(said)
        state.cue(said)
    end
    mode = m
end, "game target")

return M
