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

local function call(fn, what)
    diag.trace("run " .. what)
    local t0 = os.clock()
    local ok, err = xpcall(fn, debug.traceback)
    local ms = (os.clock() - t0) * 1000
    if not ok then log("task failed (" .. what .. "): " .. tostring(err)) end
    if ms > SLOW_MS then log(string.format("slow task %s: %.0f ms", what, ms)) end
    return ok and err
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
