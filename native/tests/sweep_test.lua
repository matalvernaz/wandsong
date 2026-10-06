-- Offline test for dispatch.call_out: a fake game call that takes a registry reference to its
-- out table exactly as UE4SS 3.0.1 does (luaL_ref, Lua 5.4.4), never releasing it. call_out
-- must free exactly that slot, both when the free list is empty and when it isn't, and never
-- touch other entries.
local here = (debug.getinfo(1, "S").source:gsub("^@", ""):gsub("\\", "/"):match("^(.*)/[^/]+$") or ".")
package.path = here .. "/../../mod/Wandsong/Scripts/?.lua;" .. package.path
LoopAsync = function() end
ExecuteInGameThread = function(fn) fn() end
local d = require("dispatch")
local reg = debug.getregistry()

-- luaL_ref in Lua: free-list head at registry[3], else the next index past the length.
local function luaL_ref(v)
    local head = rawget(reg, 3)
    if head == nil then rawset(reg, 3, 0); head = 0 end
    local ref
    if head ~= 0 then ref = head; rawset(reg, 3, rawget(reg, head)) else ref = rawlen(reg) + 1 end
    rawset(reg, ref, v)
    return ref
end
local function game_call(out) return function() luaL_ref(out); return true end end

local keep = function() end
local keep_ref = luaL_ref(keep)

-- Empty free list: the reference goes past the end.
for _ = 1, 20 do
    local out = {}
    local ok = d.call_out(game_call(out), out)
    assert(ok, "call ran")
    for k, v in pairs(reg) do assert(v ~= out, "out table freed (append case), still at " .. tostring(k)) end
end

-- Non-empty free list: the reference reuses its head.
local spare = luaL_ref("spare")
rawset(reg, spare, rawget(reg, 3)); rawset(reg, 3, spare)   -- luaL_unref(spare)
local out = {}
d.call_out(game_call(out), out)
for _, v in pairs(reg) do assert(v ~= out, "out table freed (free-list case)") end

-- A call that errors after taking the reference still gets cleaned up.
local out2 = {}
local ok = d.call_out(function() luaL_ref(out2); error("boom") end, out2)
assert(not ok, "error reported")
for _, v in pairs(reg) do assert(v ~= out2, "out table freed after an error") end

assert(rawget(reg, keep_ref) == keep, "other references untouched")
assert(type(rawget(reg, 2)) == "table", "globals untouched")
local freed, missed = d.out_stats()
assert(freed == 22 and missed == 0, "freed " .. freed .. ", missed " .. missed)
print("call_out test passed")
