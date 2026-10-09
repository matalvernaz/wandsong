-- The vault's second statue puzzle shows three knights' reflections at once: they get one
-- sentence between them, not the same line three times (Oct 8), and likewise when revealed.
local t = dofile("native/tests/testlib.lua")
local said = {}
local function obj(cls, path, props)
    props.IsValid = function() return true end
    props.GetFullName = function() return cls .. " " .. path end
    return props
end
local pawn = obj("BP_Biped_Player_C", "/Game/Player", { RootComponent = { RelativeLocation = { X = 0, Y = 0, Z = 0 },
    RelativeRotation = { Pitch = 0, Yaw = 0, Roll = 0 } } })
local knights = {}
for i, x in ipairs({ -500, 0, 500 }) do
    local root = obj("CapsuleComponent", "/Game/Vault.Knight" .. i .. ".Root", { RelativeLocation = { X = x, Y = 800, Z = 100 },
        RelativeRotation = { Pitch = 0, Yaw = 270, Roll = 0 }, RelativeScale3D = { X = 0.75, Y = 0.75, Z = 0.75 } })
    knights[i] = { path = "/Game/Vault.BP_HogwartsProtector_C_" .. i, extra = {}, root = root,
        o = obj("BP_HogwartsProtector_C", "/Game/Vault.BP_HogwartsProtector_C_" .. i, { bPuzzleActive = true,
            bHasBeenReleased = false, bStatueVisible = false, bReflectionVisible = false, AlignToAngle = 270,
            TargetAngle = 180, CurrentAngle = 180, VFX_HintLine_Alpha = 0, RootComponent = root }) }
end
local reader, in_game = nil, true
package.loaded.world = {
    in_game = function() return in_game end, position = function() return 0, 0, 100, 0 end,
    pawn = function() return pawn end, sounds_enabled = function() return true end,
    on_scan = function(_, fn) reader = fn end,
    entries = function()
        if not in_game then return {} end
        local list = {}
        for _, k in ipairs(knights) do
            local l = k.root.RelativeLocation
            local e = { path = k.path, name = "Knight statue", x = l.X, y = l.Y, z = l.Z, extra = k.extra, kind = "statue" }
            reader(k.o, e)
            list[#list + 1] = e
        end
        return list
    end,
}
package.loaded.audio_bridge = { init = function() return true end, play = function() end, play_ui = function() end,
    loop = function() return true end, stop = function() end }
require("speech").say = function(s) said[#said + 1] = s end
require("statues")
local function count(fragment)
    local n = 0
    for _, s in ipairs(said) do if s:find(fragment, 1, true) then n = n + 1 end end
    return n
end

-- The floor changes: three reflections, no knights. One sentence, once.
for _, k in ipairs(knights) do k.o.bReflectionVisible = true end
t.run(5)
assert(count("Three knights' reflections show in the floor") == 1, "three reflections: one sentence")
assert(count("Only a knight's reflection") == 0, "not the single-knight line three times")
t.run(3)
assert(#said == 1, "said once: " .. table.concat(said, " | "))

-- Revelio shows all three: one introduction for the three.
for _, k in ipairs(knights) do k.o.bStatueVisible = true end
t.run(1)
assert(count("Three stone knights kneel here") == 1, "three revealed knights: one introduction")
assert(count("A stone knight kneels here") == 0, "not the single-knight introduction three times")
t.run(3)
assert(#said == 2, "introduced once: " .. table.concat(said, " | "))

-- Your light leads all three: explained once, not once per knight (Oct 9, said three times).
for _, k in ipairs(knights) do k.o.TargetActor = pawn end
t.run(6)
assert(count("The reflections now follow your light") == 1, "the light explained once: " .. table.concat(said, " | "))
assert(count("The reflection now follows your light") == 0, "not the single-knight line")
-- How many stand, as it changes (all three face south, 1.1 to 16 m of line each).
knights[2].o.TargetAngle = 270
t.run(1)
assert(said[#said] == "One of three stands.", "one stands: " .. tostring(said[#said]))
knights[1].o.TargetAngle, knights[3].o.TargetAngle = 270, 270
t.run(1)
assert(said[#said] == "All three stand.", "all three: " .. tostring(said[#said]))
local n = #said
t.run(3)
assert(#said == n, "said as it changes, not over and over")
print("statues group test passed")
