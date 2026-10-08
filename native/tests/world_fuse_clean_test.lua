-- The crash fuse tells a crash from a quit (Oct 8): Alt+F4 in the middle of play leaves the
-- marker but no crash dump, and world features stay on; a crash dump at least as new as the
-- marker blows the fuse.
local t = dofile("native/tests/testlib.lua")
FindFirstOf = function() return nil end
FindAllOf = function() return {} end
StaticFindObject = function() return nil end
local files = require("files")
files.mod = "C:/Game/Phoenix/Binaries/Win64/Mods/Wandsong"
local MARKER = files.runtime("world_active.flag", true)
local asked = {}
local dump_time = 900
package.loaded.input_bridge = {
    focused = function() return true end,
    file_time = function(p) asked.marker = p; return 1000 end,
    newest = function(p) asked.dump = p; return dump_time end,
}
package.loaded.audio_bridge = { init = function() return true end, play_ui = function() end,
    listener = function() end, stop_all = function() end }
package.loaded.tips = { once = function() end }
package.loaded.guide = { welcome = function() return "Welcome" end }
local function write_marker() local f = assert(io.open(MARKER, "w")); f:write("x"); f:close() end
local function exists() local f = io.open(MARKER, "r"); if f then f:close(); return true end; return false end

write_marker()
local world = require("world")
assert(world.enabled(), "a quit without a crash dump leaves world features on")
assert(not exists(), "and clears the marker")
assert(asked.dump == "C:\\Game\\Phoenix\\Binaries\\Win64\\crash_*.dmp",
    "looks for UE4SS's dumps beside the game: " .. tostring(asked.dump))

-- A crash dump as new as the marker: the fuse blows, and the marker stays until resumed.
write_marker(); dump_time = 1000.5
package.loaded.world = nil
world = require("world")
assert(not world.enabled(), "a crash since the marker blows the fuse")
assert(exists(), "the marker stays until world features are resumed")
os.remove(MARKER)
print("world fuse clean test passed")
