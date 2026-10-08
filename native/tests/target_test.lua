-- The game's own target: an auto-target change clicks from where the new target is, locking on
-- says its name as the HUD shows it and its shield (colour from the game's shield effects,
-- the spell kind that breaks it), and End adds it. The target is never touched after the hook.
local t = dofile("native/tests/testlib.lua")
local said, played, readers, events = {}, {}, {}, {}
local controller = { TargetingMode = 1 }
local snapshots = {}
package.loaded.world = {
    in_game = function() return true end, sounds_enabled = function() return true end,
    pawn = function() return { Controller = controller } end,
    entry = function(path) return snapshots[path] end,
    on_scan = function(fragment, fn) readers[#readers + 1] = { fragment = fragment, fn = fn } end,
}
package.loaded.audio_bridge = { init = function() return true end,
    play = function(name, x) played[#played + 1] = { name = name, x = x } end }
RegisterCustomEvent = function(name, fn) events[name] = fn end
local function arr(items)
    return { ForEach = function(_, fn) for i, v in ipairs(items) do fn(i, { get = function() return v end }) end end }
end
local function fname(s) return { ToString = function() return s end } end
local HUD = "/Engine/Transient.GameEngine_1:BP_PhoenixGameInstance_C_1.UI_BP_PhoenixHUDWidget_C_1"
local shown = "Goblin Trapper"
local hud = { IsValid = function() return true end, GetFullName = function() return "UI_BP_PhoenixHUDWidget_C " .. HUD end,
    NPCHealthMeter = { TargetName = { Text = { ToString = function() return shown end } } } }
local spell = { IsValid = function() return true end, DWShieldEffectData = arr({
    { ShieldTypes = arr({ 2 }), ShieldSkinEffectName = fname("Protego_Orange"), ShieldLoopFX2 = arr({}) },
    { ShieldTypes = arr({ 4 }), ShieldSkinEffectName = fname("None"), ShieldLoopFX2 = arr({
        { GetFullName = function() return "MultiFX2_NiagraVfx /Game/VFX/X.X" end,
          NiagaraVFX = { GetFullName = function() return "NiagaraSystem /Game/VFX/Enemies/Dark_Wizards/DW_Protego_Purple/VFX_NS_DW_Protego_FullShield_Purple_V3" end } } }) },
}) }
StaticFindObject = function(p)
    if p == HUD then return hud end
    if p:find("BP_ProtegoSpell_DW", 1, true) then return spell end
end
require("speech").say = function(s) said[#said + 1] = s end
local target = require("target")

-- The scan reader copies each enemy's shield type, and only enemies'.
assert(#readers == 1 and readers[1].fragment == "", "one reader, for every class")
local goblin = { kind = "enemy", extra = {} }
readers[1].fn({ EnemyAIComponent = { ProtegoDefenseLevel = 2 } }, goblin)
assert(goblin.extra.shield == 2, "shield type read in the pass")
local student = { kind = "person", extra = {} }
readers[1].fn({ EnemyAIComponent = { ProtegoDefenseLevel = 3 } }, student)
assert(student.extra.shield == nil, "people aren't read")
snapshots["/Game/Goblin"] = { path = "/Game/Goblin", kind = "enemy", name = "Goblin", x = 700, y = 0, z = 0, extra = goblin.extra }
snapshots["/Game/Wizard"] = { path = "/Game/Wizard", kind = "enemy", name = "Dark wizard", x = 0, y = 900, z = 0, extra = { shield = 4 } }

local function ctx(path, cls)
    return { get = function() return { GetFullName = function() return (cls or "UI_BP_PhoenixHUDWidget_C") .. " " .. path end } end }
end
local function param(path)
    return { get = function()
        if not path then return nil end
        return { IsValid = function() return true end, GetFullName = function() return "BP_Enemy_C " .. path end }
    end }
end
assert(events.SetCurrentTargetActor, "the HUD's target event is hooked")

-- Auto-target picks the goblin: a click from where it is, nothing said.
events.SetCurrentTargetActor(ctx(HUD), param("/Game/Goblin"))
t.run(0.5)
assert(played[#played] and played[#played].name == "tick" and played[#played].x == 700, "auto-target clicks from the target")
assert(#said == 0, "auto-target isn't spoken")

-- Locking on says the name as the game shows it, and the shield.
controller.TargetingMode = 2
t.run(0.3)
assert(said[#said] == "Locked on: Goblin Trapper, yellow shield, control spells break it, like Levioso", tostring(said[#said]))

-- Switching target while locked on: the new one is said once the HUD has its name.
shown = "Dark Wizard Executioner"
events.SetCurrentTargetActor(ctx(HUD), param("/Game/Wizard"))
t.run(0.6)
assert(said[#said] == "Locked on: Dark Wizard Executioner, purple shield, force spells break it, like Accio", tostring(said[#said]))
assert(#said == 2, "said once")
assert(target.describe() == "Dark Wizard Executioner, purple shield, force spells break it, like Accio", "End reads the target")

-- Another widget's event of the same name is ignored; a shield type with no known colour is "shielded".
events.SetCurrentTargetActor(ctx("/Engine/Transient.UI_BP_NPCHealthMeter_C_1", "UI_BP_NPCHealthMeter_C"), param("/Game/Goblin"))
t.run(0.5)
assert(target.describe():find("^Dark Wizard"), "only the HUD widget's event counts")
assert(target.shield_words(3) == "shielded" and target.shield_words(0) == nil, "unknown colour: shielded; none: nothing")

-- Target lost: nothing to describe.
events.SetCurrentTargetActor(ctx(HUD), param(nil))
t.run(0.5)
assert(target.describe() == nil, "no target")
print("target test passed")
