-- Remapped game keys. Audit A13: a mod check on a game key compares the key itself, not its
-- name (UE4SS says "DEL", the game "Delete"), so the stuck-hotspot interaction works on Delete,
-- Space, punctuation and number keys too; a failed try stays retryable. Audit A12: a game key
-- moved in Input.ini still works in the game until it restarts, and conflict checks say so.
local t = dofile("native/tests/testlib.lua")
Key.ONE, Key.OEM_PERIOD = 49, 190
local files = require("files")
local function write_input(lines)
    local f = assert(io.open(files.input(), "w"))
    f:write(table.concat(lines, "\n") .. "\n")
    f:close()
end
write_input({
    'ActionMappings=(ActionName="AM_Interact",Key=Delete,GroupName="OnFoot")',
    'ActionMappings=(ActionName="UMGMapScreenToggle",Key=M,GroupName="AccessingMenus")',
})
local bindings = require("bindings")

-- The same key under both names.
assert(bindings.same_key("DEL", "Delete") and bindings.same_key("SPACE", "SpaceBar"), "Delete and Space")
assert(bindings.same_key("OEM_PERIOD", "Period") and bindings.same_key("ONE", "One"), "punctuation and numbers")
assert(bindings.same_key("F", "F") and bindings.same_key("F5", "F5"), "letters and function keys")
assert(not bindings.same_key("D", "Delete") and not bindings.same_key("DEL", nil), "different or no key")

-- The stuck hotspot, with Interact on Delete.
local said, calls, reader, observer = {}, 0, nil, nil
local fail_next = true
local actor = { allowInteract = true, WantsToBeInteractable = false, IsActivated = true, bHotSpotActive = true,
    GetFullName = function() return "BP_AncientMagicHotSpot_C /Game/Vault.Gate" end,
    InteractionInitiated = function()
        calls = calls + 1
        if fail_next then fail_next = false; error("not ready") end
    end }
local entry = { path = "/Game/Vault.Gate", kind = "magic", x = 90, y = 0, z = 0, extra = {} }
package.loaded.world = { in_game = function() return true end, position = function() return 0, 0, 0, 0 end,
    pawn = function() return {} end, on_scan = function(_, fn) reader = fn end,
    entries = function() reader(actor, entry); return { entry } end }
package.loaded.feedback = { prompt_active = function() return false end }
FindAllOf = function(cls) if cls == "AncientMagicHotSpot" then return { actor } end return {} end
local keys = require("keys")
local observe = keys.observe
keys.observe = function(fn) observer = fn; observe(fn) end
require("speech").say = function(s) said[#said + 1] = s end
require("hotspots")
t.run(3)
assert(said[#said] == "Press delete to investigate.", "named as the remapped key: " .. tostring(said[#said]))
observer("delete", "DEL")
t.run(0.4)
assert(calls == 1, "Delete reaches the hotspot")
assert(said[#said] ~= "Investigating the ancient magic.", "a failed try isn't reported as working")
observer("delete", "DEL")
t.run(0.4)
assert(calls == 2 and said[#said] == "Investigating the ancient magic.", "and can be tried again")
observer("delete", "DEL")
t.run(0.4)
assert(calls == 2, "once it worked, once per hotspot and map")
observer("f", "F")
t.run(0.4)
assert(calls == 2, "F isn't Interact any more")

-- Map moved from M to J in Input.ini: the game still answers M until it restarts.
write_input({
    'ActionMappings=(ActionName="AM_Interact",Key=Delete,GroupName="OnFoot")',
    'ActionMappings=(ActionName="UMGMapScreenToggle",Key=J,GroupName="AccessingMenus")',
})
local id, when = bindings.conflict("M")
assert(id == "UMGMapScreenToggle" and when == "until restart", "M is still Map now: " .. tostring(id) .. " " .. tostring(when))
id, when = bindings.conflict("J")
assert(id == "UMGMapScreenToggle" and when == "from next start", "J is Map after a restart: " .. tostring(when))
id, when = bindings.conflict("Delete")
assert(id == "AM_Interact" and when == nil, "Delete is Interact now and then")
assert(bindings.conflict("Delete", "AM_Interact") == nil, "an action doesn't conflict with itself")
assert(bindings.conflict("K") == nil, "a free key is free")

-- The Controls menu explains which: a mod key on M is refused with the reason.
local capture
keys.capture_next = function(fn) capture = fn end
keys.action{ id = "test_action", name = "Test mod action", group = "Tests", default = "f8", run = function() end }
local controls = require("controls")
local function choose(prefix)
    for _, item in ipairs(controls.items()) do
        if item.text:sub(1, #prefix) == prefix then item.on_press(); return end
    end
    error("missing control " .. prefix)
end
local function heard(since, words)
    for i = since + 1, #said do if said[i]:find(words, 1, true) then return true end end
    return false
end
choose("Test mod action:")
local n = #said
capture("m", "M")
assert(heard(n, "is the game's key for") and heard(n, "until you restart the game"), "says the conflict lasts until restart")
assert(keys.combo_of("test_action") == "f8", "refused")
n = #said
capture("j", "J")
assert(heard(n, "from the next time you start the game"), "and the one to come")
capture("k", "K")
assert(keys.combo_of("test_action") == "k", "a free key is taken")
print("keys remap test passed")
