-- The game's own audio cues: hooked only where this game version has the function, and turned
-- into speech (spotted, a beast noticing you, where a hit came from) or a positioned sound
-- (loot), each kind rate-limited and only in gameplay.
local t = dofile("native/tests/testlib.lua")
local said, played = {}, {}
local functions = {}
for _, f in ipairs({ "UIAccessibilityManager:TriggerAccessibilityEvent", "UIAccessibilityManager:TriggerAccessibilityEventEnter",
                     "UIAccessibilityManager:TriggerAccessibilityEventLeave", "UIAccessibilityManager:TriggerAccessibilityEventDamage",
                     "UIAccessibilityManager:ActivateAudioCues", "UIAccessibilityManager:DeactivateAudioCues" }) do
    functions["/Script/Phoenix." .. f] = { IsValid = function() return true end }
end
StaticFindObject = function(p) return functions[p] end
FindAllOf = function() return {} end
local in_game = true
local pawn = { GetFullName = function() return "BP_Biped_Player_C /Game/Player" end }
package.loaded.world = {
    in_game = function() return in_game end, position = function() return 0, 0, 0, 0 end,
    pawn = function() return pawn end, sounds_enabled = function() return true end, ui_busy = function() return false end,
}
package.loaded.audio_bridge = { init = function() return true end,
    play = function(name, x, y, z) played[#played + 1] = { name = name, x = x, y = y, z = z } end }
require("speech").say = function(s) said[#said + 1] = s end
local cues = require("gamecues")

local function param(v) return { get = function() return v end } end
local function actor(path, x, y)
    return { IsValid = function() return true end, GetFullName = function() return "BP_Thing_C " .. path end,
             RootComponent = { RelativeLocation = { X = x, Y = y, Z = 0 } } }
end
local EVENT = "/Script/Phoenix.UIAccessibilityManager:TriggerAccessibilityEvent"
local DAMAGE = "/Script/Phoenix.UIAccessibilityManager:TriggerAccessibilityEventDamage"
assert(t.hooks[EVENT] and t.hooks[DAMAGE], "the manager's functions are hooked")
assert(t.hooks["/Script/Phoenix.MapSubSystem:TriggerAccessibility"] == nil, "a function this version lacks is never hooked")

-- Spotted while sneaking: said once, not again within a few seconds.
t.hooks[EVENT](nil, param(14), param(actor("/Game/Troll", 500, 0)))
t.run(0.2)
assert(said[#said] == "Spotted!", "spotted is said: " .. tostring(said[#said]))
t.hooks[EVENT](nil, param(14), param(actor("/Game/Troll", 500, 0)))
t.run(0.2)
assert(#said == 1, "not twice in a row")

-- A hit from behind (the camera faces +X): said with its direction.
t.hooks[DAMAGE](nil, param(actor("/Game/Troll", -800, 0)), param({ X = -600, Y = 10, Z = 0 }), param(180), param(12))
t.run(0.2)
assert(said[#said] == "Hit from behind.", "where the hit came from: " .. tostring(said[#said]))
-- A hit whose location is the player and whose actor is the player: no direction to give.
t.run(2)
t.hooks[DAMAGE](nil, param(actor("/Game/Player", 0, 0)), param({ X = 20, Y = 0, Z = 0 }), param(0), param(5))
t.run(0.2)
assert(said[#said] == "Hit.", "no direction when there's none to give: " .. tostring(said[#said]))

-- Loot: the item sound from where it lies, nothing said.
local n = #said
t.hooks[EVENT](nil, param(10), param(actor("/Game/Coins", 300, 200)))
t.run(0.2)
assert(played[#played] and played[#played].name == "item" and played[#played].x == 300, "loot sounds where it lies")
assert(#said == n, "loot isn't spoken")

-- Footsteps and the like are only counted; nothing happens outside gameplay.
t.hooks[EVENT](nil, param(1), param(actor("/Game/Student", 100, 0)))
in_game = false
t.run(6)
t.hooks[EVENT](nil, param(14), param(actor("/Game/Troll", 500, 0)))
t.run(0.2)
assert(#said == n, "nothing said outside gameplay")
in_game = true

-- The switch taking effect is logged and reported.
t.hooks["/Script/Phoenix.UIAccessibilityManager:ActivateAudioCues"]()
t.run(0.2)
local report = cues.report()
assert(report:find("activated", 1, true) and report:find("event stealth detected=3", 1, true)
       and report:find("event footsteps=1", 1, true) and report:find("damage hit=2", 1, true), report)
print("game cues test passed")
