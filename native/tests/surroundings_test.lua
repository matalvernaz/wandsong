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
local cm = setmetatable({}, { __index = function(_, k)
    if k == "MovementMode" then return mode end
    if k == "Velocity" then return { X = 300, Y = 0, Z = 0 } end
    if k == "Acceleration" then return { X = 1000, Y = 0, Z = 0 } end
end })
local pawn = { CharacterMovement = cm, RootComponent = { CapsuleHalfHeight = 90 } }
package.loaded["world"] = {
    in_game = function() return true end,
    pawn = function() return pawn end,
    position = function() return x, 0, 100, 0 end,
}

local step = 0
local kismet = {
    LineTraceSingle = function(self, ctx, s, e, ch, cx, ign, dbg, hit)
        -- Right side (positive Y) has a wall for the first 10 samples.
        if e.Y > 100 and math.abs(e.X - s.X) < 1 and step < 10 then
            hit.Distance = 150; hit.ImpactPoint = { X = s.X, Y = 150, Z = s.Z }; return true
        end
        -- Downward ray: ground 4 m below the feet (a drop-off).
        if e.Z < s.Z - 100 then
            hit.Distance = 520; hit.ImpactPoint = { X = e.X, Y = e.Y, Z = 10 - 400 }; return true
        end
        return false
    end,
}
StaticFindObject = function(p) return kismet end

require("surroundings")
local t0 = os.clock()
while os.clock() - t0 < 3.5 do
    x = x + 15            -- walking forward at 150 cm per 100 ms tick... roughly
    step = math.floor((os.clock() - t0) / 0.2)
    loop()
    local t = os.clock() while os.clock() - t < 0.05 do end
end
local counts = {}
for _, n in ipairs(played) do counts[n] = (counts[n] or 0) + 1 end
local keys = {}
for k, v in pairs(counts) do keys[#keys + 1] = k .. "=" .. v end
table.sort(keys)
print(table.concat(keys, " "))
assert(counts.step and counts.step > 3, "footsteps")
assert(counts["loop:wall1"], "a wall region loop")
assert(counts.opening == 1, "one opening when the right wall ends")
assert(not counts.ledge, "drop-off cue stays off until reliable")
local st = require("state")
assert(st.cues[1] and st.cues[1].text:find("Opening on your right"), "opening named for what-was-that")
print("surroundings test passed")
