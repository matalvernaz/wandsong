local t = dofile("native/tests/testlib.lua")
local handlers = {}
RegisterKeyBind = function(key, mods, fn)
    if type(mods) == "function" then handlers[key] = mods end
end
local has_focus, broken_check = true, false
package.loaded.input_bridge = { focused = function()
    if broken_check then error("focus unavailable") end
    return has_focus
end }
local keys = require("keys")
local actions, observed, captured = 0, 0, 0
keys.action{ id = "test", name = "Test", default = "f8", run = function() actions = actions + 1 end }
keys.observe(function() observed = observed + 1 end)
local press = assert(handlers[Key.F8])

has_focus = false
press(); t.run(0.3)
assert(actions == 0 and observed == 0, "background typing never reaches actions or observers")
has_focus = true
press(); t.run(0.3)
assert(actions == 1 and observed == 1, "foreground keys still work")
press(); has_focus = false; t.run(0.3)
assert(actions == 1, "queued actions are discarded after losing focus")

keys.capture_next(function() captured = captured + 1 end)
press(); t.run(0.3)
assert(captured == 0, "background typing cannot rebind controls")
has_focus = true
press(); has_focus = false; t.run(0.3)
assert(captured == 0, "focus loss cancels a queued capture without consuming it")
has_focus = true
press(); press(); t.run(0.3)
assert(captured == 1, "capture survives focus loss and accepts exactly one foreground key")
broken_check = true
press(); t.run(0.3)
assert(actions == 1, "focus check errors fail closed")
print("keys test passed")
