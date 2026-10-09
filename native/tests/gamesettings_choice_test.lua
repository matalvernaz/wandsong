-- Audit A11: a setting the first start switched on, then switched off by the player on the
-- Controls screen, stays off; settings the player left alone are still set again after the
-- game restores its saved copy.
local t = dofile("native/tests/testlib.lua")
local said = {}
local s = { AudioVisualizer = true, AccessibilityAudioCueOpacity = 1, SubtitlesEnabled = false,
    ShowTargetHighlights = false, saves = 0 }
s.IsValid = function() return true end
s.GetFullName = function() return "PhoenixGameSettings /Engine/Transient.PhoenixGameSettings_1" end
s.SetSubtitlesEnabled = function(self, v) self.SubtitlesEnabled = v end
s.SetShowTargetHighlights = function(self, v) self.ShowTargetHighlights = v end
s.SaveSettings = function(self) self.saves = self.saves + 1 end
local template = { IsValid = function() return true end, GetPhoenixGameSettings = function() return s end }
StaticFindObject = function() return template end
FindAllOf = function() return {} end
require("speech").say = function(x) said[#said + 1] = x end
local gs = require("gamesettings")

assert(gs.apply() and s.SubtitlesEnabled and s.ShowTargetHighlights, "the first start turns both on")
gs.toggle("subtitles")
assert(not s.SubtitlesEnabled and said[#said] == "Subtitles off", "switched off and said: " .. tostring(said[#said]))
-- The game puts back its saved copy while its menu loads: highlights come back off.
s.ShowTargetHighlights = false
gs.enforce()
assert(not s.SubtitlesEnabled, "the player's choice is not reversed")
assert(s.ShowTargetHighlights, "an untouched setting is still set again")
t.run(3)
assert(not s.SubtitlesEnabled, "nor by the watch at the next ticks")
-- Switching it back on is a choice too, and stays.
gs.toggle("subtitles")
assert(s.SubtitlesEnabled and said[#said] == "Subtitles on", "switched on again: " .. tostring(said[#said]))
gs.enforce()
assert(s.SubtitlesEnabled, "still on")
print("game settings choice test passed")
