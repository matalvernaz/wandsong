-- The game's quest markers (the beacon manager's HUD beacons of the active-mission type). In the
-- Ravenclaw common room (Oct 8) the step wanted three students and gave no route; the scanner
-- called all eight "Student". The marked ones now lead the scanner's quest category, are tagged
-- in every list, and are what autowalk falls back to.
local t = dofile("native/tests/testlib.lua")
local things = {
    ["/Game/Samantha"] = { kind = "person", name = "Samantha Dale", pos = { 100, 0, 0 } },
    ["/Game/Other"] = { kind = "person", name = "Student", pos = { 500, 0, 0 } },
    ["/Game/Amit"] = { kind = "person", name = "Student", pos = { 1200, 0, 0 } },
    ["/Game/Door"] = { kind = "door", name = "Door", pos = { 1210, 40, 0 } },
}
package.loaded.world = {
    in_game = function() return true end,
    position = function() return 0, 0, 0, 0 end,
    entries = function()
        local out = {}
        for path, th in pairs(things) do
            out[#out + 1] = { path = path, kind = th.kind, name = th.name, x = th.pos[1], y = th.pos[2], z = th.pos[3] }
        end
        return out
    end,
    locate = function(path) local th = things[path]; return th and { th.pos[1], th.pos[2], th.pos[3] } end,
    not_ready_reason = function() return "not now" end,
}
package.loaded.path = { objective = function() return nil end, face_to = function() end }

-- The beacon manager and its HUD beacons: two quest markers over students, one hidden, one of
-- another type (a named character far away).
local function beacon(t_, x, y, z, hidden)
    return { BeaconType = t_, bIsBeaconActive = true, bHudIconSuppressed = hidden == true,
             BeaconWorldPosition = { X = x, Y = y, Z = z } }
end
local beacons = { beacon(7, 100, 0, 93), beacon(7, 1200, 0, 90), beacon(7, 500, 0, 90, true), beacon(61, 90000, 0, 0) }
local manager = {
    IsValid = function() return true end,
    GetFullName = function() return "BeaconManager /Engine/Transient.BeaconManager_1" end,
    HudBeaconObjects = { ForEach = function(_, fn) for i, b in ipairs(beacons) do fn(i, { get = function() return b end }) end end },
}
FindAllOf = function(cls) if cls == "BeaconManager" then return { manager } end return {} end
StaticFindObject = function(path) if path == "/Engine/Transient.BeaconManager_1" then return manager end end
local said = {}
require("speech").say = function(s) said[#said + 1] = s end

local markers = require("markers")
t.run(1.2)
assert(#markers.list() == 2, "two markers shown (the hidden one and the far named character aren't): " .. #markers.list())
assert(markers.marked("/Game/Samantha") and markers.marked("/Game/Amit"), "each marker belongs to the student under it")
assert(not markers.marked("/Game/Door"), "a character before the door beside it")
assert(not markers.marked("/Game/Other"), "unmarked students stay unmarked")
local near = markers.nearest()
assert(near and near.path == "/Game/Samantha" and near.x == 100, "the nearest marker, at its character")

-- The scanner: the quest category lists the marked students by name, and every list tags them.
require("scanner")
local run = {}
for _, a in pairs(require("keys").actions()) do run[a.id] = a.run end
run.scan_cat_next()   -- Everything -> Quest objective
t.run(0.5)
assert(said[#said]:find("^Samantha Dale, quest marker, close, ahead, 1 of 2"), said[#said])
run.scan_next()
assert(said[#said]:find("^Student, quest marker, 12 metres, ahead, 2 of 2"), said[#said])
run.scan_cat_next()   -- People
t.run(0.5)
run.scan_next()
assert(said[#said]:find("^Student, 5 metres") or said[#said]:find("^Samantha Dale, quest marker"), said[#said])
local tagged = 0
for _ = 1, 3 do
    run.scan_next()
    if said[#said]:find("quest marker", 1, true) then tagged = tagged + 1 end
end
assert(tagged == 2, "both marked students are tagged among the people: " .. tagged)

-- The markers go when the step changes.
beacons = {}
t.run(1.2)
assert(#markers.list() == 0 and not markers.marked("/Game/Samantha"), "a finished step leaves no markers")
print("markers test passed")
