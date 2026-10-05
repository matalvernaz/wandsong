-- Diagnostics: everything the mod does, written to files that survive a crash.
--
-- Two files in the mod's folder (…\Mods\Wandsong\):
--   Wandsong.log   every message the mod prints, timestamped, flushed line by line;
--   trace.log            breadcrumbs: each task and risky step just before it runs. After a
--                        crash, its last lines say what the mod was doing at that moment.
-- The previous session's files are kept as *.prev.log, and the new log starts with the tail
-- of the previous trace, so one file shows how the last session ended.
--
--   diag.trace(s)        breadcrumb (trace.log only)
--   diag.mark(note)      "the player marked this moment" (both files)
--   diag.event(s)        log only when s differs from the last event with the same key

local M = {}

local function mod_dir()
    local src = debug.getinfo(1, "S").source or ""
    src = src:gsub("^@", ""):gsub("/", "\\")
    return src:match("^(.*)\\[Ss]cripts\\[^\\]+$") or "."
end
M.dir = mod_dir()
local LOG = M.dir .. "\\Wandsong.log"
local TRACE = M.dir .. "\\trace.log"
local TRACE_MAX = 4 * 1024 * 1024   -- start a fresh trace file past this (only the tail matters)

local function rotate(path)
    local prev = path:gsub("%.log$", ".prev.log")
    os.remove(prev)
    os.rename(path, prev)
    return prev
end

local function tail(path, n)
    local f = io.open(path, "r")
    if not f then return {} end
    local lines = {}
    for line in f:lines() do
        lines[#lines + 1] = line
        if #lines > n then table.remove(lines, 1) end
    end
    f:close()
    return lines
end

local function open(path)
    local f = io.open(path, "w")
    if f then pcall(function() f:setvbuf("line") end) end
    return f
end

rotate(LOG)
local prev_trace = rotate(TRACE)
local log_f = open(LOG)
local trace_f = open(TRACE)
local trace_bytes = 0

local t_start = os.clock()
local function stamp()
    return string.format("%s +%.3f", os.date("%H:%M:%S"), os.clock() - t_start)
end

local function write(f, s)
    if not f then return end
    pcall(function() f:write(s, "\n"); f:flush() end)
end

-- Every print in this mod also goes to the log.
local raw_print = print
print = function(...)
    local parts = {}
    for i = 1, select("#", ...) do parts[#parts + 1] = tostring((select(i, ...))) end
    local s = table.concat(parts, "\t")
    raw_print(s)
    write(log_f, stamp() .. " " .. (s:gsub("\n+$", "")))
end

function M.log(s) print("[Wandsong diag] " .. s .. "\n") end

function M.trace(s)
    if not trace_f then return end
    local line = stamp() .. " " .. s
    trace_bytes = trace_bytes + #line + 1
    if trace_bytes > TRACE_MAX then
        pcall(function() trace_f:close() end)
        rotate(TRACE)
        trace_f = open(TRACE)
        trace_bytes = 0
    end
    write(trace_f, line)
end

local last_event = {}
function M.event(key, s)
    if last_event[key] == s then return end
    last_event[key] = s
    M.log(key .. ": " .. s)
    M.trace(key .. ": " .. s)
end

function M.mark(note)
    local s = "=== PLAYER MARK === " .. (note or "")
    M.log(s)
    M.trace(s)
end

-- --- Session header -------------------------------------------------------------------

M.log("session start " .. os.date("%Y-%m-%d %H:%M:%S") .. ", " .. _VERSION .. ", mod folder " .. M.dir)
pcall(function()
    local a, b, c = UE4SS.GetVersion()
    M.log("UE4SS " .. tostring(a) .. "." .. tostring(b) .. "." .. tostring(c))
end)
local prev = tail(prev_trace, 25)
if #prev > 0 then
    M.log("previous session's last trace lines (if the game crashed, the crash came right after the last one):")
    for _, l in ipairs(prev) do M.log("  | " .. l) end
else
    M.log("no previous trace")
end

return M
