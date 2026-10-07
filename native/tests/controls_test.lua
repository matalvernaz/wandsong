local t = dofile("native/tests/testlib.lua")
local files = require("files")
local f = assert(io.open(files.input(), "w"))
f:write([[ActionMappings=(ActionName="AM_Stupefy",Key=LeftMouseButton,GroupName="SpellsActions")
ActionMappings=(ActionName="AM_Dodge",Key=LeftControl,GroupName="OnFoot")
ActionMappings=(ActionName="AM_Jump",Key=J,GroupName="OnFoot")
ActionMappings=(ActionName="UMGMapScreenToggle",Key=M,GroupName="AccessingMenus")
AxisMappings=(AxisName="MoveForward",Key=I,Scale=1.000000)
AxisMappings=(AxisName="MoveForward",Key=K,Scale=-1.000000)
]])
f:close()
local keys, said = require("keys"), {}
require("speech").say = function(s) said[#said+1]=s end
keys.action{id="test_action",name="Test mod action",group="Tests",default="f8",run=function() end}
keys.action{id="shift_only",name="Shift only action",group="Tests",default="shift+f7",run=function() end}
local controls, bindings = require("controls"), require("bindings")
assert(bindings.forward()=="I" and bindings.virtual_key(bindings.key("AM_Jump","SpaceBar"))==74)
assert(bindings.movement_vk(75) and not bindings.movement_vk(nil))
assert(bindings.key("AM_Stupefy","Slash")==nil,"mouse-only action does not invent a key")
local capture
keys.capture_next=function(fn) capture=fn end
local function choose(prefix)
    for _,item in ipairs(controls.items()) do
        if item.text:sub(1,#prefix)==prefix then item.on_press(); return end
    end
    error("missing control "..prefix)
end
local function rejected(combo,enum,expected)
    local n=#said
    capture(combo,enum)
    local found=false
    for i=n+1,#said do if said[i]:find(expected,1,true) then found=true end end
    assert(found,"missing conflict explanation: "..expected)
end
choose("Test mod action:")
rejected("ctrl+shift+m","M","the game would react to it too")
rejected("shift+i","I","the game would react to it too")
rejected("insert","INS","belongs to your screen reader")
assert(keys.combo_of("test_action")=="f8","rejections preserve current key")
capture("shift+f6","F6")
assert(keys.combo_of("test_action")=="shift+f6")
choose("Dodge:")
rejected("f7","F7","Wandsong's key")
choose("Jump:")
capture("l","L")
assert(bindings.key("AM_Jump","SpaceBar")=="J","active key stays correct until restart")
assert(bindings.conflict("L")=="AM_Jump","next-launch key persisted")
local real_open=io.open
io.open=function(path,mode)
    if path==files.runtime("keys.ini",true) and mode=="w" then return nil,"read only" end
    return real_open(path,mode)
end
assert(not keys.rebind("test_action","f5"),"failed save reported")
assert(keys.combo_of("test_action")=="shift+f6","failed save restores original binding")
io.open=real_open
assert(io.open(files.input()..".wandsong-backup","r")):close()
print("controls test passed")
