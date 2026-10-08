-- Quitting in the middle of play isn't a crash (Oct 8): the game instance's shutdown, which a
-- crash never reaches, clears the crash fuse's marker, so the next launch keeps world features.
local t = dofile("native/tests/testlib.lua")
FindFirstOf = function() return nil end
FindAllOf = function() return {} end
StaticFindObject = function() return nil end
package.loaded.audio_bridge = { init = function() return true end, play_ui = function() end,
    listener = function() end, stop_all = function() end }
package.loaded.tips = { once = function() end }
package.loaded.guide = { welcome = function() return "Welcome" end }
local MARKER = require("files").runtime("world_active.flag", true)
local world = require("world")
assert(world.enabled(), "no marker: world features on")
local shutdown = t.hooks["/Script/Engine.GameInstance:ReceiveShutdown"]
assert(shutdown, "the shutdown is hooked at startup")
local f = assert(io.open(MARKER, "w")); f:write("x"); f:close()
shutdown()
assert(not io.open(MARKER, "r"), "shutting down clears the marker")
print("world fuse clean test passed")
