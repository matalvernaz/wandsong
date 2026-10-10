-- Host: the Lua inside the UE4SS running Wandsong. The native modules (Prism speech, sounds,
-- keys and mouse, clicks, the deletion record) each carry their own copy of Lua and work on
-- UE4SS's Lua state directly (UE4SS exports no lua_* functions), so they're only safe on the
-- exact Lua they were built with (native/CMakeLists.txt). UE4SS's version can't tell: its
-- rolling test build (UE4SS_v3.0.1-1164, Oct 9, 2026) still calls itself 3.0.1 but carries
-- Lua 5.4.7, where the 3.0.1 release has 5.4.4. So the version is read from UE4SS.dll itself
-- ("$LuaVersion: Lua 5.4.4", in every Lua build), two folders up from the mod in both UE4SS
-- layouts (Win64\Mods\Wandsong, Win64\ue4ss\Mods\Wandsong). On another Lua the native modules
-- stay unloaded, their users fall back as when one is missing (speech through the helper
-- program), and the player is told why.

local files = require("files")

local M = { BUILT_FOR = "5.4.4" }
M.NATIVE = { "prism_bridge", "audio_bridge", "input_bridge", "click_bridge", "lifetime_bridge" }

local function log(s) print("[Wandsong host] " .. s .. "\n") end

local MARK = "$LuaVersion: Lua "

--- The Lua version the UE4SS.dll at `path` carries ("5.4.4"), or nil and why not.
function M.lua_version(path)
    local f = io.open(path, "rb")
    if not f then return nil, "no UE4SS.dll at " .. path end
    local tail = ""
    while true do
        local chunk = f:read(1048576)
        if not chunk then break end
        local s = tail .. chunk
        local at = s:find(MARK, 1, true)
        local v = at and s:match("^(%d+%.%d+%.%d+)", at + #MARK)
        if v then f:close(); return v end
        tail = s:sub(-64)   -- a mark cut by the chunk's end is whole next time
    end
    f:close()
    return nil, "no Lua version in " .. path
end

--- Once, before anything loads a native module: on another Lua than the modules were built
--- for, they can't load. Returns false then (M.problem says what to tell the player).
function M.guard(path)
    path = path or ((files.mod:match("^(.*)/[^/]+/[^/]+$") or ".") .. "/UE4SS.dll")
    local v, why = M.lua_version(path)
    M.lua = v
    if not v then
        -- Can't tell (a renamed or moved file): load them, as before this check.
        log("UE4SS's Lua: unknown (" .. why .. "), loading the native modules")
        return true
    end
    if v == M.BUILT_FOR then
        log("UE4SS's Lua: " .. v)
        return true
    end
    local reason = "UE4SS has Lua " .. v .. ", Wandsong's native modules are built for " .. M.BUILT_FOR
    for _, name in ipairs(M.NATIVE) do
        package.preload[name] = function() error(reason, 0) end
    end
    M.problem = "This version of UE4SS isn't the one Wandsong needs, so its sounds, turning and " ..
                "clicks are off. Run Wandsong's setup to put back UE4SS 3.0.1."
    log(reason .. ": not loading them")
    return false
end

return M
