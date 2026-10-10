-- The native modules' Lua copy is built as UE4SS builds its own (native/lua_lock.cpp): C++
-- exceptions for Lua errors, and UE4SS's global lock when UE4SS 3.0.1 is loaded. Offline there
-- is no UE4SS.dll: no lock, and an error a module raises still reaches the caller's pcall,
-- thrown from one Lua copy and caught by another, as in the game. Windows only (the modules).
dofile("native/tests/testlib.lua")
if package.config:sub(1, 1) ~= "\\" then print("native lock test skipped (Windows only)"); return end
for _, name in ipairs({ "audio_bridge", "lifetime_bridge" }) do
    local ok, mod = pcall(require, name)
    assert(ok and type(mod) == "table", name .. " loads: " .. tostring(mod))
    local status = mod.lua_lock()
    assert(status == "no UE4SS.dll: no lock", name .. ": " .. tostring(status))
end
local audio = require("audio_bridge")
for _ = 1, 3 do
    local ok, err = pcall(audio.listener)
    assert(not ok and tostring(err):find("number expected", 1, true), "a module's error is caught: " .. tostring(err))
end
-- The state is sound afterwards.
local t = {}
for i = 1, 1000 do t[i] = tostring(i) end
collectgarbage()
assert(#t == 1000 and t[1000] == "1000")
print("native lock test passed")
