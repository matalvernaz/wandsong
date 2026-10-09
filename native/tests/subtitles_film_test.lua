-- The game's pre-rendered films show their lines as standalone subtitles, without line data
-- (the vault's Pensieve memory, Oct 9). They reach the mod as lines: read aloud when that's on,
-- logged, and descriptions keyed to their words follow them. A line the game updates again
-- with the same words counts once.
local t = dofile("native/tests/testlib.lua")
local events = {}
RegisterCustomEvent = function(name, fn) events[name] = fn end
package.loaded.descriptions = {
    { after = "We've done all that we can.", items = { { delay = 1.2, text = "Waterfalls of blue light pour down the walls." } } } }
local said = {}
require("speech").say = function(s) said[#said + 1] = s end
require("subtitles")
local state = require("state")
assert(events.BPAddStandaloneSubtitle and events.BPUpdateStandaloneSubtitle, "both standalone events are hooked")
local function film_line(event, text)
    events[event](nil, { get = function() return { ToString = function() return text end } end })
end
local function count(text)
    local n = 0
    for _, s in ipairs(said) do if s == text then n = n + 1 end end
    return n
end
state.set_cinematic(true); t.run(0.5)
film_line("BPAddStandaloneSubtitle", "<Name_Text>Percival Rackham:</> We've done all that we can.")
film_line("BPUpdateStandaloneSubtitle", "<Name_Text>Percival Rackham:</> We've done all that we can.")
t.run(5)
assert(count("Waterfalls of blue light pour down the walls.") == 1, "the film line keys its description, once")
-- Read aloud when subtitles are read.
t.action("read_subtitles")()
film_line("BPUpdateStandaloneSubtitle", "<Name_Text>Charles Rookwood:</> Then it is done.")
t.run(0.5)
assert(count("Charles Rookwood: Then it is done.") == 1, "read aloud, speaker and words: " .. tostring(said[#said]))
-- Empty updates (the box clearing) say nothing.
local n = #said
film_line("BPUpdateStandaloneSubtitle", "")
t.run(0.5)
assert(#said == n, "an empty update says nothing")
print("subtitles film test passed")
