-- Who may cut in (Oct 8: a burst of messages cut each other off). Speech answering a key the
-- player just pressed interrupts; what the mod says on its own waits its turn; alerts (an
-- attack to block, critical health) always cut in. The log line shows which: "say " cuts in,
-- "say+ " waits, "say! " is an alert.
local t = dofile("native/tests/testlib.lua")
local lines = {}
local real_print = print
print = function(s) lines[#lines + 1] = tostring(s) end
local speech = require("speech")
local function last() return lines[#lines] or "" end
speech.say("New Spell Unlocked: Basic Cast")
assert(last():find("say%+ New Spell"), "the mod's own speech waits: " .. last())
speech.note_key()
speech.say("Facing east")
assert(last():find("say Facing east"), "an answer to a key cuts in: " .. last())
speech.say("Queued anyway", true)
assert(last():find("say%+ Queued anyway"), "queue=true always waits: " .. last())
t.run(1)
speech.say("Tutorial text")
assert(last():find("say%+ Tutorial text"), "a second after the key, it waits: " .. last())
speech.alert("Protego, q")
assert(last():find("say! Protego"), "alerts cut in: " .. last())
print = real_print
print("speech test passed")
