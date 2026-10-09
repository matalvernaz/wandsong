-- Combat feedback (Oct 9, the vault's first fight: "a lot", through it "mainly by luck"): a
-- block that works chimes (and says so at first), spells landing tick, enemies falling are
-- counted down, and a fight says how many it is. Hooks copy only scalars and paths.
local t = dofile("native/tests/testlib.lua")
local events, said, ui, tips = {}, {}, {}, {}
RegisterCustomEvent = function(name, fn) events[name] = fn end
local enemies = {
    { path = "/Game/Vault.Knight1", kind = "enemy", x = 500, y = 0, z = 0 },
    { path = "/Game/Vault.Knight2", kind = "enemy", x = 0, y = 500, z = 0 },
    { path = "/Game/Vault.Knight3", kind = "enemy", x = -500, y = 0, z = 0 },
    { path = "/Game/Far.Troll", kind = "enemy", x = 9000, y = 0, z = 0 },
    { path = "/Game/Vault.Fig", kind = "person", x = 100, y = 100, z = 0 },
}
package.loaded.world = { in_game = function() return true end, position = function() return 0, 0, 0, 0 end,
    sounds_enabled = function() return true end, entries = function() return enemies end }
package.loaded.audio_bridge = { init = function() return true end,
    play_ui = function(name, vol, pitch) ui[#ui + 1] = { name = name, pitch = pitch } end }
package.loaded.tips = { once = function(id, fn) tips[#tips + 1] = id; said[#said + 1] = fn() end }
require("speech").say = function(s) said[#said + 1] = s end
local combat = require("combat")
local function obj(full) return { get = function() return { GetFullName = function() return full end } end } end
local function val(v) return { get = function() return v end } end
local block = t.hooks["/Script/Phoenix.Biped_Player:NotifySucessfulBlock"]
local down = t.hooks["/Script/Phoenix.EncounterTracker:OnCombatVolumeDeath"]
local fight = t.hooks["/Script/Phoenix.EncounterTracker:StartEncounterForPlayersCombatVolume"]
assert(block and down and fight and events.OnNPC_Damaged, "the four combat events are hooked at startup")

-- A fight: how many, once they've arrived.
fight(obj("EncounterTracker /Engine/Transient.Tracker"))
t.run(1)
assert(#said == 0, "counted a moment later, once they've arrived")
t.run(1)
assert(said[#said] == "Fight: three enemies.", "the fight's size, near ones only: " .. tostring(said[#said]))

-- A block that works: a chime, "Blocked." the first three times, then how to fight back.
block(obj("BP_Biped_Player_C /Game/Player"))
t.run(0.2)
assert(ui[#ui].name == "chime" and said[#said - 1] == "Blocked.", "a block that works chimes and says so")
assert(tips[1] == "fight_back" and said[#said]:find("locks on to an enemy", 1, true), "then how to fight back")
for _ = 1, 4 do block(obj("BP_Biped_Player_C /Game/Player")); t.run(0.2) end
local blocked = 0
for _, s in ipairs(said) do if s == "Blocked." then blocked = blocked + 1 end end
assert(blocked == 3, "said three times, then the chime alone: " .. blocked)

-- Spells landing: a tick, higher on a weak spot; other widgets' events are ignored.
local n_ui = #ui
events.OnNPC_Damaged(obj("UI_BP_DamageIndicators_C /Game/HUD.DamageIndicators"), val({ X = 1, Y = 2 }), val(12.5), val(false))
t.run(0.2)
assert(ui[#ui].name == "tick" and ui[#ui].pitch == 1.6, "a hit ticks")
events.OnNPC_Damaged(obj("UI_BP_DamageIndicators_C /Game/HUD.DamageIndicators"), val({ X = 1, Y = 2 }), val(30), val(true))
t.run(0.2)
assert(ui[#ui].pitch == 2.2, "a weak spot ticks higher")
local n_said = #said
events.OnNPC_Damaged(obj("UI_BP_Other_C /Game/HUD.Other"), val({}), val(1), val(false))
t.run(0.2)
assert(#ui == n_ui + 2 and #said == n_said, "only the damage numbers count, and hits are never spoken")

-- Enemies down: counted from what's still near.
down(obj("EncounterTracker /Engine/Transient.Tracker"), obj("CombatVolume /Game/Vault.Volume"), obj("BP_HogwartsProtector_C /Game/Vault.Knight2"))
t.run(0.2)
assert(said[#said] == "One down, two left.", "one down: " .. tostring(said[#said]))
down(obj("EncounterTracker /Engine/Transient.Tracker"), obj("CombatVolume /Game/Vault.Volume"), obj("BP_HogwartsProtector_C /Game/Vault.Knight1"))
down(obj("EncounterTracker /Engine/Transient.Tracker"), obj("CombatVolume /Game/Vault.Volume"), obj("BP_HogwartsProtector_C /Game/Vault.Knight3"))
t.run(0.2)
assert(said[#said] == "Last one down.", "the last: " .. tostring(said[#said]))
assert(combat.enemies_left() == 0, "none left near")
-- A load starts afresh.
require("state").mark_loading(1)
t.run(2)
assert(combat.enemies_left() == 3, "a new map, a new count")
print("combat test passed")
