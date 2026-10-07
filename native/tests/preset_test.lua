local t = dofile("native/tests/testlib.lua")
local input=require("files").input()
local f=assert(io.open(input,"w"))
f:write([[ActionMappings=(ActionName="AM_Stupefy",Key=LeftMouseButton,GroupName="SpellsActions")
ActionMappings=(ActionName="AM_AimMode",Key=RightMouseButton,GroupName="SpellsActions")
ActionMappings=(ActionName="AM_AimMode",Key=H,GroupName="SpellsActions")
ActionMappings=(ActionName="UMGSkipCinematicOrConversation",Key=RightMouseButton,GroupName="Dialogue")
ActionMappings=(ActionName="LockOn",Key=CapsLock,GroupName="SpellsActions")
ActionMappings=(ActionName="UMGUINavigateUp",Key=Up,GroupName="HiddenMenuGroup")
]])
f:close()
UE4SS={GetVersion=function() return 3,0,1 end}
require("speech").say=function() end
local controls=require("controls")
for _,item in ipairs(controls.items()) do
    if item.text:find("Apply the no%-mouse preset") then item.on_press(); item.on_press() end
end
f=assert(io.open(input,"r")); local result=f:read("a"); f:close()
assert(result:find('ActionName="LockOn",Key=Period',1,true),"screen reader key moved")
assert(result:find('ActionName="UMGUINavigateUp",Key=W',1,true),"game no longer intercepts review arrows")
assert(result:find('ActionName="AM_Stupefy",Key=LeftMouseButton',1,true),"mouse retained")
local _,count=result:gsub('ActionName="AM_Stupefy",Key=Slash',"")
assert(count==1,"preset idempotent")
assert(result:find('ActionName="AM_AimMode",Key=H',1,true),"custom binding retained")
assert(not result:find("Key=RightShift",1,true),"custom binding not replaced by preset")
assert(result:find('ActionName="UMGSkipCinematicOrConversation",Key=Delete',1,true))
print("preset test passed")
