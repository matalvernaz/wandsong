-- The knight-statue puzzle: the spot comes from the game's own corridor box, the chime and
-- ticks follow the puzzle state, and nothing is said or played outside it.
local t = dofile("native/tests/testlib.lua")
local said, played, ticks = {}, {}, 0
local px, py, pz, in_game = 500, 0, 100, true
local function obj(cls, path, props)
    props.IsValid = function() return true end
    props.GetFullName = function() return cls .. " " .. path end
    return props
end
local pawn = obj("BP_Biped_Player_C", "/Game/Player", { RootComponent = { RelativeLocation = { X = 0, Y = 0, Z = 0 },
    RelativeRotation = { Pitch = 0, Yaw = 0, Roll = 0 } } })
local fig = obj("BP_Student_C", "/Game/Fig", { RootComponent = { RelativeLocation = { X = -300, Y = 300, Z = 100 },
    RelativeRotation = { Pitch = 0, Yaw = 0, Roll = 0 } } })
-- A kneeling knight at the origin facing +Y; its corridor runs 1 to 7 m in front of it.
local root = obj("CapsuleComponent", "/Game/Vault.Knight.Root", { RelativeLocation = { X = 0, Y = 0, Z = 100 },
    RelativeRotation = { Pitch = 0, Yaw = 90, Roll = 0 }, RelativeScale3D = { X = 1, Y = 1, Z = 1 } })
local box = obj("BoxComponent", "/Game/Vault.Knight.Corridor", { RelativeLocation = { X = 400, Y = 0, Z = 0 },
    RelativeRotation = { Pitch = 0, Yaw = 0, Roll = 0 }, RelativeScale3D = { X = 1, Y = 1, Z = 1 },
    BoxExtent = { X = 300, Y = 60, Z = 100 }, AttachParent = root })
local knight_path = "/Game/Vault.BP_HogwartsProtector_C_1"
local knight = obj("BP_HogwartsProtector_C", knight_path, { bPuzzleActive = false, bHasBeenReleased = false,
    bStatueVisible = false, bReflectionVisible = true, AlignToAngle = 90, TargetAngle = 0, CurrentAngle = 0,
    RootComponent = root, AlignmentCorridor = box, TargetActor = fig })
local entries = { { path = knight_path, kind = "statue", name = "Knight statue" } }
package.loaded.world = {
    in_game = function() return in_game end, position = function() return px, py, pz, 0 end,
    pawn = function() return pawn end, entries = function() return in_game and entries or {} end,
    resolve = function(p) if p == knight_path then return knight end end,
    sounds_enabled = function() return true end,
}
package.loaded.audio_bridge = { init = function() return true end,
    play = function(name, x, y, z) played[#played + 1] = { name = name, x = x, y = y, z = z } end,
    play_ui = function(name) if name == "tick" then ticks = ticks + 1 end end }
require("speech").say = function(s) said[#said + 1] = s end
local keys = require("keys")
keys.action{ id = "autowalk", name = "Autowalk", default = "shift+`", run = function() end }
local statues = require("statues")
local function heard(fragment)
    for _, s in ipairs(said) do if s:find(fragment, 1, true) then return true end end
    return false
end

-- Only the reflection shows: Revelio is suggested once, and nothing else happens yet.
t.run(1)
assert(heard("Cast Revelio with r"), "a hidden knight suggests Revelio with its real key")
local n = #said
t.run(2)
assert(#said == n, "the Revelio hint is said once")
assert(not statues.target() and #played == 0, "no spot or chime before the puzzle is active")

-- Revealed and active: the spot is the corridor's centre at the player's height.
knight.bStatueVisible, knight.bPuzzleActive = true, true
t.run(0.5)
local spot = statues.target()
assert(spot and math.abs(spot[1]) < 1 and math.abs(spot[2] - 400) < 1 and spot[3] == pz,
    "spot is the corridor centre, from the attached box's world transform")
assert(heard("Light Lumos with one") and heard("shift grave accent"), "the puzzle is explained with real keys")
t.run(1.5)
assert(#played > 0 and played[#played].name == "chime" and math.abs(played[#played].y - 400) < 1,
    "a chime sounds from the spot")
assert(ticks == 0, "no alignment ticks while the reflection follows someone else's light")

-- Into the corridor, without your own light yet.
px, py = 20, 300
t.run(0.5)
assert(statues.in_line(), "standing inside the corridor counts as in line")
assert(said[#said]:find("In line with the knight", 1, true) and said[#said]:find("Light Lumos", 1, true),
    "in line, and told to light Lumos")
local chimes = #played
t.run(1.5)
assert(#played == chimes, "no chime once you are on the spot")

-- Your light leads the reflection: ticks, and "Lined up" when it matches the knight.
knight.TargetActor = pawn
t.run(1)
assert(ticks > 0, "ticks while your light leads the reflection")
knight.CurrentAngle = 88
t.run(0.5)
assert(said[#said] == "Lined up.", "lined up once the reflection matches the knight")

-- Released: the puzzle is over.
knight.bHasBeenReleased = true
t.run(0.5)
assert(not statues.target() and not statues.in_line(), "a released knight ends the puzzle")
chimes, ticks = #played, 0
t.run(2)
assert(#played == chimes and ticks == 0, "silence after the puzzle")

-- A box centred on the knight itself: stand a few metres out on the side it faces.
local s = { cor = { c = { 0, 0, 100 }, ax = { { 0, 1, 0 }, { -1, 0, 0 }, { 0, 0, 1 } }, h = { 500, 60, 100 } },
            root = { 0, 0, 100 }, yaw = 90 }
knight.bHasBeenReleased, knight.AlignmentCorridor = false, obj("BoxComponent", "/Game/Vault.Knight.Corridor2", {
    RelativeLocation = { X = 0, Y = 0, Z = 0 }, RelativeRotation = { Pitch = 0, Yaw = 0, Roll = 0 },
    RelativeScale3D = { X = 1, Y = 1, Z = 1 }, BoxExtent = { X = 500, Y = 60, Z = 100 }, AttachParent = root })
px, py = 500, 0
t.run(0.5)
spot = statues.target()
assert(spot and math.abs(spot[1]) < 1 and math.abs(spot[2] - 300) < 1, "box on the knight: 3 m out in front")

-- Three corridors that cross at (1000, 1000): the crossing is where to stand.
local function cor(cx, cy, yaw)
    local r = math.rad(yaw)
    return { c = { cx, cy, 100 }, ax = { { math.cos(r), math.sin(r), 0 }, { -math.sin(r), math.cos(r), 0 }, { 0, 0, 1 } },
             h = { 600, 60, 100 } }
end
local q = statues.crossing({ { cor = cor(1000, 600, 90) }, { cor = cor(600, 1000, 0) },
    { cor = cor(1000 - 300, 1000 - 300, 45) } })
assert(q and math.abs(q[1] - 1000) < 1 and math.abs(q[2] - 1000) < 1, "corridors cross at one spot")

-- Leaving gameplay drops the puzzle at once.
in_game = false
assert(not statues.target(), "no puzzle spot outside gameplay, even before the next check")
t.run(0.5)
assert(not statues.target(), "no puzzle spot outside gameplay")
print("statues test passed")
