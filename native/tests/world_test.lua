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
package.loaded.audio_bridge={init=function() return true end,play_ui=function() end,play=function() end,listener=function() end,
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
-- Puzzle knights are statues until they come alive: no growl, no enemy tip, their own name.
local fighter=obj("BP_HogwartsProtector_C","/Game/Vault.Fighter",{bHasBeenReleased=false,bPuzzleActive=false,
    RootComponent={RelativeLocation={X=650,Y=230,Z=340}}})
fighter.GetClass=function() return {GetFName=function() return {ToString=function() return "BP_HogwartsProtector_C" end} end} end
local knight=obj("BP_HogwartsProtector_C","/Game/Vault.Knight",{bHasBeenReleased=false,bPuzzleActive=true,
    RootComponent={RelativeLocation={X=600,Y=230,Z=340}}})
knight.GetClass=function() return {GetFName=function() return {ToString=function() return "BP_HogwartsProtector_C" end} end} end
-- Every character comes from one NPC_Character pass, sorted by class.
local classes={}
local function class_obj(name) classes[name]=classes[name] or {IsValid=function() return true end,name=name}; return classes[name] end
local real_find=StaticFindObject
StaticFindObject=function(p)
    local c=p:match("^/Script/Phoenix%.(.+)$")
    if c then return class_obj(c) end
    return real_find(p)
end
local function is(o,...) local set={} for _,n in ipairs({...}) do set[n]=true end
    o.IsA=function(_,c) return set[c.name]==true end end
is(knight,"Enemy_Character"); is(fighter,"Enemy_Character")
local wolf=obj("BP_Wolf_C","/Game/Forest.Wolf",{RootComponent={RelativeLocation={X=900,Y=230,Z=340}}})
wolf.GetClass=function() return {GetFName=function() return {ToString=function() return "BP_Wolf_C" end} end} end
is(wolf,"Creature_Character")
local reads=0
world.on_scan("HogwartsProtector",function(a,e) reads=reads+1; e.extra.puzzle=a.bPuzzleActive end)
local queried={}
FindAllOf=function(cls) queried[cls]=(queried[cls] or 0)+1; if cls=="NPC_Character" then return {knight,fighter,wolf} end return {} end
local function kind_of(path) for _,e in ipairs(world.entries()) do if e.path==path then return e.kind,e.name,e end end end
t.run(8)
local kind,name,entry=kind_of("/Game/Vault.Knight")
assert(kind=="statue" and name=="Knight statue","a kneeling puzzle knight is a statue, not an enemy")
assert(entry.extra.puzzle==true and reads>0,"readers record from the fresh object during the pass")
assert(entry.x==600 and world.locate("/Game/Vault.Knight")[1]==600,"positions come from the pass's snapshot")
assert(kind_of("/Game/Vault.Fighter")=="enemy","a knight of the same class that isn't a puzzle is an enemy")
assert(kind_of("/Game/Forest.Wolf")=="beast","creatures are sorted by class")
assert(world.resolve==nil,"there is no lookup of world things by path")
assert(queried.NPC_Character>=3 and not queried.Enemy_Character and not queried.BP_Student_C,"one query for all characters")
-- Nothing between passes touches a thing: a moved knight is where the last pass saw it.
local before=world.locate("/Game/Vault.Knight")[1]
knight.RootComponent.RelativeLocation.X=700
local looked=0
local find=StaticFindObject
StaticFindObject=function(p) if p:find("Vault",1,true) then looked=looked+1 end return find(p) end
t.run(0.3)
assert(looked==0,"world things are never looked up by path")
StaticFindObject=find
t.run(1.5)
assert(world.locate("/Game/Vault.Knight")[1]==700,"the next pass refreshes the snapshot")
knight.bHasBeenReleased=true
t.run(1.5)
kind,name=kind_of("/Game/Vault.Knight")
assert(kind=="enemy" and name=="Stone knight","a knight that comes alive becomes an enemy")
-- The sentinel: a thing its pass no longer returns is gone at once.
FindAllOf=function(cls) if cls=="NPC_Character" then return {knight,wolf} end return {} end
t.run(1.5)
assert(kind_of("/Game/Vault.Fighter")==nil and world.locate("/Game/Vault.Fighter")==nil,"a vanished fighter is dropped")

-- Generic interactables take the name the level designer gave them; pots go to Objects.
local function cls_of(o, name) o.GetClass=function() return {GetFName=function() return {ToString=function() return name end} end} end end
local door=obj("BP_INT_Interact_C","/Game/Vault.Interact_VaultDoor",{RootComponent={RelativeLocation={X=700,Y=230,Z=340}}})
cls_of(door,"BP_INT_Interact_C")
local glow=obj("BP_INT_Interact_C","/Game/Vault.BP_INT_Interact_C_2147450001",{Text={ToString=function() return "Strange glow" end},
    RootComponent={RelativeLocation={X=800,Y=230,Z=340}}})
cls_of(glow,"BP_INT_Interact_C")
local anon=obj("BP_INT_Interact_C","/Game/Vault.BP_INT_Interact_C_2147450002",{RootComponent={RelativeLocation={X=900,Y=230,Z=340}}})
cls_of(anon,"BP_INT_Interact_C")
local pot=obj("BP_Int_BCProps_Pot_001_W_C","/Game/Ruins.BP_Int_BCProps_Pot_001_W_C_7",{RootComponent={RelativeLocation={X=650,Y=230,Z=340}}})
cls_of(pot,"BP_Int_BCProps_Pot_001_W_C")
FindAllOf=function(c) if c=="SimpleInteractObject" then return {door,glow,anon,pot} end return {} end
t.run(10)
kind,name=kind_of("/Game/Vault.Interact_VaultDoor")
assert(kind=="usable" and name=="Vault Door","placed name instead of Interact: "..tostring(name))
kind,name=kind_of("/Game/Vault.BP_INT_Interact_C_2147450001")
assert(name=="Strange glow","the thing's own label: "..tostring(name))
kind,name=kind_of("/Game/Vault.BP_INT_Interact_C_2147450002")
assert(name=="Something to use","an anonymous one is never called Interact: "..tostring(name))
kind,name=kind_of("/Game/Ruins.BP_Int_BCProps_Pot_001_W_C_7")
assert(kind=="prop" and name=="Pot","pots are objects, not things to use")

-- The quest-failed screen (Try Again / Exit) is a menu: the world stands down while it's up.
local fail_up=true
ui.MissionFailedScreen={IsValid=function() return true end, Visibility=0, IsInViewport=function() return fail_up end}
require("state").fail_screen_since=os.clock()
t.run(0.5)
assert(not world.in_game() and not world.gameplay(),"quest failed screen closes the world gate")
fail_up=false
t.run(6)
assert(world.in_game() and require("state").fail_screen_since==nil,"gone: back to the world")
print("world test passed")
