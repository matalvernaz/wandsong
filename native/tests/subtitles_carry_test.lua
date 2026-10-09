-- Audit A17: descriptions still to come when a scene is cut by a load are carried to the next
-- scene only when the story goes straight on (the title card, then Hogwarts at night). A save
-- loaded from a menu, another load, or a menu before the next scene leaves them behind, so an
-- unrelated scene never hears the old one's descriptions.
local t = dofile("native/tests/testlib.lua")
local events = {}
RegisterCustomEvent = function(name, fn) events[name] = fn end
package.loaded.descriptions = {
    { id = "Fig_20", after = "Wait. We do not know what",
      items = { { delay = 2, text = "A dragon swoops." }, { delay = 6, text = "The carriage breaks apart." } } } }
local said = {}
require("speech").say = function(s) said[#said + 1] = s end
require("subtitles")
local state = require("state")
local function line(text, dur, id)
    events.BPAddSubtitleEvent(nil, { get = function() return {
        lineID = { ToString = function() return id end }, DurationSeconds = dur,
        VoiceName = { ToString = function() return "Fig" end } } end },
        { get = function() return { ToString = function() return text end } end })
end
local function heard(words)
    for _, s in ipairs(said) do if s == words then return true end end
    return false
end
-- A scene whose line queues descriptions 1 and 5 s ahead.
local function scene()
    said = {}
    state.set_cinematic(false); t.run(3)
    state.set_cinematic(true); t.run(0.5)
    line("Wait. We do not know what -", 1, "Fig_20"); t.run(2)
end

-- The story goes straight on: the new map opens in play for ten seconds, then its scene comes
-- (as the title card did, Oct 8). The descriptions come with it.
scene()
state.mark_loading(2); t.run(0.2); state.set_cinematic(false); t.run(2)
t.run(10)
assert(not heard("A dragon swoops."), "nothing in the play between")
state.set_cinematic(true); t.run(2)
assert(heard("A dragon swoops."), "the next scene has them")

-- A save loaded from the pause menu, opening in a scene: nothing of the old scene.
scene()
state.ui_blocker = "InPauseMode"; state.paused = true; t.run(1)
state.mark_loading(2); t.run(0.2); state.set_cinematic(false)
state.ui_blocker, state.paused = nil, false; t.run(2.5)
state.set_cinematic(true); t.run(8)
assert(not heard("A dragon swoops.") and not heard("The carriage breaks apart."), "a save's scene hears nothing old")

-- Another load after the first (the audit's case: a new generation, then a silent scene).
scene()
state.mark_loading(2); t.run(0.2); state.set_cinematic(false); t.run(2)
state.generation = state.generation + 1
state.set_cinematic(true); t.run(8)
assert(not heard("A dragon swoops."), "another load drops what was carried")

-- A menu between the load and the next scene: dropped too.
scene()
state.mark_loading(2); t.run(0.2); state.set_cinematic(false); t.run(2.5)
state.ui_blocker = "InPauseMode"; t.run(0.5); state.ui_blocker = nil; t.run(0.5)
state.set_cinematic(true); t.run(8)
assert(not heard("A dragon swoops."), "a menu after the load drops what was carried")
print("subtitles carry test passed")
