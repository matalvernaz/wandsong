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
local before=stopped
t.action("world_toggle")()
assert(not world.sounds_enabled() and stopped>before,"sound toggle stops loops")
assert(world.in_game(),"sound toggle leaves scanner and navigation available")
pawn.RootComponent.RelativeLocation.X=500
t.run(0.3)
assert(world.position()==500,"position keeps updating without sounds")
t.action("world_toggle")(); assert(world.sounds_enabled())
require("state").mark_loading(0.5)
assert(not world.in_game(),"load closes public gate immediately")
t.run(0.3)
pawn.InCinematic=true
t.run(1)
assert(require("state").cinematic and not world.in_game(),"cutscene suppresses world")
pawn.InCinematic=false; t.run(6)
assert(world.in_game(),"gameplay resumes after cutscene")
print("world test passed")
