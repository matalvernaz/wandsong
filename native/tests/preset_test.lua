package.path = "C:/claudeProjects/wandsong/mod/Wandsong/Scripts/?.lua;" .. package.path
LoopAsync = function() end; ExecuteInGameThread = function(f) f() end; RegisterKeyBind = function() end
ModifierKey = { SHIFT = 1, CONTROL = 2 }; Key = { OEM_TWO = 191 }
local speech = require("speech"); speech.say = function(t) print("SAY: " .. t) end
local controls = require("controls")
controls.items()[1].on_press()
for _, it in ipairs(controls.items()) do
  if it.text:find("^Basic cast") or it.text:find("^Aim mode") or it.text:find("spell set") or it.text:find("^Skip") then print(it.text) end
end
