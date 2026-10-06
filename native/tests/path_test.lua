-- Offline test for path.lua: a fake route around a corner, a fake controller that records
-- camera turns, and a fake input module. Checks the beacon pings along the route, autowalk
-- holds and releases the forward key, steers toward the route, and stops on arrival.
local here = (debug.getinfo(1, "S").source:gsub("^@", ""):gsub("\\", "/"):match("^(.*)/[^/]+$")) or "."
package.path = here .. "/../../mod/Wandsong/Scripts/?.lua;" .. package.path

local loop
LoopAsync = function(ms, fn) loop = fn end
ExecuteInGameThread = function(fn) fn() end
Key = { OEM_THREE = 192 }
ModifierKey = { CONTROL = 1, SHIFT = 2 }
RegisterKeyBind = function() end

local played, keys_sent, yaws, vks = {}, {}, {}, {}
local px, py, yaw
function yaw_turn(d) yaw = (yaw + d + 180) % 360 - 180; yaws[#yaws + 1] = yaw end
package.loaded["audio_bridge"] = {
    init = function() return true end,
    play = function(n, x, y) played[#played + 1] = { n = n, x = x, y = y }; return true end,
    play_ui = function(n) played[#played + 1] = { n = n }; return true end,
    loop = function() return true end, stop = function() end, stop_all = function() end,
}
package.loaded["input_bridge"] = {
    focused = function() return true end,
    key = function(vk, down) keys_sent[#keys_sent + 1] = down; vks[#vks + 1] = { vk = vk, down = down }; return true end,
    -- The fake camera turns 0.04 degrees per mouse step (the mod starts guessing 0.15).
    mouse_move = function(dx) yaw_turn(dx * 0.04); return true end,
}

-- Route: 20 m east, then 20 m north. The player walks along it as autowalk steers.
local route = { { X = 0, Y = 0, Z = 0 }, { X = 2000, Y = 0, Z = 0 }, { X = 2000, Y = 2000, Z = 0 } }
local arr = setmetatable({ GetArrayNum = function() return #route end }, { __index = function(t, i) return route[i] end })
local mgr = { PathTS = arr, GuidePathPoints = arr,
              IsValid = function() return true end,
              GetFullName = function() return "BP_PathNavigationManager_C /Game/Fake.Mgr" end }
FindAllOf = function(c) return c == "BP_PathNavigationManager_C" and { mgr } or {} end
StaticFindObject = function() return mgr end

px, py, yaw = 0, 0, 0
local controller = { ControlRotation = setmetatable({ Pitch = 0 }, { __index = function(_, k) if k == "Yaw" then return yaw end end }) }
function controller:SetControlRotation(r) yaw = r.Yaw; yaws[#yaws + 1] = r.Yaw end
local pawn = { Controller = controller }
package.loaded["world"] = {
    in_game = function() return true end,
    pawn = function() return pawn end,
    position = function() return px, py, 0, yaw end,
    nearest = function() return nil end,
    locate = function() return nil end,
    locate = function() return nil end,
}

require("path")
local actions = require("keys").actions()
local walk
for _, a in pairs(actions) do if a.id == "autowalk" then walk = a.run end end
assert(walk, "autowalk action registered")

-- The character only walks while the forward key is held.
function keys_held()
    for i = #vks, 1, -1 do if vks[i].vk == 0x57 then return vks[i].down end end
    return false
end
local function run(seconds, move, each)
    local last = 0
    local t0 = os.clock()
    while os.clock() - t0 < seconds do
        if each then each() end
        if move and not (type(move) == "function" and not move()) and keys_held() then
            px = px + math.cos(math.rad(yaw)) * 40
            py = py + math.sin(math.rad(yaw)) * 40
        end
        loop()
        if os.getenv('PATHDBG') and os.clock() - last > 0.5 then last = os.clock(); print(string.format('  at %.0f %.0f yaw %.0f', px, py, yaw)) end
        local t = os.clock() while os.clock() - t < 0.02 do end
    end
end

run(1.5)                          -- beacon only, standing at the start
local pings = 0
for _, p in ipairs(played) do if p.n == "ping" then pings = pings + 1 end end
assert(pings >= 1, "beacon pinged")
assert(played[1].x > 500, "first ping is along the route, east")

walk()
run(6, true)                      -- autowalk: should turn north at the corner and arrive
assert(keys_sent[1] == true, "forward key held")
assert(keys_sent[#keys_sent] == false, "forward key released at the end")
local turned_north = false
for _, y in ipairs(yaws) do if y > 60 then turned_north = true end end
assert(turned_north, "steered round the corner")
local arrived = false
for _, p in ipairs(played) do if p.n == "arrive" then arrived = true end end
assert(arrived, "arrived")
print(string.format("pings %d, turns %d, end at %.0f %.0f", pings, #yaws, px, py))

-- Escort: no route, the mission destination is a guide walking east ahead of the player.
for i = #route, 1, -1 do route[i] = nil end
local gx, gy, guide_walks = px + 1500, py, true
mgr.GetMissionDestinationLocation = function() return { X = gx, Y = gy, Z = 0 } end
local said = {}
local speech = require("speech")
local real_say = speech.say
speech.say = function(t, ...) said[#said + 1] = t; return real_say(t, ...) end
local function guide_step() if guide_walks then gx = gx + 6 end end   -- 3 m/s
run(3, false, guide_step)                                            -- the trail builds up
local holding = function() return vks[#vks] and vks[#vks].vk == 0x57 and vks[#vks].down end
walk()
assert(said[#said]:find("^Following"), "follow mode announced: " .. tostring(said[#said]))
local waited = false
run(4, holding, function() guide_step(); if not holding() and vks[#vks] and vks[#vks].vk == 0x57 then waited = true end end)
assert(waited, "waited behind the guide")
for _, t in ipairs(said) do assert(not t:find("Arrived"), "no arrival while following") end
guide_walks = false
run(8, holding)
assert(said[#said]:find("Caught up"), "stops when the guide stops: " .. tostring(said[#said]))

-- Blocked: forward held but the player doesn't move: jumps, then gives up.
gx, gy = px + 3000, py
route[1], route[2] = { X = px, Y = py, Z = 0 }, { X = px + 3000, Y = py, Z = 0 }
run(1.2)
walk()
run(5.5)
local jumps = 0
for _, k in ipairs(vks) do if k.vk == 0x20 and k.down then jumps = jumps + 1 end end
assert(jumps == 2, "two jumps when blocked, got " .. jumps)
assert(said[#said]:find("stuck"), "gave up stuck: " .. tostring(said[#said]))

-- No objective at all (start of the intro): autowalk follows the nearest person.
for i = #route, 1, -1 do route[i] = nil end
mgr.GetMissionDestinationLocation = function() return { X = 0, Y = 0, Z = 0 } end
local w = package.loaded["world"]
w.nearest = function() return { px + 1200, py, 0 }, "/Game/Fake.Bystander" end
local real_nearest = w.nearest
run(1.2)   -- the route refresh picks up the change
local n_played = #played
run(1.5)
for i = n_played + 1, #played do assert(played[i].n ~= "ping", "no beacon toward a passer-by") end
w.nearest = function() return { gx, gy, 0 }, "/Game/Fake.Guide" end
w.locate = function(path) if path == "/Game/Fake.Guide" then return { gx, gy, 0 } end end
gx, gy = px + 1200, py
walk()
assert(said[#said]:find("nearest person"), "guide fallback announced: " .. tostring(said[#said]))
run(4, true)
assert(said[#said]:find("Caught up"), "reached the standing person: " .. tostring(said[#said]))
print("path test passed")
