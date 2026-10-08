-- The game's own accessibility settings: audio cues set at every start (unless switched off on
-- the Controls screen), the informational ones once at first install and then left to the
-- player, the rest only ever switched from the Controls screen. Saved through the game.
local t = dofile("native/tests/testlib.lua")
local said = {}
local s = { AudioVisualizer = false, AccessibilityAudioCueOpacity = 0, AccessibilityAudioCueScale = 0.5,
    SubtitlesEnabled = false, PathLineEnabled = true, ShowTargetName = true, ShowTargetHighlights = false,
    ShowHudBeacons = true, bAccessibilitySpellToggle = false, bEnableKeyboardSprintWalkToggle = true,
    AlwaysUseCameraAiming = true, saves = 0, camera_allowed = true }
s.IsValid = function() return true end
s.GetFullName = function() return "PhoenixGameSettings /Engine/Transient.PhoenixGameSettings_2147482207" end
local function setter(prop) return function(self, v) self[prop] = v end end
s.SetAudioVisualizer = setter("AudioVisualizer")
s.SetAccessibilityAudioCueOpacity = setter("AccessibilityAudioCueOpacity")
s.SetSubtitlesEnabled = setter("SubtitlesEnabled")
s.SetMiniMapPathEnabled = setter("PathLineEnabled")
s.SetShowTargetName = setter("ShowTargetName")
s.SetShowTargetHighlights = setter("ShowTargetHighlights")
s.SetShowHudBeacons = setter("ShowHudBeacons")
s.SetAccessibilitySpellToggle = setter("bAccessibilitySpellToggle")
s.SetEnableKeyboardSprintWalkToggle = setter("bEnableKeyboardSprintWalkToggle")
s.SetAlwaysUseCameraAiming = setter("AlwaysUseCameraAiming")
s.AllowOptionToSetAlwaysUseCameraAiming = function(self) return self.camera_allowed end
s.SaveSettings = function(self) self.saves = self.saves + 1 end
local template = { IsValid = function() return true end, GetPhoenixGameSettings = function() return s end }
StaticFindObject = function(p) if p == "/Script/Phoenix.Default__PhoenixGameSettings" then return template end end
FindAllOf = function() return {} end
require("speech").say = function(x) said[#said + 1] = x end
local gs = require("gamesettings")

-- First start: set at the first tick, saved once, said once.
t.run(1.2)
assert(s.AudioVisualizer == true and s.AccessibilityAudioCueOpacity > 0, "audio cues on")
assert(s.SubtitlesEnabled == true and s.ShowTargetHighlights == true, "the informational settings are turned on")
assert(s.bAccessibilitySpellToggle == false and s.AlwaysUseCameraAiming == true, "offered settings are never switched on their own")
assert(s.saves == 1, "saved once, got " .. s.saves)
t.run(7)
local notice = said[#said] or ""
assert(notice:find("audio cues, subtitles, target highlights", 1, true), "says what it turned on: " .. notice)
assert(not notice:find("path line", 1, true), "what was already on isn't mentioned")

-- A later start: the player switched subtitles off in the game's menu, and the game lost the
-- audio cues. Cues come back silently; subtitles stay off.
s.SubtitlesEnabled, s.AudioVisualizer = false, false
local n = #said
assert(gs.apply())
assert(s.AudioVisualizer == true, "audio cues are needed: set again at every start")
assert(s.SubtitlesEnabled == false, "the player's later choice stands")
assert(#said == n, "nothing said after the first start")

-- The Controls screen lists them all and switches them.
local function item(prefix)
    for _, it in ipairs(gs.items()) do if it.text:find(prefix, 1, true) == 1 then return it end end
end
assert(item("Audio cues").text:find(": on$"), "cues listed as on")
item("Audio cues").on_press()
assert(s.AudioVisualizer == false and said[#said] == "Audio cues off", "switched off: " .. tostring(said[#said]))
assert(gs.apply() and s.AudioVisualizer == false, "switched off on the Controls screen: stays off at the next start")
item("Audio cues").on_press()
assert(s.AudioVisualizer == true, "and back on")
item("Spell toggle").on_press()
assert(s.bAccessibilitySpellToggle == true and said[#said] == "Spell toggle on", "offered setting switched by the player")
local saves = s.saves
item("Sprint and walk").on_press()
assert(s.bEnableKeyboardSprintWalkToggle == false and s.saves == saves + 1, "each change is saved")
s.camera_allowed = false
assert(item("Camera aiming") == nil, "camera aiming only where the game allows changing it")

-- Without the game's settings object nothing is touched.
StaticFindObject = function() return nil end
assert(gs.apply() == false, "no settings object: nothing set")
assert(gs.items()[2].text:find("aren't available", 1, true), "the Controls screen says so")
print("game settings test passed")
