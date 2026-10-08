local t = dofile("native/tests/testlib.lua")
local hooks, queued, submitted = {}, {}, 0
RegisterCustomEvent = function(name, fn) hooks[name] = fn end
UE4SS = { GetVersion = function() return 3, 0, 1 end }
local reg = debug.getregistry()
local function ref(v)
    local head = rawget(reg, 3) or 0
    local slot
    if head ~= 0 then slot = head; rawset(reg, 3, rawget(reg, head))
    else rawset(reg, 3, 0); slot = rawlen(reg) + 1 end
    rawset(reg, slot, v)
    return slot
end
local function unref(slot) rawset(reg, slot, rawget(reg, 3)); rawset(reg, 3, slot) end
local sentinel = function() end
local sentinel_ref = ref(sentinel)
ExecuteInGameThread = function(fn)
    submitted = submitted + 1
    local f, thread = ref(fn), ref({})
    queued[#queued + 1] = function()
        fn()
        -- Exactly the 3.0.1 bug: releases its thread, but not its function.
        unref(thread)
        assert(rawget(reg, f) ~= fn, "completed callback reference leaked")
    end
end
local d = require("dispatch")
local ticks = 0
d.every(100, function() ticks = ticks + 1 end, "test tick")
for _ = 1, 1000 do t.now = t.now + 0.02; hooks.Tick(); t.loop() end
assert(ticks > 150 and ticks <= 200, "hook work throttled to 100ms")
assert(submitted == 0, "Blueprint ticks do not submit ExecuteInGameThread")

-- During a stalled game thread, async ticks must not accumulate callbacks.
t.run(10)
assert(submitted == 1 and #queued == 1, "one pending fallback during a stall")
queued[1](); queued = {}
local base = rawlen(reg)
for _ = 1, 2000 do
    t.now = t.now + 0.12
    t.loop()
    for _, run in ipairs(queued) do run() end
    queued = {}
end
assert(rawlen(reg) <= base + 4, "fallback registry stays bounded")
assert(rawget(reg, sentinel_ref) == sentinel, "unrelated reference preserved")
local _, calls, freed, missed = d.driver_stats()
assert(calls == freed and missed == 0, "all leaked callbacks released")

-- A task can start a load halfway through a batch; later tasks must see that immediately.
local state = require("state")
local touched, released = false, false
d.run(function() state.mark_loading(1) end, "load")
d.run(function() touched = true end, "old world")
d.later(1, function() touched = true end, "old timer")
d.later(1, function() released = true end, "input release", true)
t.now = t.now + 0.2; hooks.Tick()
assert(not touched and released, "load cancels stale work but releases input")
t.now = t.now + 2; hooks.Tick()
assert(not touched, "old world work stays cancelled after load")

-- Inside UEngine::LoadMap actors still tick, but nothing runs, not even work allowed during
-- loads: the world gate's player lookup there crashed the game (Oct 8, end of the intro).
local ran_inside, ran_old = false, false
d.every(100, function() ran_inside = true end, "gate", true)
d.run(function() ran_old = true end, "old map work")
state.begin_map_load()
for _ = 1, 20 do t.now = t.now + 0.12; hooks.Tick() end
assert(not ran_inside and not ran_old, "nothing runs inside a map load")
state.end_map_load()
for _ = 1, 3 do t.now = t.now + 0.12; hooks.Tick() end
assert(ran_inside, "work allowed during loads runs again once the map load has ended")
assert(not ran_old, "work queued for the old map is dropped")
-- Should the end never be heard, the hold lapses after a minute.
ran_inside = false
state.begin_map_load()
t.now = t.now + 61; hooks.Tick()
assert(ran_inside, "a map load that never ends doesn't stop the mod for good")
state.map_loading_since = nil

-- In play, the game ticking no more is a load beginning ("Try Again" after a failed quest
-- reloads with no loading screen at first, Oct 8): world work waits for the ticks to come back.
for _ = 1, 30 do t.now = t.now + 0.1; hooks.Tick(); t.loop() end
state.in_world = true
local world_ran = 0
d.every(100, function() world_ran = world_ran + 1 end, "world work")
for _ = 1, 5 do t.now = t.now + 0.1; hooks.Tick(); t.loop() end
assert(not state.loading() and world_ran > 0, "ticking in play: world work runs")
for _ = 1, 25 do t.now = t.now + 0.1; t.loop(); for _, run in ipairs(queued) do run() end; queued = {} end
assert(state.loading(), "no ticks for 2.5 s in play: a load")
state.in_world = false                     -- the world gate closes for the load
world_ran = 0
for _ = 1, 30 do t.now = t.now + 0.1; t.loop(); for _, run in ipairs(queued) do run() end; queued = {} end
assert(state.loading() and world_ran == 0, "still no ticks: still a load, and no world work in it")
for _ = 1, 30 do t.now = t.now + 0.1; hooks.Tick(); t.loop() end
assert(not state.loading() and world_ran > 0, "ticks back: the load is over and world work resumes")
print("dispatcher test passed")
