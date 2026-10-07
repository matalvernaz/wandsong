local t=dofile("native/tests/testlib.lua")
local objects={}
local function obj(cls,path,props)
    props.IsValid=function() return true end
    props.GetFullName=function() return cls.." "..path end
    props.GetAddress=function() return path end
    objects[path]=props
    return props
end
local ui=obj("UIManager","/Game/UI",{IsInPreGameplayState=function() return false end,
    IsAsyncScreenLoadInProgress=function() return false end,GetInMenuTransition=function() return false end,
    InPauseMode=function() return false end})
local pawn=obj("Biped_Player","/Game/Player",{InCinematic=false,RootComponent={RelativeLocation={X=120,Y=230,Z=340}},
    Controller={ControlRotation={Yaw=45}}})
FindFirstOf=function(cls) if cls=="UIManager" then return ui elseif cls=="Biped_Player" then return pawn end end
FindAllOf=function() return {} end
StaticFindObject=function(path) return objects[path] end
local stopped=0
package.loaded.audio_bridge={init=function() return true end,play_ui=function() end,listener=function() end,
    stop_all=function() stopped=stopped+1 end}
package.loaded.tips={once=function() end}
package.loaded.guide={welcome=function() return "Welcome" end}
require("speech").say=function() end
local world=require("world")
t.run(7)
assert(world.in_game(),"gameplay gate opened")
local _, _, _, initial_yaw = world.position()
assert(initial_yaw == 45, "listener follows the camera heading")
pawn.Controller.ControlRotation.Yaw = { IsValid = function() return false end }
pawn.RootComponent.RelativeRotation = { Yaw = 90 }
t.run(0.3)
local _, _, _, fallback_yaw = world.position()
assert(fallback_yaw == 90, "missing camera rotation falls back to the player heading")
pawn.RootComponent.RelativeRotation.Yaw = {}
t.run(0.3)
local _, _, _, held_yaw = world.position()
assert(held_yaw == 90, "invalid rotation wrappers preserve the last usable heading")
pawn.Controller.ControlRotation.Yaw = 45
pawn.RootComponent.RelativeLocation.Y = {}
t.run(0.3)
local _, held_y = world.position()
assert(held_y == 230, "incomplete positions never reach the audio listener")
pawn.RootComponent.RelativeLocation.Y = 230
local before=stopped
t.action("world_toggle")()
assert(not world.sounds_enabled() and stopped>before,"sound toggle stops loops")
assert(world.in_game(),"sound toggle leaves scanner and navigation available")
pawn.RootComponent.RelativeLocation.X=500
t.run(0.3)
assert(world.position()==500,"position keeps updating without sounds")
t.action("world_toggle")(); assert(world.sounds_enabled())
before=stopped
require("speech").toggle_mute()
assert(stopped>before and not world.sounds_enabled(),"global mute immediately stops active sounds")
require("speech").toggle_mute()
require("state").mark_loading(0.5)
assert(not world.in_game(),"load closes public gate immediately")
t.run(0.3)
pawn.InCinematic=true
t.run(1)
assert(require("state").cinematic and not world.in_game(),"cutscene suppresses world")
assert(world.gameplay(),"a cutscene is not a menu: arrow keys must not walk widgets")
assert(world.not_ready_reason():find("scene",1,true),"the player hears it is a scene")
pawn.InCinematic=false; t.run(6)
assert(world.in_game(),"gameplay resumes after cutscene")
local generation=require("state").generation
pawn.GetAddress=function() return "replacement player" end
t.run(0.5)
assert(not world.in_game() and require("state").generation==generation+1,
    "an unexpected player replacement also settles before scanning")
t.run(6)
assert(world.in_game(),"replacement player settles")
print("world test passed")
