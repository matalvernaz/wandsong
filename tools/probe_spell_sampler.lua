-- Records the spell-learning lesson every 100 ms for 25 s into spell_samples.txt (mod folder):
-- the wand's input, the spark's position, speed and segment, the chasing spark, checkpoints.
-- Read-only apart from the file. Run during a lesson with tools\dev.ps1.
-- It stops by itself when the lesson screen goes. (Its first version called IsValid on the
-- closed screen and crashed the game, Oct 7 08:45: never IsValid a looked-up widget before
-- checking that its full name still matches.)
local dispatch, files = require("dispatch"), require("files")
local path
for _, o in ipairs(FindAllOf("SpellMiniGameBase") or {}) do
    local n = o:GetFullName()
    if not n:find("Default__", 1, true) then path = n:match("^%S+%s+(.+)$") end
end
if not path then return "no spell lesson on screen" end
local out = io.open(files.runtime("spell_samples.txt"), "w")
local t0 = os.clock()
local function v2(v) local ok, s = pcall(function() return string.format("%.1f,%.1f", v.X, v.Y) end); return ok and s or "?" end
local function num(fn) local ok, v = pcall(fn); return ok and type(v) == "number" and string.format("%.3f", v) or "?" end
local seen_segments = {}
dispatch.every(100, function()
    if os.clock() - t0 > 25 then out:close(); return true end
    local w = StaticFindObject(path)
    local full
    pcall(function() full = w:GetFullName() end)
    if not full or full:match("^%S+%s+(.+)$") ~= path or not w:IsValid() then
        out:write(string.format("%.1f lesson closed\n", os.clock() - t0)); out:close(); return true
    end
    local s, b = w.PlayerSpark, w.BadSpark
    local line = { string.format("%.1f", os.clock() - t0) }
    line[#line + 1] = "wait " .. tostring(pcall(function() return w:GetIsWaitingForStart() end) and w:GetIsWaitingForStart())
    line[#line + 1] = "active " .. tostring(w:GetIsMiniGameActive())
    line[#line + 1] = "window " .. tostring(w:GetIsInInputWindow())
    line[#line + 1] = "input " .. v2(w.PlayerSparkInput)
    line[#line + 1] = "lin " .. v2(s.LinearInput)
    line[#line + 1] = "run " .. tostring(s.IsRunning)
    line[#line + 1] = "pos " .. v2(s:GetPosition())
    line[#line + 1] = "vel " .. v2(s:GetVelocity())
    line[#line + 1] = "dir " .. v2(s:GetDirection())
    line[#line + 1] = "seg " .. num(function() return s:GetCurrentPathSegmentIndex() end)
    line[#line + 1] = "pct " .. num(function() return s:GetTotalDistanceAsPercent() end)
    line[#line + 1] = "bad " .. num(function() return b:GetTotalDistanceAsPercent() end)
    line[#line + 1] = "boost " .. tostring(s:GetIsBoosting())
    line[#line + 1] = "fail " .. v2(w.FailProgress)
    line[#line + 1] = "chase " .. num(function() return w.ThreatChaserDelay end)
    pcall(function()
        local seg = s:GetCurrentPathSegment()
        local key = string.format("%.0f,%.0f>%.0f,%.0f", seg.StartPoint.X, seg.StartPoint.Y, seg.EndPoint.X, seg.EndPoint.Y)
        if not seen_segments[key] then seen_segments[key] = true; line[#line + 1] = "NEWSEG " .. key end
    end)
    pcall(function()
        local c = w:GetCurrentCheckpointData()
        line[#line + 1] = string.format("cp %s idx %s win %s", tostring(c.InputAction), tostring(c.PathSplineIndex), v2(c.InputWindow))
    end)
    out:write(table.concat(line, " | ") .. "\n")
    out:flush()
end, "spell sampler")
return "sampling " .. path
