-- The knight-statue puzzle as an audio puzzle: notes carry what a sighted player sees (the
-- knight, and how far its reflection is turned from it); nothing marks or walks to the answer.
local t = dofile("native/tests/testlib.lua")
local said, notes, loops = {}, {}, {}
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
-- A kneeling knight at the origin facing +Y (yaw 90), scaled 0.75 like the vault's; its
-- corridor box is 550 cm out (412 after scaling), 400 x 75 half extents (300 x 56).
local root = obj("CapsuleComponent", "/Game/Vault.Knight.Root", { RelativeLocation = { X = 0, Y = 0, Z = 100 },
    RelativeRotation = { Pitch = 0, Yaw = 90, Roll = 0 }, RelativeScale3D = { X = 0.75, Y = 0.75, Z = 0.75 } })
local box = obj("BoxComponent", "/Game/Vault.Knight.Corridor", { RelativeLocation = { X = 550, Y = 0, Z = -100 },
    RelativeRotation = { Pitch = 0, Yaw = 0, Roll = 0 }, RelativeScale3D = { X = 1, Y = 1, Z = 1 },
    BoxExtent = { X = 400, Y = 75, Z = 180 }, AttachParent = root })
local knight_path = "/Game/Vault.BP_HogwartsProtector_C_1"
local knight = obj("BP_HogwartsProtector_C", knight_path, { bPuzzleActive = true, bHasBeenReleased = false,
    bStatueVisible = false, bReflectionVisible = false, AlignToAngle = 90, TargetAngle = 180, CurrentAngle = 180,
    VFX_HintLine_Alpha = 0, RootComponent = root, AlignmentCorridor = box, TargetActor = fig })
-- The world scan's contract: readers registered with on_scan run on fresh objects during a
-- pass and fill entry.extra; entries are snapshots. Here every entries() call is a pass.
local reader, passes, extra = nil, 0, {}
package.loaded.world = {
    in_game = function() return in_game end, position = function() return px, py, pz, 0 end,
    pawn = function() return pawn end, sounds_enabled = function() return true end,
    on_scan = function(fragment, fn) assert(fragment == "HogwartsProtector"); reader = fn end,
    entries = function()
        if not in_game then return {} end
        local e = { path = knight_path, name = "Knight statue", x = root.RelativeLocation.X,
                    y = root.RelativeLocation.Y, z = root.RelativeLocation.Z, extra = extra }
        e.kind = (knight.bPuzzleActive and not knight.bHasBeenReleased) and "statue" or "enemy"
        passes = passes + 1
        reader(knight, e)
        return { e }
    end,
}
package.loaded.audio_bridge = { init = function() return true end,
    play = function(name, x, y, z, vol, pitch) notes[#notes + 1] = { name = name, x = x, y = y, pitch = pitch } end,
    play_ui = function() end, loop = function(id, name, x, y) loops[id] = { name = name, x = x, y = y }; return true end,
    stop = function(id) loops[id] = nil end }
require("speech").say = function(s) said[#said + 1] = s end
local statues = require("statues")
assert(reader, "statues read knights during the world scan's passes")
local looked = 0
StaticFindObject = function(p) if tostring(p):find("Vault", 1, true) then looked = looked + 1 end end
local function heard(fragment)
    for _, s in ipairs(said) do if s:find(fragment, 1, true) then return true end end
    return false
end
local function count_loops() local n = 0; for _ in pairs(loops) do n = n + 1 end; return n end

-- Before the floor changes, the knight is invisible: no sound, nothing said.
t.run(4)
assert(#notes == 0 and #said == 0, "an invisible knight makes no sound")

-- The floor changes in a cutscene; only the reflection shows. Once play has settled again it's
-- described once, and the knight's note plays.
in_game = false
knight.bReflectionVisible = true
t.run(2)
in_game = true
t.run(1)
assert(not heard("reflection"), "nothing is described before play settles")
t.run(3)
assert(heard("Only a knight's reflection shows"), "a reflection without a knight is described")
local n = #said
t.run(3)
assert(#said == n, "described once")
assert(#notes > 0 and notes[#notes].name == "note" and notes[#notes].pitch == 1.0, "the knight's note plays from it")
assert(not heard("Revelio") and not heard("walks you"), "no solution is given away")

-- Revealed: the puzzle is explained in the mod's terms, once.
knight.bStatueVisible = true
t.run(1)
assert(heard("A stone knight kneels here"), "the revealed knight is introduced")
-- Fig's light leads the reflection: whose light it follows is said, and what the light does
-- (Matt, Oct 8: the pitches meant nothing without the idea of the light).
assert(heard("point at whoever's light leads it"), "the light is explained")
assert(heard("follows someone else's light now, not yours"), "whose light leads it is said")

-- Your light leads it: said once, with how to use the hum.
knight.TargetActor = pawn
knight.TargetAngle, knight.CurrentAngle = 180, 180
t.run(6)
assert(heard("now follows your light") and heard("the knight's hum"), "the reflection following you, and the hum, explained")
for _, s in ipairs(notes) do assert(s.pitch == 1.0, "only the knight's bell: no reflection pitches") end

-- Where the knight looks, heard: its hum sounds along its line of sight (east of it here, 1.1 to
-- 7.1 m out, its corridor), from the nearest point, only near the line (Oct 9: three knights).
assert(count_loops() == 0, "away from its line of sight: no hum")
px, py = 100, 400            -- a metre beside the line, 4 m out
t.run(0.5)
local id, hum = next(loops)
assert(hum and hum.name == "hum" and math.abs(hum.x) < 1 and math.abs(hum.y - 400) < 1,
    "near its line of sight: its hum, from the nearest point of the line")
px, py = 0, 900              -- on the line just past the corridor: the hum comes from its end
t.run(0.5)
id, hum = next(loops)
assert(hum and math.abs(hum.y - 712.5) < 1, "the line ends where the corridor does: " .. tostring(hum and hum.y))
px, py = 500, 0
t.run(0.5)
assert(count_loops() == 0, "away again: silent")

-- Lined up: on the line with your light; said once.
px, py = 0, 400
knight.TargetAngle, knight.CurrentAngle = 90, 90
t.run(1)
assert(said[#said] == "Lined up.", "lined up on its line of sight: " .. tostring(said[#said]))
n = #said
t.run(3)
assert(#said == n, "lined up is said once per alignment")
-- In line but past the corridor: which way to go.
px, py = 0, 900
t.run(1)
assert(said[#said] == "In line, but too far from the knight: step closer.", "too far: " .. tostring(said[#said]))
px, py = 500, 0
t.run(1)

-- What a glance shows, for the scanner: the knight's facing from where you stand, and which
-- way to step. You face north (yaw 0); the knight faces east (90); the light is south of it.
knight.TargetAngle, knight.CurrentAngle = 180, 180
local d = statues.describe(knight_path)
assert(d == "kneeling, facing to your right (east); its reflection points at you. To line it up, step to your right, round the knight",
    "describe: " .. tostring(d))
-- South of a knight facing east, facing it (north): round it to the right brings you east of it.
assert(statues.step_words(180, 90, 0) == "to your right", "south of an east-facing knight: right")
assert(statues.step_words(0, 90, 180) == "to your left", "north of it, facing it: left")
assert(statues.step_words(180, 90, 90) == "forward", "south of it, facing east: forward")
knight.TargetActor = fig
assert(statues.describe(knight_path):find("points at someone else's light, not yours", 1, true), "not your light")
knight.TargetActor = pawn

-- Released: silence.
knight.bHasBeenReleased = true
notes = {}
t.run(3)
assert(#notes == 0, "a knight that has come alive is no longer a puzzle")

-- Outside gameplay: silence, and nothing to describe.
knight.bHasBeenReleased = false
in_game = false
notes = {}
t.run(3)
assert(#notes == 0 and statues.describe(knight_path) == nil, "silent outside gameplay")
assert(looked == 0, "statues never look a knight up by path")
print("statues test passed")
