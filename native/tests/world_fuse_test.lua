-- Crash fuse blown: world features stay off, but gameplay must still be told from menus so the
-- arrow keys never walk HUD widgets mid-gameplay (that crashed the game, Oct 6).
local t=dofile("native/tests/testlib.lua")
local f=assert(io.open(require("files").runtime("world_active.flag", true), "w")); f:write("x"); f:close()
local objects={}
local pregame=true
local ui={IsValid=function() return true end,GetFullName=function() return "UIManager /Game/UI" end,
    IsInPreGameplayState=function() return pregame end,IsAsyncScreenLoadInProgress=function() return false end,
    GetInMenuTransition=function() return false end,InPauseMode=function() return false end}
objects["/Game/UI"]=ui
local pawn_asked=false
local object_reads=0
FindFirstOf=function(cls)
    object_reads=object_reads+1
    if cls=="UIManager" then return ui end
    if cls=="Biped_Player" then pawn_asked=true end
end
FindAllOf=function() object_reads=object_reads+1; return {} end
StaticFindObject=function(path) object_reads=object_reads+1; return objects[path] end
package.loaded.audio_bridge={init=function() return true end,play_ui=function() end,listener=function() end,stop_all=function() end}
package.loaded.tips={once=function() end}
package.loaded.guide={welcome=function() return "Welcome" end}
local said={}
require("speech").say=function(s) said[#said+1]=s end
local world=require("world")
local state=require("state")
state.mark_loading(2)
t.run(1)
assert(object_reads==0 and not world.enabled(),"A06: crash-paused startup performs no object queries during a load")
assert(world.ui_busy() and not world.gameplay() and object_reads==0,"load status queries are object-free")
-- The dispatcher still ticks during an explicit mark, just as it can while the map changes.
t.run(1.2)
require("path")
local stepped=0
require("state").menu_step=function() stepped=stepped+1 end
t.run(2)
assert(not world.enabled() and not world.gameplay(),"main menu with the fuse blown is a menu")
t.action("where_am_i")()
assert(stepped==1,"up arrow steps the menu")
pregame=false
t.run(1)
assert(not world.in_game(),"world features stay off")
assert(world.gameplay(),"gameplay is still recognised")
assert(not pawn_asked,"the player is never looked up while the fuse is blown")
t.action("where_am_i")()
t.action("turn_around")()
assert(stepped==1,"arrow keys don't walk menus in gameplay")
assert(said[#said]:find("World features are off",1,true),"the player hears why")
object_reads=0
state.mark_loading(2)
t.run(1)
assert(object_reads==0,"A06: a later load also blocks recovery-mode UI lookups")
t.run(1.4)
assert(object_reads>0 and not world.enabled(),"safe menu queries resume after the load without enabling world features")
print("world fuse test passed")
