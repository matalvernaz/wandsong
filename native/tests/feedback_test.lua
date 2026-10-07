local t=dofile("native/tests/testlib.lua")
local events,said,sounds={}, {}, {}
RegisterCustomEvent=function(n,fn) events[n]=fn end
local playing,enabled,muted=true,true,false
package.loaded.world={in_game=function() return playing end,ui_busy=function() return false end,
    sounds_enabled=function() return enabled end,not_ready_reason=function() return "Not playing" end}
package.loaded.audio_bridge={init=function() return true end,play_ui=function(name,volume,pitch) sounds[#sounds+1]={name,pitch} end}
local speech=require("speech")
speech.say=function(s) said[#said+1]=s end
speech.is_muted=function() return muted end
local reads=0
StaticFindObject=function(p)
    reads=reads+1
    assert(playing and not require("state").loading(),"no widget reads outside gameplay")
    return {IsValid=function() return true end,ButtonPrompt={Visibility=0,RenderOpacity=1},
        ActionText={Text={ToString=function() return "<b>Examine</>" end}}}
end
local function ctx(cls,path) return {get=function() return {GetFullName=function() return cls.." "..(path or "/Game/HUD") end} end} end
local function val(v) return {get=function() return v end} end
require("feedback")
events.UpdateHealthBar(ctx("SomeOtherWidget"),val(0.1)); t.run(0.2)
assert(#said==0,"unrelated event ignored")
events.UpdateHealthBar(ctx("UI_BP_QuickHealthActions_C"),val(0.49)); t.run(0.2)
assert(said[#said]:find("below half"))
local n=#said
events.UpdateHealthBar(ctx("UI_BP_QuickHealthActions_C"),val(0.48)); t.run(0.2)
assert(#said==n,"health warning doesn't repeat on every update")
events.UpdateHealthBar(ctx("UI_BP_QuickHealthActions_C"),val(0.19)); t.run(0.2)
assert(said[#said]:find("critical"))
events.DisplayItemCount(ctx("UI_BP_QuickHealthActions_C"),val(3)); t.run(0.2)
t.action("gauges")(); assert(said[#said]:find("19 percent. 3 healing potions",1,true))
events.ReceiveIndicatorStart(ctx("BP_AttackIndicator_C"),val(true),val(false)); t.run(0.3)
events.ReceiveIndicatorStart(ctx("BP_AttackIndicator_C"),val(false),val(true)); t.run(0.3)
assert(#sounds==2 and sounds[1][2]>sounds[2][2],"different block and dodge cues")
enabled=false
events.ReceiveIndicatorStart(ctx("BP_AttackIndicator_C"),val(true),val(true)); t.run(0.3)
assert(#sounds==2,"world sound toggle respected")
enabled=true; muted=true
events.ReceiveIndicatorStart(ctx("BP_AttackIndicator_C"),val(true),val(true)); t.run(0.3)
assert(#sounds==2,"mute respected")
muted=false; playing=false
events.ShowButtonInfo(ctx("UI_BP_InteractBlip_C"),val(true)); t.run(0.3)
assert(reads==0,"prompt deferred until gameplay")
playing=true; t.run(0.3)
assert(said[#said]=="Examine: f","prompt includes interaction key")
n=#said
for i=1,3 do events.ShowButtonInfo(ctx("UI_BP_InteractBlip_C"),val(true)); t.run(3) end
assert(#said==n,"standing at a prompt does not repeat it")
events.ShowButtonInfo(ctx("UI_BP_InteractBlip_C"),val(false)); t.run(0.2)
events.ShowButtonInfo(ctx("UI_BP_InteractBlip_C"),val(true)); t.run(0.2)
assert(#said==n+1,"leaving and returning announces prompt again")
events.ShowButtonInfo(ctx("UI_BP_InteractBlip_C"),val(true))
require("state").mark_loading(0.5); n=reads; t.run(1)
assert(reads==n,"old prompt discarded on load")
t.action("gauges")(); assert(said[#said]:find("hasn't been reported"),"old save's health discarded")
print("feedback test passed")
