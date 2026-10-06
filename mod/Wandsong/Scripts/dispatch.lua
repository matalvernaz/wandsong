-- One game-thread dispatcher for the whole mod.
--
-- Every UE4SS ExecuteInGameThread call sets up its own Lua state, and another access mod found
-- that doing that from many loops and key binds at once races. So nothing in the mod calls
-- ExecuteInGameThread or ExecuteWithDelay directly: key binds, hooks and timers queue work
-- here, and a single loop runs all of it inside one ExecuteInGameThread per tick.
--
--   dispatch.run(fn)             run fn on the game thread at the next tick
--   dispatch.later(ms, fn)       run fn on the game thread after ms milliseconds
--   dispatch.every(ms, fn)       run fn every ms milliseconds; fn returning true stops it
--
-- Every task runs inside pcall, so one failing task can't stop the others.

local diag = require("diag")
local state = require("state")

local M = {}

-- 100 ms, not faster: every ExecuteInGameThread call leaves a reference in the Lua registry
-- that UE4SS never releases (about 36,000 an hour at this rate), and the registry is shared
-- with UE4SS's async thread. Two game freezes on Oct 6 came with it at 32,000 and 70,000.
local TICK_MS = 100

local queue = {}     -- functions to run at the next tick
local timers = {}    -- { due = clock, fn = f, every = ms|nil }

local function log(s) print("[Wandsong] " .. s .. "\n") end

-- Where a task was written ("world.lua:212"), for the trace and error messages.
local function where(fn, depth)
    local caller = debug.getinfo(depth or 3, "Sl")
    local def = debug.getinfo(fn, "S")
    local src = def and def.short_src or "?"
    if src == "?" and caller then src = caller.short_src end
    return (src:match("[^/\\]+$") or src) .. ":" .. tostring(def and def.linedefined or "?")
end

local SLOW_MS = 40

-- during_load = true lets a task run while the game is loading. Everything else waits until
-- the load is over: touching game objects mid-load is what crashes.
function M.run(fn, label, during_load)
    queue[#queue + 1] = { fn = fn, label = label or where(fn), during_load = during_load }
end

function M.later(ms, fn, label, during_load)
    timers[#timers + 1] = { due = os.clock() + ms / 1000, fn = fn, label = label or where(fn), during_load = during_load }
end

function M.every(ms, fn, label, during_load)
    timers[#timers + 1] = { due = os.clock() + ms / 1000, fn = fn, every = ms, label = label or where(fn),
                            during_load = during_load }
end

function M.counts() return #queue, #timers end

-- Memory accounting: KB of Lua memory each task label allocated since the last report.
-- (A garbage-collector step inside a task can make one reading negative: those count as 0.)
local alloc = {}

function M.alloc_report()
    local list = {}
    for label, kb in pairs(alloc) do list[#list + 1] = { label, kb } end
    table.sort(list, function(a, b) return a[2] > b[2] end)
    local parts = {}
    for i = 1, math.min(8, #list) do parts[i] = string.format("%s %.0f", list[i][1], list[i][2]) end
    alloc = {}
    return table.concat(parts, ", ")
end

local function call(fn, what)
    diag.trace("run " .. what)
    local t0 = os.clock()
    local kb0 = collectgarbage("count")
    local ok, err = xpcall(fn, debug.traceback)
    local dkb = collectgarbage("count") - kb0
    if dkb > 0 then alloc[what] = (alloc[what] or 0) + dkb end
    local ms = (os.clock() - t0) * 1000
    if not ok then log("task failed (" .. what .. "): " .. tostring(err)) end
    if ms > SLOW_MS then log(string.format("slow task %s: %.0f ms", what, ms)) end
    return ok and err
end

-- UE4SS 3.0.1 leaks a Lua registry reference for every out parameter of a game function
-- called from Lua (LuaUObject.cpp takes a ref to the out table and never releases it): one
-- per wall ray, each pinning its table. call_out makes such a call and then frees exactly the
-- slot luaL_ref (Lua 5.4.4) gave the out table: the free-list head (registry[3]) if there was
-- one, else the next index past the registry's length. The slot is only cleared if it really
-- holds that table, and it's set to nil rather than put back on the free list (luaL_ref
-- always treats a nil slot as free), so nothing else's bookkeeping is touched. No walk over
-- the registry: UE4SS's async thread writes to it, and a long walk could meet that.
local out_freed, out_missed = 0, 0
function M.call_out(fn, ...)
    local reg = debug.getregistry()
    local head, len = rawget(reg, 3), rawlen(reg)
    local ok, a, b = pcall(fn)
    local cands = { len + 1, len + 2, len + 3 }
    if math.type(head) == "integer" and head > 3 then table.insert(cands, 1, head) end
    for i = 1, select("#", ...) do
        local out = select(i, ...)
        local found = false
        for _, k in ipairs(cands) do
            if rawequal(rawget(reg, k), out) then rawset(reg, k, nil); found = true; break end
        end
        if found then out_freed = out_freed + 1 else out_missed = out_missed + 1 end
    end
    return ok, a, b
end
function M.out_stats()
    local f, m = out_freed, out_missed
    out_freed, out_missed = 0, 0
    return f, m
end

local function tick()
    -- Take what's queued now; anything queued while running waits for the next tick.
    local loading = state.loading()
    local now_queue = queue
    queue = {}
    for _, t in ipairs(now_queue) do
        if loading and not t.during_load then queue[#queue + 1] = t else call(t.fn, t.label) end
    end

    local now = os.clock()
    local keep = {}
    local due = {}
    for _, t in ipairs(timers) do
        if now >= t.due and (t.during_load or not loading) then due[#due + 1] = t else keep[#keep + 1] = t end
    end
    timers = keep
    for _, t in ipairs(due) do
        local stop = call(t.fn, t.label)
        if t.every and stop ~= true then
            t.due = now + t.every / 1000
            timers[#timers + 1] = t
        end
    end
end

-- One function object for every ExecuteInGameThread call: UE4SS 3.0.1 keeps a registry
-- reference to each callback it's given, so a fresh closure per call would pin a new closure
-- 20 times a second; the same function pins nothing new.
-- Stall watch: the async loop notes when the game thread last ran our tick. A gap of more
-- than 8 s (the game frozen, or a very long load) goes in the trace once, and so does the
-- recovery, so a hang can be told apart from a crash and timed.
local last_ran, stall_logged = os.clock(), false
local function game_tick()
    if stall_logged then
        diag.trace(string.format("game thread running the mod again after %.0f s", os.clock() - last_ran))
        stall_logged = false
    end
    last_ran = os.clock()
    local ok, err = xpcall(tick, debug.traceback)
    if not ok then log("tick failed: " .. tostring(err)) end
end
LoopAsync(TICK_MS, function()
    if not stall_logged and os.clock() - last_ran > 8 then
        stall_logged = true
        diag.trace("game thread hasn't run the mod for 8 s (frozen, or a long load)")
    end
    if #queue > 0 or #timers > 0 then ExecuteInGameThread(game_tick) end
    return false
end)

return M
