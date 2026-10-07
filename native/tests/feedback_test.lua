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
local translations={WoundCleaning="Wiggenweld Potion",Menu_NewSpellUnlocked="New Spell Unlocked",Stupefy="Basic Cast"}
StaticFindObject=function(p)
    if p=="/Script/Phoenix.Default__PhoenixBPLibrary" then
        return {IsValid=function() return true end,AVATranslate=function(_,key)
            return {ToString=function() return translations[key] or ("["..key.."]") end} end}
    end
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
-- The parry callout (the Protego tutorial waits on it with time stopped) is spoken with the key.
events.BlueprintSetParryType(ctx("UI_BP_CombatParry_ButtonCallout_C"),val(0))
events.OnIntroStarted(ctx("UI_BP_CombatParry_ButtonCallout_C")); t.run(0.2)
assert(said[#said]=="Protego, q","the parry callout names the Protego key: "..tostring(said[#said]))
events.OnIntroStarted(ctx("UI_BP_SomethingElse_C")); t.run(0.7)
assert(said[#said]=="Protego, q" and #said==#said,"other widgets' intros are ignored")
local before_dodge=#said
events.BlueprintSetParryType(ctx("UI_BP_CombatParry_ButtonCallout_C"),val(1))
events.OnIntroStarted(ctx("UI_BP_CombatParry_ButtonCallout_C")); t.run(0.2)
assert(#said==before_dodge+1 and said[#said]:find("^Dodge, "),"a dodge callout says dodge")
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
assert(said[#said]=="Press f to examine.","prompt says which key to press")
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
local function fstr(v) return {get=function() return {ToString=function() return v end} end} end
t.run(1); local n0=#said
events.OnAddPickupNotification(ctx("UI_BP_PhoenixHUDWidget_C"),fstr("Wiggenweld Potion"),fstr("icon"),val(2),val(false)); t.run(0.2)
assert(said[#said]=="Got 2 Wiggenweld Potion","item pickup announced with count")
events.OnAddPickupNotification(ctx("UI_BP_PhoenixHUDWidget_C"),fstr("<b>Moonstone</>"),fstr("icon"),val(1),val(false)); t.run(0.2)
assert(said[#said]=="Got Moonstone","single item without count or markup")
events.AddMoneyNotification(ctx("UI_BP_NotificationPanel_C"),{get=function() return {ItemCount=50} end}); t.run(0.2)
assert(said[#said]=="Got 50 Galleons","money announced")
events.OnAddPickupNotification(ctx("UI_BP_PhoenixHUDWidget_C"),fstr(""),fstr("icon"),val(1),val(false)); t.run(0.2)
assert(#said==n0+3,"nameless pickups stay silent")
-- The game hands over keys, not words (Oct 6: "Got 4 WoundCleaning", "Menu_NewSpellUnlocked").
events.OnAddPickupNotification(ctx("UI_BP_PhoenixHUDWidget_C"),fstr("WoundCleaning"),fstr("icon"),val(4),val(false)); t.run(0.2)
assert(said[#said]=="Got 4 Wiggenweld Potion","item keys are translated: "..said[#said])
events.OnAddSpecialItemNotification(ctx("UI_BP_PhoenixHUDWidget_C"),fstr("Stupefy"),fstr("icon"),val(1),fstr("Menu_NewSpellUnlocked")); t.run(0.2)
assert(said[#said]=="New Spell Unlocked: Basic Cast","unlock messages are translated: "..said[#said])
events.OnAddPickupNotification(ctx("UI_BP_PhoenixHUDWidget_C"),fstr("UnknownThing"),fstr("icon"),val(1),val(false)); t.run(0.2)
assert(said[#said]=="Got UnknownThing","an untranslatable key is said as it is")
print("feedback test passed")
