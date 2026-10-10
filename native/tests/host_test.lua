-- The native modules only load on the Lua they were built with, read from UE4SS.dll itself:
-- UE4SS's test build calls itself 3.0.1 too but carries Lua 5.4.7.
local t=dofile("native/tests/testlib.lua")
local dir=os.getenv("WANDSONG_TEST_DIR")
local function dll(name,body)
    local p=dir.."/"..name
    local f=assert(io.open(p,"wb")); f:write(body); f:close()
    return p
end
local mark=" $LuaVersion: Lua %s  Copyright (C) 1994-2024 Lua.org, PUC-Rio $"
local release=dll("release.dll",("x"):rep(5000)..mark:format("5.4.4")..("y"):rep(5000))
-- The mark straddles the first megabyte's end: found anyway.
local test_build=dll("test_build.dll",("x"):rep(1048576-10)..mark:format("5.4.7")..("y"):rep(100))
local unmarked=dll("unmarked.dll",("x"):rep(3000))

local host=require("host")
assert(host.lua_version(release)=="5.4.4")
assert(host.lua_version(test_build)=="5.4.7","a mark across a chunk boundary is read whole")
local v,why=host.lua_version(unmarked)
assert(v==nil and why:find("no Lua version",1,true))
v,why=host.lua_version(dir.."/missing.dll")
assert(v==nil and why:find("no UE4SS.dll",1,true))

-- The release's Lua, or one that can't be read: the modules load as before.
assert(host.guard(release)==true and host.problem==nil and package.preload.audio_bridge==nil)
assert(host.guard(dir.."/missing.dll")==true and package.preload.audio_bridge==nil,"unknown: load as before")
-- The test build: none of them loads, and the player hears why.
assert(host.guard(test_build)==false)
for _,name in ipairs(host.NATIVE) do
    local ok,err=pcall(require,name)
    assert(not ok and tostring(err):find("Lua 5.4.7",1,true),name.." is kept out: "..tostring(err))
end
assert(host.problem and host.problem:find("setup",1,true),"the player is told how to fix it")
print("host test passed")
