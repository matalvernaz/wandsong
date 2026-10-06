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

local TICK_MS = 50

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

-- UE4SS 3.0.1 leaks a Lua registry reference for every out parameter of every game function
-- called from Lua (LuaUObject.cpp: make_ref for the out table, never unref'd): one per wall
-- ray, about 80 a second, each pinning its table. Its own long-lived references (callbacks,
-- coroutines) are all functions and threads, and an out-parameter reference is only used
-- during its call, so once a second every integer-keyed table in the registry beyond the
-- reserved slots (1 main thread, 2 globals, 3 free list) is dropped. Entries are set to nil
-- rather than put on the free list: a nil slot is always safe for luaL_ref to reuse, and
-- nothing else's bookkeeping is touched.
local next_sweep, swept = 0, 0
local function sweep_registry()
    local reg = debug.getregistry()
    local dead = {}
    for k, v in pairs(reg) do
        if math.type(k) == "integer" and k > 3 and type(v) == "table" then dead[#dead + 1] = k end
    end
    for _, k in ipairs(dead) do reg[k] = nil end
    swept = swept + #dead
end
function M.swept() local n = swept; swept = 0; return n end

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
    if now >= next_sweep then
        next_sweep = now + 1
        local ok, err = pcall(sweep_registry)
        if not ok then log("registry sweep failed: " .. tostring(err)) end
    end
end

LoopAsync(TICK_MS, function()
    if #queue > 0 or #timers > 0 then
        ExecuteInGameThread(function()
            local ok, err = xpcall(tick, debug.traceback)
            if not ok then log("tick failed: " .. tostring(err)) end
        end)
    end
    return false
end)

return M
