-- While main.lua loads the modules (on UE4SS's event-loop thread, taking registry references),
-- nothing runs on the game thread and no fallback is posted from the async thread; and a
-- fallback is never posted right after the last one finished, while UE4SS is still releasing
-- that one's references on the game thread (UE4SS's luaL_ref isn't atomic across threads).
local t = dofile("native/tests/testlib.lua")
local hooks, queued, posted = {}, {}, 0
RegisterCustomEvent = function(name, fn) hooks[name] = fn end
UE4SS = { GetVersion = function() return 3, 0, 1 end }
ExecuteInGameThread = function(fn) posted = posted + 1; queued[#queued + 1] = fn end
local d = require("dispatch")

d.close()
local ran = 0
d.run(function() ran = ran + 1 end, "loading-time work")
for _ = 1, 50 do t.now = t.now + 0.02; hooks.Tick(); t.loop() end
assert(ran == 0, "no game-thread work while the modules load")
d.open()
for _ = 1, 10 do t.now = t.now + 0.02; hooks.Tick(); t.loop() end
assert(ran == 1, "once loaded, the work runs")

-- No Blueprint ticks while the modules load: no fallback is posted either.
d.close()
d.every(100, function() end, "steady work")
t.run(2)
assert(posted == 0, "no fallback posted while the modules load: " .. posted)
d.open()
t.run(1)
assert(posted == 1, "once loaded, the fallback steps in: " .. posted)

-- When it has finished, the next waits out the gap, then comes.
queued[1](); queued = {}
t.now = t.now + 0.01; t.loop()
assert(posted == 1, "no post right after the last fallback finished")
t.run(0.2)
assert(posted == 2, "the next fallback after the gap: " .. posted)
print("dispatch gate test passed")
