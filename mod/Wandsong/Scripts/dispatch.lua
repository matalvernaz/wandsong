-- One game-thread dispatcher for the whole mod.
--
-- Every UE4SS ExecuteInGameThread call sets up its own Lua state, and another access mod found
-- that doing that from many loops and key binds at once races. So nothing in the mod calls
-- ExecuteInGameThread or ExecuteWithDelay directly: key binds, hooks and timers queue work
-- here. Blueprint actor/widget ticks drive the queue on the game thread. A bounded
-- fallback covers startup and screens with no Blueprint ticks.
--
--   dispatch.run(fn)             run fn on the game thread at the next tick
--   dispatch.later(ms, fn)       run fn on the game thread after ms milliseconds
--   dispatch.every(ms, fn)       run fn every ms milliseconds; fn returning true stops it
--
-- Every task runs inside pcall, so one failing task can't stop the others.

local diag = require("diag")
local state = require("state")

local M = {}

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

-- during_load = true lets a task run while the game is loading. Other work waits until the
-- load ends, unless it came from a previous world generation, in which case it is discarded.
function M.run(fn, label, during_load)
    queue[#queue + 1] = { fn = fn, label = label or where(fn), during_load = during_load, generation = state.generation }
end

function M.later(ms, fn, label, during_load)
    local timer = { due = os.clock() + ms / 1000, fn = fn, label = label or where(fn), during_load = during_load,
                    generation = state.generation }
    timers[#timers + 1] = timer
    return timer
end

function M.cancel(timer) if timer then timer.cancelled = true end end

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
    local now_queue = queue
    queue = {}
    for _, t in ipairs(now_queue) do
        if t.generation == state.generation then
            if state.loading() and not t.during_load then queue[#queue + 1] = t else call(t.fn, t.label) end
        end
    end

    local now = os.clock()
    local keep = {}
    local due = {}
    for _, t in ipairs(timers) do
        if not t.cancelled and (t.every or t.during_load or t.generation == state.generation) then
            if now >= t.due and (t.during_load or not state.loading()) then due[#due + 1] = t else keep[#keep + 1] = t end
        end
    end
    timers = keep
    for _, t in ipairs(due) do
        local stop
        if t.cancelled or (not t.every and not t.during_load and t.generation ~= state.generation) then stop = true
        elseif state.loading() and not t.during_load then timers[#timers + 1] = t; stop = true
        else stop = call(t.fn, t.label) end
        if t.every and stop ~= true and not t.cancelled then
            t.due = now + t.every / 1000
            timers[#timers + 1] = t
        end
    end
end

local last_ran, stall_logged = os.clock(), false
local running, pending = false, false
local next_tick, last_hook = 0, -math.huge
local driver, fallback_calls, callback_freed, callback_missed = "starting", 0, 0, 0
local function game_tick()
    -- Nothing at all inside a map load, not even work allowed during loads (state.lua).
    if state.in_map_load() then return end
    if running or os.clock() < next_tick then return end
    running = true
    next_tick = os.clock() + TICK_MS / 1000
    if stall_logged then
        diag.trace(string.format("game thread running the mod again after %.0f s", os.clock() - last_ran))
        stall_logged = false
    end
    last_ran = os.clock()
    local ok, err = xpcall(tick, debug.traceback)
    running = false
    if not ok then log("tick failed: " .. tostring(err)) end
end

-- These named Blueprint events are invoked on the game thread for actors and widgets.
-- They need no object access, survive level changes, and are registered only once.
-- Do not return game_tick's result: a hook return value could change the game's event.
local function on_tick()
    last_hook = os.clock()
    if driver ~= "Blueprint tick" then driver = "Blueprint tick"; log("dispatcher: " .. driver) end
    game_tick()
end
if type(RegisterCustomEvent) == "function" then
    for _, name in ipairs({ "ReceiveTick", "Tick" }) do
        local ok, err = pcall(RegisterCustomEvent, name, on_tick)
        if not ok then log("dispatcher hook " .. name .. " unavailable: " .. tostring(err)) end
    end
end

-- UE4SS 3.0.1 releases the temporary thread reference but leaks the callback reference.
-- Capture only luaL_ref's possible slots and release the exact, unique callback when it
-- executes. Never scan the registry, never release the thread (UE4SS owns it). A newer
-- engine's bookkeeping is left alone. At most one fallback may be outstanding.
local clean_callback = false
pcall(function()
    local a, b, c = UE4SS.GetVersion()
    clean_callback = a == 3 and b == 0 and c == 1
end)
local function fallback()
    if pending then return end
    pending = true
    local reg, candidates
    if clean_callback then
        reg = debug.getregistry()
        local head, len = rawget(reg, 3), rawlen(reg)
        candidates = { len + 1, len + 2, len + 3 }
        if math.type(head) == "integer" and head > 3 then table.insert(candidates, 1, head) end
    end
    local callback
    callback = function()
        if reg then
            local found = false
            for _, slot in ipairs(candidates) do
                if rawequal(rawget(reg, slot), callback) then
                    rawset(reg, slot, nil); callback_freed = callback_freed + 1; found = true; break
                end
            end
            if not found then callback_missed = callback_missed + 1 end
        end
        -- Keep pending set during work, including any nested ProcessEvent calls.
        game_tick()
        pending = false
    end
    fallback_calls = fallback_calls + 1
    local ok, err = pcall(ExecuteInGameThread, callback)
    if not ok then pending = false; log("dispatcher scheduling failed: " .. tostring(err)) end
end

function M.driver_stats()
    return driver, fallback_calls, callback_freed, callback_missed
end
-- The game stopped ticking while in play: a level load has begun. "Try Again" after a failed
-- quest (Oct 8, 15:06) reloads with no loading screen at first, so the world gate stayed open,
-- the fallback ran world scans inside the load, and the game hung there for good (the end of the
-- intro crashed the same way at 05:49). Work that touches the world waits for the ticks to come
-- back; menus and speech, allowed during loads, carry on.
local STILL_S = 1.5
local still_in_world = false
LoopAsync(TICK_MS, function()
    -- (Only once the game has ticked at all: before that, and in the offline tests, every
    -- tick is the fallback's.)
    local still = last_hook > -math.huge and os.clock() - last_hook > STILL_S
    if still and (still_in_world or state.in_world) then
        if not still_in_world then diag.trace("no game ticks in play: treated as a load") end
        still_in_world = true
        state.mark_loading(2)
    elseif not still then
        still_in_world = false
    end
    if not stall_logged and os.clock() - last_ran > 8 then
        stall_logged = true
        diag.trace("game thread hasn't run the mod for 8 s (frozen, or a long load)")
    end
    if (#queue > 0 or #timers > 0) and os.clock() - last_hook > 0.3 then
        if driver ~= "fallback" then driver = "fallback"; log("dispatcher: fallback (no Blueprint ticks)") end
        fallback()
    end
    return false
end)

return M
