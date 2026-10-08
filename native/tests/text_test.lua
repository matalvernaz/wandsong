-- Offline test for the menu reader's text fixes: button hints said action first, and
-- sight or mouse instructions said in the mod's terms.
local here = (debug.getinfo(1, "S").source:gsub("^@", ""):gsub("\\", "/"):match("^(.*)/[^/]+$")) or "."
package.path = here .. "/../../mod/Wandsong/Scripts/?.lua;" .. package.path
LoopAsync = function() end
ExecuteInGameThread = function(fn) fn() end
RegisterHook = function() end
RegisterLoadMapPostHook = function() end
StaticFindObject = function() return nil end
FindFirstOf = function() return nil end
FindAllOf = function() return {} end
Key = { OEM_FOUR = 219, OEM_SIX = 221, OEM_FIVE = 220, OEM_ONE = 186, OEM_COMMA = 188, LEFT_ARROW = 37,
        RIGHT_ARROW = 39, UP_ARROW = 38, DOWN_ARROW = 40, OEM_SEVEN = 222, OEM_MINUS = 189, OEM_PLUS = 187 }
ModifierKey = { CONTROL = 1, SHIFT = 2 }
RegisterKeyBind = function() end
local keys = require("keys")
for _, a in ipairs({ { "turn_left", "left_arrow" }, { "turn_right", "right_arrow" }, { "where_am_i", "up_arrow" },
                      { "face_target", "," } }) do
    keys.action{ id = a[1], name = a[1], group = "test", default = a[2], run = function() end }
end
local t = require("menus")

local function eq(a, b) assert(a == b, "\n got: " .. tostring(a) .. "\nwant: " .. tostring(b)) end
eq(table.concat(t.legend_order({ "backslash", "Select", "Esc", "Back" }), ", "), "Select: backslash, Back: escape")
eq(table.concat(t.legend_order({ "gemma gemmerson", "Oct 3, 2026", "F", "Load Game" }), ", "),
   "gemma gemmerson, Oct 3, 2026, Load Game: F")
eq(table.concat(t.legend_order({ "Settings" }), ", "), "Settings")
eq(t.rewrite("Mouse Look Around"), "Look around: left arrow and right arrow turn you, up arrow says which way you face.")
eq(t.rewrite("Use your camera Mouse to select an active target., Continue: Space"),
   "Turn toward an enemy to make it your target: comma turns you to the nearest one, and period locks on. To continue, hold space for a moment.")
assert(t.rewrite("A white outline indicates your active target. Aim Mode reveals additional secondary targets, and a reticle for greater targeting precision."):find("With Wandsong: comma turns you"), "reticle note")
eq(t.clean('Tap <img src="cbi_Keyboard_Slash"/> to cast'), "Tap forward slash to cast")
eq(t.rewrite("The Minimap shows your surroundings, with you Map PlayerBlip in the middle. This is your current objective. Press and hold V to toggle quest objective details., Continue: Space"),
   "The minimap shows your surroundings to sighted players. With Wandsong, up arrow says your quest, its current task and which way the objective is. This is your current objective. Press and hold V to toggle quest objective details. To continue, hold space for a moment.")
eq(t.rewrite("Something., Continue: Space"), "Something. To continue, hold space for a moment.")
eq(t.rewrite("R cast Revelio Revelio."), "R cast Revelio.")
local objectives = t.rewrite("Review your objectives to reveal the way forward., Continue: Space")
assert(objectives:lower():find("press v, the game's objectives key", 1, true) and objectives:find("up arrow also says your quest", 1, true),
    "objectives tutorial names the key the game waits for, and the mod's: " .. objectives)
eq(t.rewrite("Tap 1 to cast or extinguish Lumos Lumos."), "Tap 1 to cast or extinguish Lumos.")
eq(t.rewrite(t.clean('Hold Q during Protego to stun enemies with a Stupefy <img src="TUT_Stupefy"/> counter-attack.')),
   "Hold Q during Protego to stun enemies with a Stupefy counter-attack.")
eq(t.rewrite("Press LeftShift to sprint."), "Press left shift to sprint.")
eq(t.rewrite("Hold LeftMouseButton, then SpaceBar."), "Hold left mouse button, then space.")
eq(t.rewrite("Professor McGonagall and Professor Weasley."), "Professor McGonagall and Professor Weasley.")
eq(t.rewrite("Hold still, then hold the line."), "Hold still, then hold the line.")
assert(t.rewrite("Steady your wand with Mouse and guide it along the symbol's path to learn the spell. Press the corresponding input when prompted to accelerate your wand's motion along the symbol's path."):find("^Spell lesson"),
    "the spell lesson's mouse instructions are said in the mod's terms")
print("text test passed")
