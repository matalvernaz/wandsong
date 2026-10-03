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

local M = {}

local TICK_MS = 50

local queue = {}     -- functions to run at the next tick
local timers = {}    -- { due = clock, fn = f, every = ms|nil }

local function log(s) print("[Wandsong] " .. s .. "\n") end

function M.run(fn)
    queue[#queue + 1] = fn
end

function M.later(ms, fn)
    timers[#timers + 1] = { due = os.clock() + ms / 1000, fn = fn }
end

function M.every(ms, fn)
    timers[#timers + 1] = { due = os.clock() + ms / 1000, fn = fn, every = ms }
end

local function call(fn, what)
    local ok, err = pcall(fn)
    if not ok then log("task failed (" .. what .. "): " .. tostring(err)) end
    return ok and err
end

local function tick()
    -- Take what's queued now; anything queued while running waits for the next tick.
    local now_queue = queue
    queue = {}
    for _, fn in ipairs(now_queue) do call(fn, "queued") end

    local now = os.clock()
    local keep = {}
    local due = {}
    for _, t in ipairs(timers) do
        if now >= t.due then due[#due + 1] = t else keep[#keep + 1] = t end
    end
    timers = keep
    for _, t in ipairs(due) do
        local stop = call(t.fn, t.every and "every" or "later")
        if t.every and stop ~= true then
            t.due = now + t.every / 1000
            timers[#timers + 1] = t
        end
    end
end

LoopAsync(TICK_MS, function()
    if #queue > 0 or #timers > 0 then
        ExecuteInGameThread(function() call(tick, "tick") end)
    end
    return false
end)

return M
