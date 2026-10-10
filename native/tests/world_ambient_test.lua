-- The world's two sound layers in a busy corridor: what the scanner picked and enemies keep a
-- beat; everything else sounds once as it comes into range, again when passed close by (doors,
-- chests, collectibles), otherwise only every 20 s, quieter, spaced out, the nearest four of
-- each kind.
local t=dofile("native/tests/testlib.lua")
local objects={}
local function obj(cls,path,props)
    props.IsValid=function() return true end
    props.GetFullName=function() return cls.." "..path end
    props.GetAddress=function() return path end
    props.GetClass=function() return {GetFName=function() return {ToString=function() return cls end} end} end
    objects[path]=props
    return props
end
local ui=obj("UIManager","/Game/UI",{IsInPreGameplayState=function() return false end,
    IsAsyncScreenLoadInProgress=function() return false end,GetInMenuTransition=function() return false end,
    InPauseMode=function() return false end})
local pawn=obj("Biped_Player","/Game/Player",{InCinematic=false,RootComponent={RelativeLocation={X=0,Y=0,Z=0}},
    Controller={ControlRotation={Yaw=0}}})
FindFirstOf=function(cls) if cls=="UIManager" then return ui elseif cls=="Biped_Player" then return pawn end end
local classes={}
StaticFindObject=function(p)
    local c=p:match("^/Script/Phoenix%.(.+)$")
    if c then classes[c]=classes[c] or {IsValid=function() return true end,name=c}; return classes[c] end
    return objects[p]
end
local function at(x,y,o) o.RootComponent={RelativeLocation={X=x,Y=y,Z=0}}; return o end

-- Ten students along the corridor, 3 to 12 m away, an enemy, a door, a chest and a lever.
local people={}
for i=1,10 do
    local p=at(200+i*100,(i%2==0) and 150 or -150,obj("BP_Student_C","/Game/Hall.Student"..i,{}))
    p.IsA=function() return false end
    people[#people+1]=p
end
local goblin=at(-1000,0,obj("BP_Goblin_C","/Game/Hall.Goblin",{}))
goblin.IsA=function(_,c) return c.name=="Enemy_Character" end
local door=at(0,800,obj("BP_Door_Template_C","/Game/Hall.Door",{}))
local chest=at(0,-1100,obj("BP_OL_Chest_C","/Game/Hall.Chest",{}))
local lever=at(-600,0,obj("BP_Lever_C","/Game/Hall.Lever",{}))
local characters={goblin}
for _,p in ipairs(people) do characters[#characters+1]=p end
FindAllOf=function(cls)
    if cls=="NPC_Character" then return characters end
    if cls=="Door" then return {door} end
    if cls=="Container" then return {chest} end
    if cls=="SimpleInteractObject" then return {lever} end
    return {}
end

local plays,ui_plays={},{}
package.loaded.audio_bridge={init=function() return true end,listener=function() end,stop_all=function() end,
    play=function(name,x,y,z,volume,pitch) plays[#plays+1]={at=t.now,name=name,x=x,y=y,volume=volume,pitch=pitch} end,
    play_ui=function(name) ui_plays[#ui_plays+1]={at=t.now,name=name} end}
package.loaded.tips={once=function() end}
package.loaded.guide={welcome=function() return "Welcome" end}
require("speech").say=function() end
local world=require("world")

-- The gate settles, and every static class has had its pass (one class per pass).
t.run(18)
assert(world.in_game(),"gameplay gate opened")
local kinds={}
for _,e in ipairs(world.entries()) do kinds[e.kind]=(kinds[e.kind] or 0)+1 end
assert(kinds.person==10 and kinds.enemy==1 and kinds.door==1 and kinds.chest==1 and kinds.usable==1,
    "the corridor is tracked")

local function window(from,to,pred)
    local out={}
    for _,p in ipairs(plays) do if p.at>from and p.at<=to and pred(p) then out[#out+1]=p end end
    return out
end
local function background(p) return p.volume==0.45 end
local function at_xy(o) return function(p) local l=o.RootComponent.RelativeLocation; return p.x==l.X and p.y==l.Y end end

-- Thirty seconds standing in the corridor.
local start=t.now
t.run(30)
local bg=window(start,t.now,background)
local foe=window(start,t.now,function(p) return p.name=="enemy" end)
assert(#foe>=20,"the enemy keeps its growl: "..#foe)
for _,p in ipairs(foe) do assert(p.volume==0.7,"enemies at full volume") end
-- Six things are heard (four students, the door, the chest), each once as the passes found
-- it and again 20 s later: the old way it was about 80 sounds.
assert(#bg>=1 and #bg<=12,"background sounds in 30 s: "..#bg)
for i=2,#bg do assert(bg[i].at-bg[i-1].at>=0.79,"background sounds never bunch up") end
for _,p in ipairs(people) do
    local n=tonumber(p.GetFullName():match("Student(%d+)$"))
    local heard=#window(0,t.now,at_xy(p))
    if n<=4 then assert(heard>=1,"student "..n.." is among the nearest four")
    else assert(heard==0,"student "..n.." is past the nearest four") end
end
assert(#window(0,t.now,at_xy(chest))>=1,"the crowd doesn't hide the chest")
for _,p in ipairs(plays) do assert(p.name~="item" or p.pitch~=1.25,"a lever isn't heard until picked") end

-- Picked in the scanner: the lever, silent by kind, gets a steady higher sparkle at full volume.
world.track("/Game/Hall.Lever")
local picked_at=t.now
t.run(6)
local lever_plays=window(picked_at,t.now,function(p) return p.name=="item" and p.pitch==1.25 end)
assert(#lever_plays>=3,"the picked thing keeps a beat: "..#lever_plays)
for _,p in ipairs(lever_plays) do assert(p.volume==0.7,"the picked thing at full volume") end
assert(world.tracked()=="/Game/Hall.Lever")

-- Walking up to it: the arrival sound, then it's back in the background.
pawn.RootComponent.RelativeLocation.X=-450
t.run(2)
assert(world.tracked()==nil,"reached: no longer tracked")
assert(ui_plays[#ui_plays] and ui_plays[#ui_plays].name=="arrive","the arrival sound plays")
local reached_at=t.now
t.run(5)
assert(#window(reached_at,t.now,function(p) return p.name=="item" and p.pitch==1.25 end)==0,
    "a reached thing goes quiet")

-- Passing close to the door sounds it once, even though it was heard moments ago.
pawn.RootComponent.RelativeLocation.X=0
t.run(3)
local before=#window(0,t.now,at_xy(door))
pawn.RootComponent.RelativeLocation.Y=500
t.run(1.5)
assert(#window(0,t.now,at_xy(door))==before+1,"passing close to a door sounds it")
t.run(5)
assert(#window(0,t.now,at_xy(door))==before+1,"once, while staying close")

-- Picked while already beside it: no beat, no arrival sound.
pawn.RootComponent.RelativeLocation.Y=650
t.run(1)
local arrivals=#ui_plays
world.track("/Game/Hall.Door")
t.run(3)
assert(world.tracked()==nil and #ui_plays==arrivals,"a thing picked while beside it isn't tracked")
print(string.format("world ambient test passed (30 s in the corridor: %d background sounds, %d growls; %d beats of the picked lever)", #bg, #foe, #lever_plays))
