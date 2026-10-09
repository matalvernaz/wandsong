-- A hotspot that's ready but offers no prompt (the vault's gate, Oct 8 and 9): the mod says what
-- the prompt would, and F does it, once, on the object found afresh. Where the game shows its
-- own prompt, F is the game's.
local t = dofile("native/tests/testlib.lua")
local said, calls = {}, {}
local reader, observer
local px = 0
local flags = { allowInteract = true, WantsToBeInteractable = false, IsActivated = true, bHotSpotActive = true }
local actor = setmetatable({
    GetFullName = function() return "BP_AncientMagicHotSpot_C /Game/Vault.BP_AncientMagicHotSpot_Gate" end,
    InteractionInitiated = function(_, caller) calls[#calls + 1] = caller end,
}, { __index = function(_, k) return flags[k] end })
local entry = { path = "/Game/Vault.BP_AncientMagicHotSpot_Gate", kind = "magic", name = "Ancient magic hotspot",
                x = 90, y = 0, z = 0, extra = {} }
local pawn = { name = "player" }
package.loaded.world = {
    in_game = function() return true end, position = function() return px, 0, 0, 0 end,
    pawn = function() return pawn end,
    on_scan = function(fragment, fn) assert(fragment == "AncientMagicHotSpot"); reader = fn end,
    entries = function() reader(actor, entry); return { entry } end,
}
local prompt = false
package.loaded.feedback = { prompt_active = function() return prompt end }
FindAllOf = function(cls) if cls == "AncientMagicHotSpot" then return { actor } end return {} end
local keys = require("keys")
local observe = keys.observe
keys.observe = function(fn) observer = fn; observe(fn) end
require("speech").say = function(s) said[#said + 1] = s end
require("hotspots")
assert(reader and observer, "reads hotspots in the scan and listens for the interact key")

-- Standing in it, stuck: after a moment, what the prompt would say; once.
t.run(1)
assert(#said == 0, "a moment first: the game may still show its own prompt")
t.run(1.5)
assert(said[1] == "Press f to investigate.", "says what the missing prompt would: " .. tostring(said[1]))
t.run(3)
assert(#said == 1, "once per visit")
-- F does it, on the fresh object, as the player.
observer("F", "F")
t.run(0.3)
assert(#calls == 1 and calls[1] == pawn, "F starts the hotspot's interaction")
assert(said[#said] == "Investigating the ancient magic.", "and says so")
observer("F", "F")
t.run(0.3)
assert(#calls == 1, "once per hotspot and map")

-- A fresh map: where the game shows its own prompt, or the hotspot isn't stuck, F is the game's.
require("state").mark_loading(1)
t.run(2)
said, calls = {}, {}
prompt = true
t.run(3)
observer("F", "F")
t.run(0.3)
assert(#said == 0 and #calls == 0, "with the game's prompt up, the mod stays out of it")
prompt = false
flags.WantsToBeInteractable = true
t.run(3)
observer("F", "F")
t.run(0.3)
assert(#said == 0 and #calls == 0, "a hotspot that wants interaction gets the game's prompt")
flags.WantsToBeInteractable = false
px = 500
t.run(3)
observer("F", "F")
t.run(0.3)
assert(#said == 0 and #calls == 0, "out of its swirl: nothing")
print("hotspots test passed")
