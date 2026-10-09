-- The Sorting Hat's house screen as a menu (Oct 9: Matt couldn't choose a different house). The
-- fake screen behaves as the real one did that day: it opens on the hat's house (state 0); Back
-- goes 0 to all four crests (1), 1 to the picked house (2) and 2 to 1; a crest's own select
-- handler puts its house on show (2); Accept (F's action) takes the house shown. The menu starts
-- on the hat's suggestion, asks once, and accepts only the house the player chose, never from
-- the opening view.
local t = dofile("native/tests/testlib.lua")
for k, v in pairs({ OEM_FOUR = 219, OEM_SIX = 221, OEM_FIVE = 220, RETURN = 13 }) do Key[k] = v end
local said = {}
package.loaded.world = { gameplay = function() return false end, in_game = function() return false end,
    ui_busy = function() return false end, not_ready_reason = function() return "Not now." end }
local PATH = "/Engine/Transient.GameEngine_1:BP_PhoenixGameInstance_C_1.UI_BP_SortingHat_C_1"
local CRESTS = { [0] = "gryffindor", [1] = "hufflepuff", [2] = "ravenclaw", [3] = "slytherin" }
local up, accepted, sent, broken = true, nil, {}, false
local hat = { HouseStateIndex = 0, NewHouse = 2, SuggestedHouse = 2, HasWWHouse = true,
    WWHouse = { ToString = function() return "Ravenclaw" end } }
local fns = {}
for id, crest in pairs(CRESTS) do
    fns[#fns + 1] = "BndEvt__UI_BP_SortingHat_" .. crest .. "_K2Node_ComponentBoundEvent_" .. id .. "_OnHouseSelected__DelegateSignature"
    fns[#fns + 1] = "BndEvt__UI_BP_SortingHat_" .. crest .. "_K2Node_ComponentBoundEvent_" .. (id + 5) .. "_OnHouseHovered__DelegateSignature"
    hat[fns[#fns - 1]] = function(self)
        if self.HouseStateIndex == 1 and not broken then self.NewHouse, self.HouseStateIndex = id, 2 end
    end
    hat[fns[#fns]] = function() end
end
hat.IsValid = function() return true end
hat.IsInViewport = function() return up end
hat.GetFullName = function() return "UI_BP_SortingHat_C " .. PATH end
hat.GetClass = function() return {
    GetFName = function() return { ToString = function() return "UI_BP_SortingHat_C" end } end,
    ForEachFunction = function(_, visit)
        for _, n in ipairs(fns) do visit({ GetFName = function() return { ToString = function() return n end } end }) end
    end } end
local mgr = { IsValid = function() return true end }
function mgr.OnInputAction(_, action, event)
    if event ~= 0 then return end
    sent[#sent + 1] = action
    if action == 1 then hat.HouseStateIndex = hat.HouseStateIndex == 1 and 2 or 1
    elseif action == 75 and hat.HouseStateIndex ~= 1 then accepted = hat.NewHouse; up = false end
end
StaticFindObject = function(p) if p == PATH then return hat end end
FindFirstOf = function(cls) if cls == "UMGInputManager" then return mgr end end
FindAllOf = function() return {} end
RegisterLoadMapPostHook = function() end
require("speech").say = function(s) said[#said + 1] = s end
local state = require("state")
require("menus")
local sorting = require("sorting")
local press, enter = t.action("press"), t.action("press_enter")
-- The arrows come from path.lua in the game (not loaded here): the menu's own list step.
local function down() state.menu_step(1) end
local function upk() state.menu_step(-1) end

-- The game reads the screen: the menu opens on the hat's suggestion.
local function read_screen() t.hooks["/Script/Phoenix.PhoenixUserWidget:ReadMenu"]({ get = function() return hat end }); t.run(0.2) end
read_screen()
local opening = said[#said]
assert(opening:find("^The Sorting%. Choose your house with the up and down arrows, then enter%. The hat suggests Ravenclaw%."),
    "says how to choose and the suggestion: " .. opening)
assert(opening:find("Ravenclaw, known for intelligence, creativity, and wit, the hat's suggestion, your Wizarding World house, button, 3 of 4", 1, true),
    "starts on the suggestion: " .. opening)
assert(state.screen_open(sorting), "the house menu is the screen open")
local n = #said
read_screen()
assert(#said == n, "the screen read again (its views changing) says nothing more")

-- Another house: down to Slytherin, up twice to Hufflepuff, then press, and press again.
down()
assert(said[#said]:find("^Slytherin, known for cunning, ambition and a hunger for power"), said[#said])
upk(); upk()
assert(said[#said]:find("^Hufflepuff, known for patience, loyalty and hard work, button, 2 of 4"), said[#said])
press()
assert(said[#said]:find("^Join Hufflepuff%? Press backslash or enter again"), "asks once: " .. said[#said])
assert(#sent == 0, "nothing sent on the first press")
enter()
t.run(0.5)
assert(sent[1] == 1 and hat.HouseStateIndex == 1, "Back shows all the crests")
assert(accepted == nil, "nothing accepted yet")
t.run(2)
assert(accepted == 1, "Hufflepuff accepted, after the screen showed it: " .. tostring(accepted))
assert(sent[#sent] == 75, "with the game's own Accept")
assert(said[#said] == "Hufflepuff.", said[#said])
t.run(1)
state.sorting_path = nil   -- the world gate's part, once the screen is gone
t.run(1)
assert(not state.screen_open(sorting), "the menu closes with the screen")

-- The suggestion from the opening view: picked through its crest too, never taken on trust.
up, accepted, sent = true, nil, {}
hat.HouseStateIndex, hat.NewHouse = 0, 2
read_screen()
press(); press()
t.run(3)
assert(accepted == 2 and #sent == 2 and sent[1] == 1 and sent[2] == 75, "the suggestion, through its crest: " .. #sent)
-- A house already picked and shown (the player clicked a crest): accepted at once.
up, accepted, sent = true, nil, {}
hat.HouseStateIndex, hat.NewHouse = 2, 2
read_screen()
press(); press()
t.run(0.5)
assert(accepted == 2 and #sent == 1 and sent[1] == 75, "the house shown is just accepted")

-- If the screen doesn't take the house (shows another), nothing is accepted.
up, accepted, sent, broken = true, nil, {}, true
hat.HouseStateIndex, hat.NewHouse = 0, 2
read_screen()
upk(); upk(); upk()                     -- Gryffindor
press(); press()
t.run(3)
assert(accepted == nil, "never accepts a house the player didn't choose")
assert(said[#said]:find("didn't take that choice", 1, true), "and says so: " .. said[#said])
assert(state.screen_open(sorting), "the menu stays for another try")
-- A first press long ago doesn't count as the confirmation; one 10 s ago does (the question
-- takes 4 s to say).
broken = false
hat.HouseStateIndex = 0
press(); t.run(16); press()
assert(said[#said]:find("^Join Gryffindor%?"), "asks again after a while: " .. said[#said])
t.run(10)
press()
t.run(3)
assert(accepted == 0, "then Gryffindor: " .. tostring(accepted))
print("sorting test passed")
