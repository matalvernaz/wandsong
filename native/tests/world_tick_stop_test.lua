-- The game stops ticking as a map load begins (the old world, the player included, is being
-- destroyed) and the dispatcher's fallback tick comes before the stall guard marks a load: the
-- world gate looked the player up there and the game crashed (Oct 8, 19:31 and 19:55). With no
-- game ticks, nothing looks the player up and the world counts as closed; a hitch changes
-- nothing else, and a longer stop is a load.
local t = dofile("native/tests/testlib.lua")
local hooks = {}
RegisterCustomEvent = function(name, fn) hooks[name] = fn end
local objects, lookups = {}, 0
local function obj(cls, path, props)
    props.IsValid = function() return true end
    props.GetFullName = function() return cls .. " " .. path end
    props.GetAddress = function() return path end
    objects[path] = props
    return props
end
local ui = obj("UIManager", "/Game/UI", { IsInPreGameplayState = function() return false end,
    IsAsyncScreenLoadInProgress = function() return false end, GetInMenuTransition = function() return false end,
    InPauseMode = function() return false end })
local pawn = obj("Biped_Player", "/Game/Player", { InCinematic = false,
    RootComponent = { RelativeLocation = { X = 120, Y = 230, Z = 340 } }, Controller = { ControlRotation = { Yaw = 45 } } })
FindFirstOf = function(cls)
    if cls == "UIManager" then return ui end
    if cls == "Biped_Player" then lookups = lookups + 1; return pawn end
end
FindAllOf = function() return {} end
StaticFindObject = function(path)
    if path == "/Game/Player" then lookups = lookups + 1 end
    return objects[path]
end
package.loaded.audio_bridge = { init = function() return true end, play_ui = function() end, play = function() end,
    listener = function() end, stop_all = function() end }
package.loaded.tips = { once = function() end }
package.loaded.guide = { welcome = function() return "Welcome" end }
require("speech").say = function() end
local state = require("state")
local world = require("world")

-- Blueprint ticks drive the dispatcher in play; a stall has only the async loop.
local function play(seconds)
    for _ = 1, math.floor(seconds / 0.05 + 0.5) do t.now = t.now + 0.05; hooks.Tick(); t.loop() end
end
local function stall(seconds)
    for _ = 1, math.floor(seconds / 0.05 + 0.5) do t.now = t.now + 0.05; t.loop() end
end
assert(hooks.Tick, "the dispatcher listens for Blueprint ticks")
play(7)
assert(world.in_game() and lookups > 0, "in play: the gate is open and finds the player")

lookups = 0
stall(1.2)
assert(not state.loading(), "1.2 s without ticks: before the stall guard, the window that crashed")
assert(lookups == 0, "no game ticks: the player is not looked up")
assert(not world.in_game(), "and the world counts as closed")
play(0.5)
assert(world.in_game() and lookups > 0, "ticks back after a hitch: open at once, no settling again")

lookups = 0
stall(3)
assert(state.loading() and lookups == 0, "a longer stop is a load, still without looking anything up")
play(2.5)
assert(not world.in_game(), "after the load, the gate settles first")
play(6)
assert(world.in_game(), "then opens")
print("world tick stop test passed")
