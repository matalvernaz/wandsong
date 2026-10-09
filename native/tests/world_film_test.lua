-- The game's pre-rendered films (the Pensieve memories) play with the player's cinematic flag
-- off (the vault's memory, Oct 9). The cinematic Bink player says a film is playing: the world
-- gate counts it as a scene, so no world sound plays over it, and opens again when it ends. A
-- player said to play for 15 minutes is no longer believed.
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
local pawn = obj("Biped_Player", "/Game/Player", { InCinematic = false,
    RootComponent = { RelativeLocation = { X = 0, Y = 0, Z = 0 } }, Controller = { ControlRotation = { Yaw = 0 } } })
local playing = false
obj("BinkMediaPlayer", "/Game/Cinematics/SceneActions/PlayBinkMedia/MP_PlayBinkMedia.MP_PlayBinkMedia", {
    IsPlaying = function() return playing end,
    URL = { ToString = function() return "C:/Game/Content/Movies/FMV/CIN_Intro2_Pensieve_to_Escape/CIN_P0.bk2" end } })
FindFirstOf = function(cls) if cls == "UIManager" then return ui elseif cls == "Biped_Player" then return pawn end end
FindAllOf = function() return {} end
StaticFindObject = function(path) return objects[path] end
local stopped = 0
package.loaded.audio_bridge = { init = function() return true end, play = function() end, play_ui = function() end,
    loop = function() end, stop = function() end, listener = function() end, stop_all = function() stopped = stopped + 1 end }
package.loaded.tips = { once = function() end }
package.loaded.guide = { welcome = function() return "Welcome" end }
require("speech").say = function() end
local state = require("state")
local world = require("world")

t.run(8)
assert(world.in_game() and not state.cinematic, "in play")
playing = true
local n = stopped
t.run(0.5)
assert(not world.in_game() and state.cinematic, "a film is a scene: the gate shuts")
assert(stopped > n, "and the world's sounds stop")
assert(world.not_ready_reason() == "That works once this scene ends.", "keys say why")
t.run(60)
assert(not world.in_game() and state.cinematic, "for as long as it plays")
playing = false
t.run(7)
assert(world.in_game() and not state.cinematic, "the film over, play again")
-- Missing or unloaded: no film.
objects["/Game/Cinematics/SceneActions/PlayBinkMedia/MP_PlayBinkMedia.MP_PlayBinkMedia"].IsPlaying = function() error("gone") end
t.run(1)
assert(world.in_game(), "a player that can't answer isn't a film")
-- A player stuck "playing" never shuts the world for good.
objects["/Game/Cinematics/SceneActions/PlayBinkMedia/MP_PlayBinkMedia.MP_PlayBinkMedia"].IsPlaying = function() return playing end
playing = true
t.run(1)
assert(not world.in_game(), "playing again")
t.run(906)   -- 15 minutes, then the gate's 5 s settling
assert(world.in_game(), "after 15 minutes it's no longer believed")
print("world film test passed")
