-- Read-only snapshot of every puzzle knight: its puzzle flags and angles, the light its
-- reflection follows, and the attachment chain of its alignment corridor, plus what
-- statues.lua makes of it. Run in the game with:
--   powershell -ExecutionPolicy Bypass -File tools\dev.ps1 -File tools\probe_statues.lua
local out = {}
local function add(s) out[#out + 1] = s end
local function f(v)
    if type(v) == "number" then return string.format("%.1f", v) end
    return tostring(v)
end
local function v3(v)
    local ok, s = pcall(function() return string.format("%.2f %.2f %.2f", v.X, v.Y, v.Z) end)
    return ok and s or "?"
end
local function r3(v)
    local ok, s = pcall(function() return string.format("p%.1f y%.1f r%.1f", v.Pitch, v.Yaw, v.Roll) end)
    return ok and s or "?"
end
local function name(o)
    local ok, n = pcall(function() return o:GetFullName() end)
    return ok and n or "none"
end
local function read(o, prop)
    local ok, v = pcall(function() return o[prop] end)
    if ok then return v end return nil
end
local world, statues = require("world"), require("statues")
local px, py, pz, yaw = world.position()
add(string.format("player %.0f %.0f %.0f yaw %.0f", px, py, pz, yaw))
local t = statues.target()
add("statues.target: " .. (t and string.format("%.0f %.0f %.0f %s", t[1], t[2], t[3], t.name) or "none") ..
    ", in line " .. tostring(statues.in_line()))
for _, k in ipairs(FindAllOf("BP_HogwartsProtector_C") or {}) do
    local n = name(k)
    if not n:find("Default__", 1, true) then
        add("knight " .. n)
        for _, p in ipairs({ "bPuzzleActive", "bHasBeenReleased", "bStatueVisible", "bReflectionVisible",
                             "bReleaseOnAlignment", "AlignToAngle", "TargetAngle", "CurrentAngle", "InterpSpeed",
                             "VFX_BoxLength", "VFX_HintLine_Alpha", "SpecialSelectionStarted", "ProtegoTutorialSetup" }) do
            add("  " .. p .. " = " .. f(read(k, p)))
        end
        add("  TargetActor = " .. name(read(k, "TargetActor")))
        local root = read(k, "RootComponent")
        add("  root " .. name(root) .. " at " .. v3(read(root, "RelativeLocation")) .. " " .. r3(read(root, "RelativeRotation")))
        local rr = read(k, "ReflectionRotator")
        add("  ReflectionRotator " .. r3(read(rr, "RelativeRotation")) .. " parent " .. name(read(rr, "AttachParent")))
        local c, depth = read(k, "AlignmentCorridor"), 0
        if c then add("  BoxExtent " .. v3(read(c, "BoxExtent"))) end
        while c and depth < 8 do
            local ok, valid = pcall(function() return c:IsValid() end)
            if not ok or not valid then break end
            add(string.format("  chain %d %s loc %s rot %s scale %s abs %s/%s/%s", depth, name(c), v3(read(c, "RelativeLocation")),
                r3(read(c, "RelativeRotation")), v3(read(c, "RelativeScale3D")), tostring(read(c, "bAbsoluteLocation")),
                tostring(read(c, "bAbsoluteRotation")), tostring(read(c, "bAbsoluteScale"))))
            c, depth = read(c, "AttachParent"), depth + 1
        end
        local w = statues.world_of(read(k, "AlignmentCorridor"))
        if w then
            add(string.format("  corridor world centre %.0f %.0f %.0f, x axis %.2f %.2f %.2f, y axis %.2f %.2f %.2f",
                w.loc[1], w.loc[2], w.loc[3], w.ax[1][1], w.ax[1][2], w.ax[1][3], w.ax[2][1], w.ax[2][2], w.ax[2][3]))
        end
    end
end
return table.concat(out, "\n")


