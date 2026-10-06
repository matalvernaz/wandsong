-- Offline test for subtitles.lua: a fake subtitle hook delivers lines; a description tied to
-- a line (matched loosely) is spoken after that line's length plus its delay, once.
local here = (debug.getinfo(1, "S").source:gsub("^@", ""):gsub("\\", "/"):match("^(.*)/[^/]+$")) or "."
package.path = here .. "/../../mod/Wandsong/Scripts/?.lua;" .. package.path
local loop
LoopAsync = function(ms, fn) loop = fn end
ExecuteInGameThread = function(fn) fn() end
Key = { F6 = 117, F7 = 118 }
ModifierKey = { CONTROL = 1, SHIFT = 2 }
RegisterKeyBind = function() end
local hook
RegisterHook = function(name, fn) hook = fn end
package.loaded["descriptions"] = {
    { after = "We must hurry, the carriage is waiting.", delay = 0.2, text = "Fig climbs into the carriage." },
}
local said = {}
local speech = require("speech")
speech.say = function(t) said[#said + 1] = t end
local subs = require("subtitles")
assert(hook, "subtitle hook registered")
local function line(text, dur)
    local data = { get = function() return { lineID = { ToString = function() return "L1" end },
                   DurationSeconds = dur, VoiceName = { ToString = function() return "Fig" end } } end }
    hook(nil, data, { get = function() return { ToString = function() return text end } end })
end
local function run(s) local t0 = os.clock() while os.clock() - t0 < s do loop(); local t = os.clock() while os.clock() - t < 0.02 do end end end
line("We must hurry! The carriage is waiting.", 0.5)   -- slightly different punctuation
run(0.4)
assert(#said == 0, "nothing before the line has ended")
run(0.8)
assert(said[1] == "Fig climbs into the carriage.", "description after the line: " .. tostring(said[1]))
line("We must hurry, the carriage is waiting.", 0.1)
run(0.6)
assert(#said == 1, "each description once")
assert(subs.similarity("Hello there, friend", "hello there friend") == 1, "similarity ignores punctuation")
print("subtitles test passed")
