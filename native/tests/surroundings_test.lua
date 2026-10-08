local test_time = 0
os.clock = function() return test_time end
-- Offline test for surroundings.lua: fake world, fake pawn and a fake LineTraceSingle that
-- reports a wall on the right that ends, and a drop-off ahead. Run with luahost.exe.
local here = (debug.getinfo(1, "S").source:gsub("^@", ""):gsub("\\", "/"):match("^(.*)/[^/]+$")) or "."
package.path = here .. "/../../mod/Wandsong/Scripts/?.lua;" .. package.path
package.cpath = here .. "/../build/Release/?.dll;" .. package.cpath

local loop
LoopAsync = function(ms, fn) loop = fn end
ExecuteInGameThread = function(fn) fn() end
Key = { OEM_THREE = 192 }
ModifierKey = { CONTROL = 1, SHIFT = 2 }
RegisterKeyBind = function() end

-- Silent audio stand-in that records what was played.
local played = {}
package.loaded["audio_bridge"] = {
    init = function() return true, "fake" end,
    play = function(n) played[#played + 1] = n; return true end,
    play_ui = function(n) played[#played + 1] = n; return true end,
    loop = function(id, n) played[#played + 1] = "loop:" .. id; return true end,
    stop = function() end, stop_all = function() end,
}

local x = 0
local mode = 1
local vel = 300
local edge_x = 0
local cm = setmetatable({}, { __index = function(_, k)
    if k == "MovementMode" then return mode end
    if k == "Velocity" then return { X = vel, Y = 0, Z = 0 } end
    if k == "Acceleration" then return { X = 1000, Y = 0, Z = 0 } end
end })
local pawn = { CharacterMovement = cm, RootComponent = { CapsuleHalfHeight = 90 } }
package.loaded["world"] = {
    in_game = function() return true end,
    pawn = function() return pawn end,
    position = function() return x, 0, 100, 0 end,
}

local step = 0
local scenario = "drop"
-- Feet are at z 10 (pawn centre 100, half height 90).
local kismet = {
    LineTraceSingle = function(self, ctx, s, e, ch, cx, ign, dbg, hit)
        local function hitat(d, z) hit.Distance = d; hit.ImpactPoint = { X = s.X + (e.X - s.X) * 0, Y = s.Y, Z = z or s.Z }; return true end
        local down = e.Z < s.Z - 50
        local forward = math.abs(e.Z - s.Z) < 1 and e.X > s.X + 50 and math.abs(e.Y - s.Y) < 1
        if scenario == "drop" then
            -- Right side (positive Y) has a wall for the first 10 samples.
            if e.Y > 100 and math.abs(e.X - s.X) < 1 and step < 10 then
                hit.Distance = 150; hit.ImpactPoint = { X = s.X, Y = 150, Z = s.Z }; return true
            end
            -- Downward ray: ground 4 m below the feet (a drop-off).
            if down then hit.Distance = 520; hit.ImpactPoint = { X = e.X, Y = e.Y, Z = 10 - 400 }; return true end
            return false
        elseif scenario == "hop" then
            -- A 60 cm wall 80 cm ahead: knee ray (z 55) blocked, waist (z 120) clear.
            if forward and s.Z < 70 then return hitat(80) end
            if down then hit.Distance = s.Z - 70; hit.ImpactPoint = { X = e.X, Y = e.Y, Z = 70 }; return true end
            return false
        elseif scenario == "stairs" then
            -- Stairs going down: 58 cm lower for every metre out, never a sudden drop.
            if down then
                local z = 10 - math.max(0, e.X - x) * 0.58
                hit.Distance = s.Z - z; hit.ImpactPoint = { X = e.X, Y = e.Y, Z = z }; return true
            end
            return false
        elseif scenario == "edge" then
            -- Level floor up to edge_x, then 4 m down.
            if down then
                local z = e.X < edge_x and 10 or (10 - 400)
                hit.Distance = s.Z - z; hit.ImpactPoint = { X = e.X, Y = e.Y, Z = z }; return true
            end
            return false
        elseif scenario == "climb" then
            -- A 2 m ledge 80 cm ahead: knee and waist blocked, head height (z 340) clear.
            if forward and s.Z < 210 then return hitat(80) end
            if down then hit.Distance = s.Z - 210; hit.ImpactPoint = { X = e.X, Y = e.Y, Z = 210 }; return true end
            return false
        end
    end,
}
StaticFindObject = function(p) return kismet end

require("surroundings")
local function run(seconds, walk)
    local t0 = os.clock()
    while os.clock() - t0 < seconds do
        if walk then x = x + 15 end
        step = math.floor((os.clock() - t0) / 0.2)
        loop()
        test_time = test_time + 0.05
    end
end
local function count()
    local counts = {}
    for _, n in ipairs(played) do counts[n] = (counts[n] or 0) + 1 end
    return counts
end

run(3.5, true)
local counts = count()
local keys = {}
for k, v in pairs(counts) do keys[#keys + 1] = k .. "=" .. v end
table.sort(keys)
print(table.concat(keys, " "))
assert(counts.step and counts.step > 3, "footsteps")
assert(counts["loop:wall1"], "a wall region loop")
assert(counts.opening == 1, "one opening when the right wall ends")
assert(counts.ledge and counts.ledge <= 2, "a drop-off cue, at most one per 8 m of edge, got " .. tostring(counts.ledge))
local st = require("state")
local found = {}
for _, c in ipairs(st.cues) do found[#found + 1] = c.text end
local all = table.concat(found, " | ")
assert(all:find("Opening on your right"), "opening named for what-was-that: " .. all)
assert(all:find("Drop%-off ahead, about 4 metres"), "drop named: " .. all)

played = {}
scenario = "hop"
run(1.2, false)
counts = count()
assert(counts.hop == 1, "one hop cue, got " .. tostring(counts.hop))
assert(st.cues[1].text:find("Low obstacle ahead, 60 centimetres"), "hop named: " .. st.cues[1].text)
assert(counts.tick and counts.tick >= 1, "lined-up tick")

played = {}
scenario = "climb"
x = x + 2000
run(1.2, false)
counts = count()
assert(counts.climb == 1, "one climb cue, got " .. tostring(counts.climb))
assert(st.cues[1].text:find("Ledge ahead, 2.0 metres up"), "climb named: " .. st.cues[1].text)

-- Stairs going down get lower at every step out, but never suddenly: not a drop-off.
played = {}
scenario = "stairs"
x = x + 5000
run(2, true)
counts = count()
assert(not counts.ledge, "stairs aren't a drop-off, got " .. tostring(counts.ledge))

-- Running at an edge 6 m ahead: warned with room to stop. At 4.7 m/s the old single look
-- 1.2 m out, confirmed 0.4 s later, came after the edge (Oct 8, the vault's hotspot platform).
played = {}
scenario = "edge"
x = x + 5000
edge_x = x + 600
vel = 470
local warned_at
local t0 = os.clock()
while os.clock() - t0 < 2 and not warned_at and x < edge_x do
    x = x + 470 * 0.05
    loop()
    test_time = test_time + 0.05
    for _, n in ipairs(played) do if n == "ledge" then warned_at = x end end
end
assert(warned_at and edge_x - warned_at >= 150,
    "warned at least 1.5 m before the edge: " .. tostring(warned_at and (edge_x - warned_at)))
print("surroundings test passed")
