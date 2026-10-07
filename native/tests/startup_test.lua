local t=dofile("native/tests/testlib.lua")
RegisterCustomEvent=function() end
RegisterLoadMapPostHook=function() end
FindFirstOf=function() end
FindAllOf=function() return {} end
StaticFindObject=function() end
-- Load the real entry point and drive timers before the game has created its objects.
-- The runner rejects any dispatcher task failure as well as Lua process failures.
require("main")
t.run(12)
assert(not require("world").in_game())
assert(require("speech").recent(1):find("Wandsong ready"))
print("startup test passed")
