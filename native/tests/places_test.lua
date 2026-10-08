-- Places: the game's own map markers as a list. Unlocked Floo Flames first, nearest first,
-- travelled to with the game's fast travel after its checks and a second press; other markers
-- nearest first with their kind and state, pressing one sets the game's route to it.
local t = dofile("native/tests/testlib.lua")
local said, calls = {}, {}
local closed = 0
local state = require("state")
state.open_screen = function() end
state.close_screen = function() closed = closed + 1 end
package.loaded.world = { in_game = function() return true end, position = function() return 0, 0, 0, 0 end,
    not_ready_reason = function() return "Not now." end }
package.loaded.feedback = { translate = function(k)
    local words = { ["FT_LOC_Library"] = "Hogwarts Library", ["LOC_Trial_04"] = "Merlin Trial" }
    return words[k] or k
end }
local function arr(items)
    return { ForEach = function(_, fn) for i, v in ipairs(items) do fn(i, { get = function() return v end }) end end }
end
local function beacon(f)
    return { BeaconType = f.type, BeaconState = f.state, BeaconFlags = f.flags or 0, BeaconHandle = f.handle,
             FastTravelLocationID = f.id or "", BeaconName = f.name or "", BeaconLocName = f.loc or "",
             BeaconWorldPosition = { X = f.x, Y = f.y, Z = 0 } }
end
local sub = {
    IsValid = function() return true end, GetFullName = function() return "MapSubSystem /Engine/Transient.MapSubSystem_1" end,
    OverlandFastTravelLocationList = arr({
        beacon({ type = 30, state = 9, handle = 1, id = "FT_Far", name = "Far_Flame", x = 90000, y = 0 }),
        beacon({ type = 30, state = 8, handle = 2, id = "FT_Locked", name = "Locked_Flame", x = 100, y = 0 }),
    }),
    HogwartsFastTravelLocationList = arr({
        beacon({ type = 31, state = 9, handle = 3, id = "FT_Library", loc = "FT_LOC_Library", x = 0, y = -2000 }),
    }),
    OverlandSphinxPuzzleLocationList = arr({
        beacon({ type = 34, state = 3, handle = 10, loc = "LOC_Trial_04", x = -1200, y = 0 }),
        beacon({ type = 34, state = 1, handle = 11, loc = "LOC_Trial_05", x = 50, y = 0 }),            -- under the fog
        beacon({ type = 34, state = 3, flags = 128, handle = 12, loc = "LOC_Trial_06", x = 60, y = 0 }), -- hidden from the map
    }),
    OverlandHamletLocationList = arr({ beacon({ type = 1, state = 11, handle = 20, name = "LowerHogsfield", x = 500, y = 500 }) }),
}
local ftm = { IsValid = function() return true end, GetFullName = function() return "FastTravelManager /Engine/Transient.FastTravelManager_1" end,
    available = true }
function ftm.IsFastTravelling() return false end
function ftm.IsFastTravelDisabled() return false end
function ftm.IsFastTravelAvailable(self) return self.available end
function ftm.IsFastTravelUnlockedForLocation(_, id) return id ~= "FT_Locked" end
function ftm.IsFastTravelAvailableForLocation() return true end
function ftm.StartFastTravelUsingID(_, id, from, kind) calls[#calls + 1] = id .. " " .. from .. " " .. kind end
local cdo = { IsValid = function() return true end, Get = function() return ftm end }
StaticFindObject = function(p) if p == "/Script/Phoenix.Default__FastTravelManager" then return cdo end end
FindAllOf = function(cls) if cls == "MapSubSystem" then return { sub } end return {} end
local route_calls = {}
package.loaded.path = { manager = function()
    return { SetBeaconPathTarget = function(_, h, validate, name) route_calls[#route_calls + 1] = h .. " " .. tostring(validate) .. " " .. name end,
             ClearPathTarget = function() route_calls[#route_calls + 1] = "clear" end }
end }
require("speech").say = function(s) said[#said + 1] = s end
local places = require("places")

local items = places.items()
local texts = {}
for i, it in ipairs(items) do texts[i] = it.text end
local all = table.concat(texts, " | ")
assert(texts[1] == "Floo Flames you can travel to, nearest first: 2", all)
assert(texts[2] == "Hogwarts Library, left, 20 metres", "the game's own name, translated: " .. texts[2])
assert(texts[3] == "Far Flame, ahead, 900 metres", "a raw name made readable: " .. texts[3])
assert(not all:find("Locked", 1, true), "a locked Floo Flame isn't listed")
assert(texts[4] == "On the map near you, nearest first", all)
assert(texts[5] == "Lower Hogsfield, hamlet, done, ahead right, 7 metres", texts[5])
assert(texts[6] == "Merlin Trial, not discovered, behind, 12 metres", texts[6])
assert(#items == 6, "under the fog or hidden from the map: not listed. " .. all)

-- Travel: the first press asks, the second goes through the game's own fast travel.
items[2].on_press()
assert(#calls == 0 and said[#said]:find("^Travel to Hogwarts Library%?"), said[#said])
items[2].on_press()
assert(calls[1] == "FT_Library 1 0", "the game's fast travel, from the map: " .. tostring(calls[1]))
assert(state.loading() and closed == 1 and said[#said] == "Travelling to Hogwarts Library.", "a load follows; the list closes")
-- Not while the game forbids it.
state.loading_until = -1
ftm.available = false
items[3].on_press(); items[3].on_press()
assert(#calls == 1 and said[#said] == "The game doesn't allow fast travel right now.", said[#said])

-- Any other marker: the game's route to it.
items[6].on_press()
assert(route_calls[1] == "10 false Merlin Trial", "route by beacon handle: " .. tostring(route_calls[1]))
items = places.items()
assert(items[#items].text == "Clear the route you set", "the route can be cleared")
items[#items].on_press()
assert(route_calls[2] == "clear" and said[#said] == "Route cleared.")
print("places test passed")
