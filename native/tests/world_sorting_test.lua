-- The Sorting Hat's house screen comes up in a scene the UI manager doesn't report, with the
-- player's cinematic flag off (Oct 9): the world opened over it and the arrows turned the
-- camera. Once menus have noted it (state.sorting_path), the gate counts it as a menu while it's
-- in the viewport, so the arrows walk the house menu; when it's gone, play resumes.
local t = dofile("native/tests/testlib.lua")
local objects = {}
local function obj(cls, path, props)
    props.IsValid = function() return true end
    props.GetFullName = function() return cls .. " " .. path end
    props.GetAddress = function() return path end
    props.GetClass = function() return { GetFName = function() return { ToString = function() return cls end } end } end
    props.IsA = function() return false end
    objects[path] = props
    return props
end
local ui = obj("UIManager", "/Game/UI", { IsInPreGameplayState = function() return false end,
    IsAsyncScreenLoadInProgress = function() return false end, GetInMenuTransition = function() return false end,
    InPauseMode = function() return false end })
obj("Biped_Player", "/Game/Player", { InCinematic = false,
    RootComponent = { RelativeLocation = { X = 0, Y = 0, Z = 0 } }, Controller = { ControlRotation = { Yaw = 0 } } })
local PATH = "/Engine/Transient.GameEngine_1:BP_PhoenixGameInstance_C_1.UI_BP_SortingHat_C_1"
local hat_up = true
obj("UI_BP_SortingHat_C", PATH, { IsInViewport = function() return hat_up end })
FindFirstOf = function(cls) if cls == "UIManager" then return ui elseif cls == "Biped_Player" then return objects["/Game/Player"] end end
FindAllOf = function() return {} end
StaticFindObject = function(path) return objects[path] end
package.loaded.audio_bridge = { init = function() return true end, play = function() end, play_ui = function() end,
    loop = function() end, stop = function() end, listener = function() end, stop_all = function() end }
package.loaded.tips = { once = function() end }
package.loaded.guide = { welcome = function() return "Welcome" end }
require("speech").say = function() end
local state = require("state")
local world = require("world")

t.run(8)
assert(world.in_game() and world.gameplay(), "in play")
state.sorting_path = PATH
t.run(0.5)
assert(state.ui_blocker == "sorting" and not world.in_game() and not world.gameplay(),
    "the house screen is a menu: " .. tostring(state.ui_blocker))
assert(world.not_ready_reason() == "That works in the world, not in menus or scenes.", world.not_ready_reason())
t.run(30)
assert(not world.in_game(), "for as long as it's up")
hat_up = false
t.run(0.5)
assert(state.sorting_path == nil, "gone: its path is forgotten")
t.run(6)
assert(world.in_game() and world.gameplay(), "and play resumes")
-- A screen that no longer resolves (destroyed) isn't up either.
hat_up = true
state.sorting_path = "/Engine/Transient.Gone"
t.run(0.5)
assert(state.sorting_path == nil and world.gameplay(), "a path that finds nothing closes nothing")
print("world sorting test passed")
