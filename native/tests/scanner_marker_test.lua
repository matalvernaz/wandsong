-- Audit A14: walking to a quest marker picked in the scanner goes to that marker, not to the
-- general objective, however the marker list is ordered at the time; a marker that's gone (the
-- step changed) walks nowhere. The route's end itself is still walked along the game's route.
local t = dofile("native/tests/testlib.lua")
local said, walked, faced = {}, nil, nil
local marks = { { x = 1000, y = 0, z = 0 }, { x = 0, y = 2000, z = 0 } }
local objective = { x = 1000, y = 0, z = 0, name = "Quest objective" }
package.loaded.world = { in_game = function() return true end, position = function() return 0, 0, 0, 0 end,
    entries = function() return {} end, locate = function() return nil end }
package.loaded.markers = { list = function() return marks end, marked = function() return false end }
package.loaded.path = { objective = function() return objective end,
    walk_objective = function() walked = "the objective" end,
    walk_point = function(x, y, z, name) walked = { x, y, z, name } end,
    face_point = function(x, y) faced = { x, y } end }
require("speech").say = function(s) said[#said + 1] = s end
require("scanner")
local cat_next, scan_next, scan_repeat, scan_walk =
    t.action("scan_cat_next"), t.action("scan_next"), t.action("scan_repeat"), t.action("scan_walk")

cat_next(); t.run(0.3)
assert(said[1] == "Quest objective, 2 nearby", "the quest category: " .. tostring(said[1]))
scan_next()
scan_repeat()
assert(faced and faced[1] == 0 and faced[2] == 2000, "the second marker is picked and faced")
scan_walk()
assert(type(walked) == "table" and walked[1] == 0 and walked[2] == 2000, "walks to the picked marker, not the objective")
-- The list comes back in another order: still the marker picked.
walked = nil
marks = { marks[2], marks[1] }
scan_walk()
assert(type(walked) == "table" and walked[2] == 2000, "the same marker after the list changed order")
-- The step changes: other markers. The one picked is gone, and nothing is walked to.
walked = nil
marks = { { x = 3000, y = 0, z = 0 } }
objective = { x = 3000, y = 0, z = 0, name = "Quest objective" }
scan_walk()
assert(walked == nil and said[#said]:find("has gone", 1, true), "a marker that's gone walks nowhere: " .. said[#said])
-- The route's end where no marker stands: walked along the game's own route.
marks = {}
objective = { x = 500, y = 0, z = 0, name = "Objective: Follow Professor Fig" }
cat_next(); cat_next(); t.run(0.1)
while not said[#said]:find("^Quest objective") do cat_next(); t.run(0.1) end
scan_walk()
assert(walked == "the objective", "the route's end uses the game's route: " .. tostring(walked))
print("scanner marker test passed")
