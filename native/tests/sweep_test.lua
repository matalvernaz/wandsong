local here = (debug.getinfo(1, "S").source:gsub("^@", ""):gsub("\\", "/"):match("^(.*)/[^/]+$") or ".") .. "/../../mod/Wandsong/Scripts"
package.path = here .. "/?.lua;" .. package.path
local loop
LoopAsync = function(ms, fn) loop = fn end
ExecuteInGameThread = function(fn) fn() end
local d = require("dispatch")
local reg = debug.getregistry()
local fkey, tkeys = #reg + 1, {}
reg[fkey] = function() end
for i = 1, 50 do local k = #reg + 1; reg[k] = {}; tkeys[#tkeys + 1] = k end
d.every(10, function() end)
local t = os.clock() while os.clock() - t < 0.05 do end
loop()
assert(type(reg[fkey]) == "function", "function ref kept")
for _, k in ipairs(tkeys) do assert(reg[k] == nil, "table ref cleared") end
assert(type(reg[2]) == "table", "globals kept")
print("sweep test passed, cleared " .. d.swept())

