-- The real description catalogue with subtitles.lua's corrections applied (Matt's playtest,
-- Oct 8): the potion isn't drunk for you, the ruins are named plainly before "Why would
-- someone have built this here?", and lines said in play before a scene hold their
-- descriptions for it.
local t = dofile("native/tests/testlib.lua")
RegisterCustomEvent = function() end
local subs = require("subtitles")
local list = subs.descriptions
assert(type(list) == "table" and #list > 100, "the real catalogue loads: " .. tostring(list and #list))
local function entry(after)
    for _, d in ipairs(list) do if d.after == after then return d end end
end
local function by_id(id)
    for _, d in ipairs(list) do if d.id == id then return d end end
end
local potion = entry("Take this. It's Wiggenweld Potion. That stuff'll right you in a second.")
assert(potion and potion.items[1].text:find("vial", 1, true), "the potion's hand-over is described")
for _, it in ipairs(potion.items) do assert(not it.text:find("drink", 1, true), "never drinks for you: " .. it.text) end
local ruins = entry("We're close now. It's just ahead.")
assert(ruins and ruins.items[1].text:find("ruins of a castle", 1, true), "the ruins in plain words: " .. tostring(ruins and ruins.items[1].text))
local there = entry("Almost there!")
assert(there and there.items[1].text:find("ruins", 1, true), "the ruins again as you reach them")
-- The knights wake in a scene of their own: held, three descriptions, the fight from "Look out!".
local knights = entry("It does follow the light.")
assert(knights and knights.hold and #knights.items == 3, "the knights' waking waits for its scene")
local look = by_id("EleazarFig_13089")
assert(look and #look.items == 2 and look.items[2].text:find("shatter", 1, true), "the fight is timed from Look out!")
assert(by_id("EleazarFig_13170") and by_id("EleazarFig_13170").hold, "the vault door's scene waits for you to reach it")
assert(by_id("EleazarFig_12942") and by_id("EleazarFig_12942").hold, "the clifftop waits for you to leave the Portkey cave")
assert(entry("I'm going to have to fight my way out of here.").hold, "the basin waits for the scene after the fight")
for _, d in ipairs(list) do
    for _, it in ipairs(d.items or {}) do
        assert(not it.text:find("sea stack", 1, true), "no jargon: " .. it.text)
        assert(not it.text:find("You raise the vial", 1, true), "never drinks for you: " .. it.text)
    end
end
print("descriptions test passed")
