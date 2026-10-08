-- The real description catalogue with subtitles.lua's corrections applied (Matt's playtest,
-- Oct 8): the potion isn't drunk for you, and the ruins are named plainly before "Why would
-- someone have built this here?".
local t = dofile("native/tests/testlib.lua")
RegisterCustomEvent = function() end
local subs = require("subtitles")
local list = subs.descriptions
assert(type(list) == "table" and #list > 100, "the real catalogue loads: " .. tostring(list and #list))
local function entry(after)
    for _, d in ipairs(list) do if d.after == after then return d end end
end
local potion = entry("Take this. It's Wiggenweld Potion. That stuff'll right you in a second.")
assert(potion and #potion.items == 1, "the potion entry keeps only the hand-over")
for _, it in ipairs(potion.items) do assert(not it.text:find("drink", 1, true), "never drinks for you") end
local ruins = entry("We're close now. It's just ahead.")
assert(ruins and ruins.items[1].text:find("ruins of a castle", 1, true), "the ruins in plain words: " .. tostring(ruins and ruins.items[1].text))
local there = entry("Almost there!")
assert(there and there.items[1].text:find("ruins", 1, true), "the ruins again as you reach them")
for _, d in ipairs(list) do
    for _, it in ipairs(d.items or {}) do
        assert(not it.text:find("sea stack", 1, true), "no jargon: " .. it.text)
    end
end
print("descriptions test passed")
