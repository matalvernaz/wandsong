-- Speech output for Wandsong.
--
-- UE4SS's Lua can't load native libraries, so speech goes through a small helper program
-- (wandsong_helper.exe, built on Prism) that this module starts when the mod loads. Lines are
-- written to the helper's named pipe:
--   I|text  speak, interrupting      Q|text  speak after current speech
--   S|      stop speaking            C|text  put text on the clipboard
-- If the helper isn't running, messages wait (briefly) and the mod carries on silently.

local M = {}

local PIPE = [[\\.\pipe\wandsong]]
local RETRY_SECONDS = 1.0
local MAX_PENDING = 20
local HISTORY_SIZE = 30

local pipe = nil
local next_try = 0
local pending = {}
local history = {}
local muted = false

local function log(s) print("[Wandsong] " .. s .. "\n") end

-- Folder holding this mod (…\Mods\Wandsong\), from this script's own path.
local function mod_dir()
    local src = debug.getinfo(1, "S").source or ""
    src = src:gsub("^@", ""):gsub("/", "\\")
    return src:match("^(.*)\\[Ss]cripts\\[^\\]+$") or "Mods\\Wandsong"
end

local function connect()
    local ok, f = pcall(io.open, PIPE, "wb")
    if ok and f then
        pcall(function() f:setvbuf("no") end)
        pipe = f
        return true
    end
    return false
end

local function write_line(line)
    if not pipe then
        if os.clock() < next_try then return false end
        if not connect() then
            next_try = os.clock() + RETRY_SECONDS
            return false
        end
    end
    local ok, res = pcall(function() return pipe:write(line .. "\n") end)
    if ok and res then
        pcall(function() pipe:flush() end)
        return true
    end
    -- Helper went away: drop the handle and try a fresh connection next time.
    pcall(function() pipe:close() end)
    pipe = nil
    next_try = 0
    return false
end

local function flush_pending()
    while #pending > 0 do
        if not write_line(pending[1]) then return false end
        table.remove(pending, 1)
    end
    return true
end

local function send(line)
    if #pending > 0 and not flush_pending() then
        pending[#pending + 1] = line
        if #pending > MAX_PENDING then table.remove(pending, 1) end
        return
    end
    if not write_line(line) then
        pending[#pending + 1] = line
        if #pending > MAX_PENDING then table.remove(pending, 1) end
    end
end

local function one_line(text)
    return (tostring(text):gsub("[\r\n]+", " "))
end

--- Speak text. queue=true waits for current speech instead of interrupting it.
function M.say(text, queue)
    if text == nil then return end
    text = one_line(text)
    -- Nothing audible (blank, or only zero-width/format characters): say nothing.
    if text:gsub("\226\128[\139-\143]", ""):match("^%s*$") then return end
    table.insert(history, 1, text)
    if #history > HISTORY_SIZE then table.remove(history) end
    -- Flight recorder: every utterance lands in UE4SS.log, which makes bug reports easy.
    log((queue and "say+ " or "say ") .. text)
    if muted then return end
    send((queue and "Q|" or "I|") .. text)
end

--- Stop any speech in progress.
function M.stop() send("S|") end

--- Put text on the Windows clipboard (via the helper). Newlines are kept.
function M.copy(text) send("C|" .. (tostring(text):gsub("\r?\n", "\31"))) end

--- n-th most recent utterance (1 = last).
function M.recent(n) return history[n] end

--- Toggle all mod speech off/on. Returns the new state (true = muted).
function M.toggle_mute()
    if muted then
        muted = false
        send("I|Wandsong speech on")
    else
        send("I|Wandsong speech off")
        muted = true
    end
    return muted
end

function M.is_muted() return muted end

--- Start the helper (if it isn't already) and keep retrying queued messages.
function M.start()
    local exe = mod_dir() .. "\\helper\\wandsong_helper.exe"
    if os and os.execute then
        -- "start" returns at once; the helper is windowless and keeps a single instance.
        local ok, err = pcall(os.execute, 'start "" "' .. exe .. '"')
        log("helper launch " .. exe .. " ok=" .. tostring(ok) .. (ok and "" or (" " .. tostring(err))))
    else
        log("os.execute unavailable; the helper must be started another way")
    end
    -- Retry on the game thread, where every other write happens, so the pipe is never
    -- written from two threads at once.
    LoopAsync(500, function()
        if #pending > 0 then ExecuteInGameThread(flush_pending) end
        return false
    end)
end

return M
