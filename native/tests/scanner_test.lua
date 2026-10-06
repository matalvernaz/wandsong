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
package.loaded["world"] = {
    in_game = function() return true end,
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
local speech = require("speech")
speech.say = function(t) said[#said + 1] = t end

require("scanner")
local run = {}
for _, a in pairs(require("keys").actions()) do run[a.id] = a.run end

run.scan_next()
assert(said[#said]:find("^Professor fig, 4 metres, ahead, 1 of 4"), said[#said])
run.scan_next()
assert(said[#said]:find("^Chest, 9 metres, right, 2 of 4"), said[#said])
run.scan_next()
assert(said[#said]:find("^Troll, 20 metres, behind, 3 of 4"), said[#said])
run.scan_next()
assert(said[#said]:find("^Student, 6 metres, ahead, above, 4 of 4"), "other floor last: " .. said[#said])
run.scan_next()
assert(said[#said]:find("^Professor fig"), "wraps to the first: " .. said[#said])

-- Repeat gives a fresh distance after walking closer.
px = 200
run.scan_repeat()
assert(said[#said]:find("^Professor fig, 2 metres"), "fresh distance: " .. said[#said])

-- Categories.
run.scan_cat_next()
assert(said[#said]:find("^People, 2 nearby"), said[#said])
run.scan_cat_next()
assert(said[#said]:find("^Enemies, 1 nearby"), said[#said])

-- A thing that disappears is skipped.
run.scan_cat_prev(); run.scan_cat_prev()          -- back to everything
things["/Game/Chest"] = nil
px = 0
for _ = 1, 3 do run.scan_next() end
for _, t in ipairs(said) do end
assert(not said[#said]:find("Chest"), "gone thing skipped")
print("scanner test passed")
