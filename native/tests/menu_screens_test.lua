-- The mod's own screens (Controls, Places, the guide). Audit A10: Press acts on the entry the
-- player picked even when the list is rebuilt in another order, with entries added before it
-- or its words changed; an entry that's gone, or can't be told from another, presses nothing.
-- Audit A20: Enter presses on a mod screen in the world too, never while typing, and never in
-- the world without one.
local t = dofile("native/tests/testlib.lua")
for k, v in pairs({ OEM_FOUR = 219, OEM_SIX = 221, OEM_FIVE = 220, OEM_ONE = 186, OEM_SEVEN = 222,
                    OEM_MINUS = 189, OEM_PLUS = 187, RETURN = 13, F11 = 122, F12 = 123 }) do Key[k] = v end
local said = {}
local px, py = 0, 0
local in_world = true
package.loaded.world = { gameplay = function() return in_world end, in_game = function() return in_world end,
    ui_busy = function() return false end, position = function() return px, py, 0, 0 end,
    not_ready_reason = function() return "Not now." end }
package.loaded.feedback = { translate = function(k) return k end }
package.loaded.path = { manager = function() return nil end }
local function arr(items)
    return { ForEach = function(_, fn) for i, v in ipairs(items) do fn(i, { get = function() return v end }) end end }
end
local function flame(handle, id, name, x)
    return { BeaconType = 30, BeaconState = 9, BeaconFlags = 0, BeaconHandle = handle, FastTravelLocationID = id,
             BeaconName = name, BeaconLocName = "", BeaconWorldPosition = { X = x, Y = 0, Z = 0 } }
end
local sub = { IsValid = function() return true end,
    GetFullName = function() return "MapSubSystem /Engine/Transient.MapSubSystem_1" end,
    OverlandFastTravelLocationList = arr({ flame(1, "FT_Near", "Near Flame", 1000), flame(2, "FT_Far", "Far Flame", 9000) }) }
local journeys = {}
local ftm = { IsValid = function() return true end,
    GetFullName = function() return "FastTravelManager /Engine/Transient.FastTravelManager_1" end }
function ftm.IsFastTravelling() return false end
function ftm.IsFastTravelDisabled() return false end
function ftm.IsFastTravelAvailable() return true end
function ftm.IsFastTravelUnlockedForLocation() return true end
function ftm.IsFastTravelAvailableForLocation() return true end
function ftm.StartFastTravelUsingID(_, id) journeys[#journeys + 1] = id end
local cdo = { IsValid = function() return true end, Get = function() return ftm end }
StaticFindObject = function(p) if p == "/Script/Phoenix.Default__FastTravelManager" then return cdo end end
FindAllOf = function(cls) if cls == "MapSubSystem" then return { sub } end return {} end
FindFirstOf = function() return nil end
RegisterLoadMapPostHook = function() end
require("speech").say = function(s) said[#said + 1] = s end
local state = require("state")
require("menus")
local places = require("places")
local next_item, press, enter, back = t.action("review_next"), t.action("press"), t.action("press_enter"), t.action("back")

-- Places, sorted nearest first afresh at every refresh: walking past the near flame turns the
-- order round between the question and the confirming press.
state.open_screen(places, "travel there")
next_item(); next_item()
assert(said[#said]:find("^Near Flame"), "picked the near flame: " .. said[#said])
press()
assert(said[#said]:find("Travel to Near Flame?", 1, true), "asks first: " .. said[#said])
px = 8000
press()
assert(journeys[1] == "FT_Near", "the confirming press travels to the flame that was picked: " .. tostring(journeys[1]))
assert(#journeys == 1, "and nowhere else")
state.close_screen()
state.mark_loading(1); t.run(1.2)   -- (the journey marks a load; let it pass)
px = 0

-- A list of plain entries (no ids: matched by their words).
local pressed
local function entry(text) return { text = text, button = true, on_press = function() pressed = text end } end
local list = { entry("First"), entry("Second") }
local screen = { title = "Test", items = function() return list end }
state.open_screen(screen, "use one")
next_item()
assert(said[#said]:find("^First"), said[#said])
list = { list[2], list[1] }
press()
assert(pressed == "First", "reordered: the entry picked is pressed, not what took its place: " .. tostring(pressed))
pressed = nil
table.insert(list, 1, entry("Inserted"))
press()
assert(pressed == "First", "an entry added before it: still the one picked: " .. tostring(pressed))
pressed = nil
list = { entry("Second"), entry("Third") }
local n = #said
press()
assert(pressed == nil, "the entry picked is gone: nothing is pressed")
assert(#said == n + 1 and said[#said]:find("The list has changed", 1, true), "and the player hears why: " .. tostring(said[#said]))
next_item()
press()
assert(pressed == "Third", "a new pick works again: " .. tostring(pressed))
-- Two entries with the same words can't be told apart once the list moves: nothing is pressed.
pressed = nil
list = { entry("Same"), entry("Other") }
state.open_screen(screen, "use one")
next_item()
list = { entry("Other"), entry("Same"), entry("Same") }
press()
assert(pressed == nil and said[#said]:find("The list has changed", 1, true), "ambiguous: nothing pressed")
-- With ids, entries with the same words stay apart.
local function place(id, text) return { id = id, text = text, button = true, on_press = function() pressed = id end } end
list = { place("a", "Floo Flame"), place("b", "Floo Flame") }
state.open_screen(screen, "use one")
next_item()
list = { place("b", "Floo Flame"), place("a", "Floo Flame, 3 metres") }
pressed = nil
press()
assert(pressed == "a", "followed by id, whatever its words now: " .. tostring(pressed))

-- A20: Enter on a mod screen in the world presses its entry.
list = { entry("First"), entry("Second") }
state.open_screen(screen, "use one")
next_item()
pressed = nil
enter()
assert(pressed == "First", "Enter presses on a mod screen in the world: " .. tostring(pressed))
back()
pressed = nil
enter()
assert(pressed == nil, "in the world without a mod screen, Enter is the game's alone")
-- A freshly opened screen with nothing picked: nothing pressed, and it says how to pick.
state.open_screen(screen, "use one")
enter()
assert(pressed == nil, "nothing picked: nothing pressed")
assert(said[#said]:find("^Nothing selected"), "the mod screen is open, not 'no menu': " .. said[#said])
print("menu screens test passed")
