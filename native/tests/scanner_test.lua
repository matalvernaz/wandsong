-- Offline test for scanner.lua: a fake world with a few named things; checks nearest-first
-- order, same-floor-first, wrap-around, categories, repeat with fresh distance, and a thing
-- that disappears.
local here = (debug.getinfo(1, "S").source:gsub("^@", ""):gsub("\\", "/"):match("^(.*)/[^/]+$")) or "."
package.path = here .. "/../../mod/Wandsong/Scripts/?.lua;" .. package.path

LoopAsync = function() end
ExecuteInGameThread = function(fn) fn() end
Key = { PAGE_UP = 33, PAGE_DOWN = 34, HOME = 36, F9 = 120 }
ModifierKey = { CONTROL = 1, SHIFT = 2 }
RegisterKeyBind = function() end

local things = {
    ["/Game/Fig"] = { kind = "person", name = "Professor fig", pos = { 400, 0, 0 } },
    ["/Game/Chest"] = { kind = "chest", name = "Chest", pos = { 0, 900, 0 } },
    ["/Game/Troll"] = { kind = "enemy", name = "Troll", pos = { -2000, 0, 0 } },
    ["/Game/Upstairs"] = { kind = "person", name = "Student", pos = { 200, 0, 600 } },   -- closer, but a floor up
}
local px, py, pz = 0, 0, 0
local tracked
package.loaded["world"] = {
    in_game = function() return true end,
    track = function(path) tracked = path end,
    position = function() return px, py, pz, 0 end,
    entries = function()
        local out = {}
        for path, t in pairs(things) do out[#out + 1] = { path = path, kind = t.kind, name = t.name, name_src = "test" } end
        return out
    end,
    locate = function(path) local t = things[path]; return t and { t.pos[1], t.pos[2], t.pos[3] } end,
    not_ready_reason = function() return "not now" end,
}
local said = {}
local faced
package.loaded.path = {
    face_to = function(path) faced = path end,
    objective = function() return nil end,
}
local speech = require("speech")
speech.say = function(t) said[#said + 1] = t end

require("scanner")
local run = {}
for _, a in pairs(require("keys").actions()) do run[a.id] = a.run end

run.scan_next()
assert(said[#said]:find("^Professor fig, 4 metres, ahead, 1 of 4"), said[#said])
assert(tracked == "/Game/Fig", "the thing named is the one tracked by sound")
run.scan_next()
assert(said[#said]:find("^Chest, 9 metres, right, 2 of 4"), said[#said])
assert(tracked == "/Game/Chest", "the next one takes over the tracking")
run.scan_next()
assert(said[#said]:find("^Troll, 20 metres, behind, 3 of 4"), said[#said])
run.scan_next()
assert(said[#said]:find("^Student, 6 metres, ahead, above, 4 of 4"), "other floor last: " .. said[#said])
run.scan_next()
assert(said[#said]:find("^Professor fig"), "wraps to the first: " .. said[#said])

-- Repeat gives a fresh distance after walking closer, and tracks it again (once reached, the
-- world lets it go).
px = 200
tracked = nil
run.scan_repeat()
assert(faced == "/Game/Fig", "Home faces the selected actor")
assert(said[#said]:find("^Professor fig, 2 metres"), "fresh distance: " .. said[#said])
assert(tracked == "/Game/Fig", "Home tracks it again")

-- Categories.
run.scan_cat_next()
assert(said[#said]:find("^People, 2 nearby"), said[#said])
assert(tracked == "/Game/Fig", "a category tracks its first thing")
run.scan_cat_next()
assert(said[#said]:find("^Enemies, 1 nearby"), said[#said])
assert(tracked == "/Game/Troll", tracked)

-- A thing that disappears is skipped.
run.scan_cat_prev(); run.scan_cat_prev()          -- back to everything
things["/Game/Chest"] = nil
px = 0
for _ = 1, 3 do run.scan_next() end
for _, t in ipairs(said) do end
assert(not said[#said]:find("Chest"), "gone thing skipped")
print("scanner test passed")
