-- Speech output for Wandsong.
--
-- Preferred route: prism_bridge.dll, a Lua C module loaded in-process with require() that
-- calls Prism (https://github.com/ethindp/prism) directly: NVDA, JAWS, Narrator and others,
-- braille where the screen reader supports it, Windows voices otherwise.
--
-- Fallback route, if the bridge can't load: a small helper program (helper\wandsong_helper.exe,
-- also built on Prism) started here and fed over a named pipe, one line per message:
--   I|text  speak, interrupting      Q|text  speak after current speech
--   S|      stop speaking            C|text  put text on the clipboard
-- Either way, if nothing can speak the mod carries on silently.

local M = {}

local dispatch = require("dispatch")

local PIPE = [[\\.\pipe\wandsong]]
local RETRY_SECONDS = 1.0
local MAX_PENDING = 20
local HISTORY_SIZE = 30
-- Re-pick the best screen reader this often (one started mid-game). Never during a load: the
-- probe touches every speech backend, SAPI's COM objects included, and the game died in
-- combase.dll during a load right after one (Oct 7, 09:34; cause unproven).
local REFRESH_MS = 30000

local native = nil        -- prism_bridge module when loaded
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

-- --- Helper-program fallback ----------------------------------------------------------

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

-- --- Public API -------------------------------------------------------------------------

local function one_line(text)
    return (tostring(text):gsub("[\r\n]+", " "))
end

local function emit(text, interrupt)
    if require("files").test_dir then return end
    if native then
        pcall(native.output, text, interrupt)
    else
        send((interrupt and "I|" or "Q|") .. text)
    end
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
    emit(text, not queue)
end

--- Stop any speech in progress.
function M.stop()
    if require("files").test_dir then return end
    if native then pcall(native.stop) else send("S|") end
end

--- Put text on the Windows clipboard. Newlines are kept.
function M.copy(text)
    if require("files").test_dir then return end
    if native then
        pcall(native.copy, tostring(text))
    else
        send("C|" .. (tostring(text):gsub("\r?\n", "\31")))
    end
end

--- n-th most recent utterance (1 = last).
function M.recent(n) return history[n] end

--- Toggle all mod speech off/on. Returns the new state (true = muted).
function M.toggle_mute()
    if muted then
        muted = false
        emit("Wandsong speech on", true)
    else
        emit("Wandsong speech off", true)
        muted = true
        local audio = package.loaded.audio_bridge
        if type(audio) == "table" and audio.stop_all then pcall(audio.stop_all) end
    end
    return muted
end

function M.is_muted() return muted end

--- Pick a speech route and start it.
function M.start()
    if require("files").test_dir then return end
    local ok, mod = pcall(require, "prism_bridge")
    if ok and type(mod) == "table" and mod.is_ready and mod.is_ready() then
        native = mod
        local name = "?"
        pcall(function() name = native.detect() or "?" end)
        log("speech: in-process Prism bridge, speaking through " .. name)
        dispatch.every(REFRESH_MS, function()
            local before = native.detect and native.detect()
            local after = native.refresh and native.refresh()
            if after and after ~= before then log("speech: now speaking through " .. after) end
        end, "speech refresh")
        return
    end
    log("speech: Prism bridge unavailable (" .. tostring(mod) .. "), using the helper program")

    local exe = mod_dir() .. "\\helper\\wandsong_helper.exe"
    if os and os.execute then
        -- "start" returns at once; the helper is windowless and keeps a single instance.
        local okx, err = pcall(os.execute, 'start "" "' .. exe .. '"')
        log("helper launch " .. exe .. " ok=" .. tostring(okx) .. (okx and "" or (" " .. tostring(err))))
    else
        log("os.execute unavailable; the helper must be started another way")
    end
    -- Retry on the game thread, where every other write happens, so the pipe is never
    -- written from two threads at once.
    dispatch.every(500, function()
        if #pending > 0 then flush_pending() end
    end, "speech pipe", true)
end

return M
