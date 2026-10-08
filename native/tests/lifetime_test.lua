-- The deletion record (lifetime_bridge.dll, the real module): an object is alive only while
-- watched with no deletion noted since its serial, and an address the game reuses never
-- revives an old serial. Outside the game, start() says why it can't register.
dofile("native/tests/testlib.lua")
if package.config:sub(1, 1) ~= "\\" then print("lifetime test skipped (Windows only)"); return end
local ok, life = pcall(require, "lifetime_bridge")
assert(ok and type(life) == "table", "lifetime_bridge builds and loads: " .. tostring(life))

local started, why = life.start()
assert(started == false and tostring(why):find("UE4SS", 1, true), "outside the game start() fails and says why: " .. tostring(why))
assert(life.stats().started == false, "not started")

life.clear()
local A, B = 0x7ff612340000, 0x7ff612340100
local a = life.watch(A)
assert(life.alive(A, a), "watched, nothing deleted: alive")
assert(not life.alive(B, a), "an address never watched is never alive")
assert(not life.alive(A, nil) and not life.alive(A, 0), "no serial: not alive")

life.test_notify(B)
local s = life.stats()
assert(s.notified == 1 and s.noted == 0 and s.watched == 1, "every deletion is counted, only watched ones noted")

life.test_notify(A)
assert(not life.alive(A, a), "deleted: never alive again")
assert(life.stats().noted == 1, "the deletion is noted")

-- The game puts a new object at the same address.
local a2 = life.watch(A)
assert(life.alive(A, a2) and not life.alive(A, a), "reused address: the new watch lives, the old serial stays dead")

-- Watching a live object again keeps its earlier serials valid.
local a3 = life.watch(A)
assert(life.alive(A, a2) and life.alive(A, a3), "a second watch of the same live object")

-- Forgotten, then the address is reused and watched again: old serials stay dead even though
-- the deletion in between was never seen.
life.forget(A)
assert(not life.alive(A, a3), "forgotten: not alive")
local a4 = life.watch(A)
assert(life.alive(A, a4) and not life.alive(A, a3) and not life.alive(A, a2), "re-watched: only the new serial lives")

-- Null is never alive; clear() forgets everything.
assert(life.watch(0) == 0 and not life.alive(0, 0), "null is never watched")
local b = life.watch(B)
life.clear()
assert(not life.alive(A, a4) and not life.alive(B, b) and life.stats().watched == 0, "cleared: nothing alive")

-- Addresses as UE4SS hands them over (integers) and as strings both work.
local c = life.watch(tostring(B))
assert(life.alive(B, c), "string addresses are read as numbers")
life.clear()
print("lifetime test passed")
