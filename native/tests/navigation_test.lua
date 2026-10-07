local t = dofile("native/tests/testlib.lua")
local config=assert(io.open(require("files").input(),"w"))
config:write('AxisMappings=(AxisName="MoveForward",Key=I,Scale=1)\nActionMappings=(ActionName="AM_Jump",Key=J)\n')
config:close()
local px, py, pz, yaw = 0, 0, 0, 0
local points = {{X=0,Y=0,Z=0},{X=150,Y=0,Z=600}}
local function arr(pts) return setmetatable({GetArrayNum=function() return #pts end}, {__index=function(_,i) return pts[i] end}) end
local nav, nav_count, available = nil, 0, true
local mgr = { PathTS=arr(points), IsValid=function() return true end, GetFullName=function() return "Mgr /Game/Manager" end }
local pawn = {Controller={ControlRotation={Yaw=0}}}
local target = {1500,0,0}
local pressed, said = {}, {}
package.loaded.world = { in_game=function() return not require("state").loading() end, position=function() return px,py,pz,yaw end,
    pawn=function() return pawn end, locate=function() return target end, nearest=function() end,
    sounds_enabled=function() return true end }
package.loaded.audio_bridge={init=function() return true end, play=function() end, play_ui=function() end}
package.loaded.input_bridge={ focused=function() return true end, key=function(v,down) pressed[v]=down; return true end,
    mouse_move=function(dx) yaw=yaw+dx*0.15; pawn.Controller.ControlRotation.Yaw=yaw; return true end }
package.loaded.surroundings={profile=function() return "test step" end}
FindAllOf=function(c) return available and c=="BP_PathNavigationManager_C" and {mgr} or {} end
StaticFindObject=function(p)
    if not available then return nil end
    if p:find("NavigationSystem",1,true) then return {FindPathToLocationSynchronously=function() nav_count=nav_count+1; return nav and {PathPoints=arr(nav)} end} end
    return mgr
end
require("speech").say=function(s) said[#said+1]=s end
local path=require("path")
t.action("autowalk")(); t.run(0.3)
for _,s in ipairs(said) do assert(not s:find("Arrived"), "no arrival on another floor") end
t.action("autowalk")()

-- A chest gets a route around a corner; no path is an explicit failure.
nav={{X=0,Y=0,Z=0},{X=0,Y=1000,Z=0},{X=1500,Y=1000,Z=0},{X=1500,Y=0,Z=0}}
path.walk_to("/Game/Chest","Chest","chest")
assert(nav_count>0,"scanner targets query navigation")
t.run(0.8)
assert(yaw>50,"steers toward the first corner, not directly at the chest")
t.action("autowalk")()
nav=nil
path.walk_to("/Game/Chest","Chest","chest")
assert(said[#said]:find("no path"),"failed path explained")
assert(not pressed[73],"no movement after failed path")

-- A partial navmesh path stops at its reachable end and reports the remaining distance.
nav={{X=0,Y=0,Z=0},{X=0,Y=1000,Z=0}}
path.walk_to("/Game/Chest","Chest","chest")
py=1000; t.run(0.3)
assert(said[#said]:find("as close as the path goes"),"partial path is not reported as arrival")
assert(not pressed[73])
py=0

-- The close-enough rules for following a person must also respect another floor.
target={150,0,600}; nav=nil
local before=#said
path.walk_to("/Game/Fig","Professor Fig","person"); t.run(0.3)
for i=before+1,#said do assert(not said[i]:find("Arrived") and not said[i]:find("Caught up")) end
t.action("autowalk")(); target={1500,0,0}

-- Jump is held while forward remains down. Loading releases both immediately on its guard.
nav={{X=0,Y=0,Z=0},{X=1500,Y=0,Z=0}}
yaw=0; pawn.Controller.ControlRotation.Yaw=0
path.walk_to("/Game/Chest","Chest","chest")
t.run(1.5)
assert(pressed[74] and pressed[73],"remapped jump and forward overlap for climbing")
assert(pressed[32]==nil and pressed[87]==nil,"default keys never injected with remapped controls")
require("state").mark_loading(1)
available=false
t.run(0.6)
assert(not pressed[74] and not pressed[73],"load releases all synthetic keys")
t.run(1)
assert(path.objective()==nil,"old destination forgotten on load")
available=true
pz=0
path.walk_to("/Game/Chest","Chest","chest")
t.run(9, function() pz=pressed[74] and 100 or 0 end)
assert(not pressed[73] and not pressed[74],"jumping in place cannot keep walking forever")
assert(said[#said]:find("stuck"),"blocked walk explains why it stopped")
print("navigation test passed")
