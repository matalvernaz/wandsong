-- Spell lessons (USpellMiniGameBase): trace the spell's symbol to learn it.
--
-- The game: a spark runs along the symbol's straight strokes. Moving the mouse the way the
-- current stroke goes keeps it at speed; without that it coasts and slows. At checkpoints an
-- input window opens, and pressing its key (Space, F, or a mouse button) gives a burst. Three
-- seconds in, a chasing spark sets off behind; if it catches up the trace fails and waits to be
-- started again. (Measured Oct 7: see NOTEBOOK.)
--
-- Played by ear (the default, once the player starts it with the game's own key):
--   * each stroke's direction is spoken as it begins ("up right"), and a bell repeats it,
--     higher for up, lower for down, from the left or right for left and right;
--   * holding the arrow keys or W A S D that way moves the wand (the mouse) while they're held;
--     a soft tick means on course, a low buzz off course;
--   * a bell when a checkpoint opens, with the key to press (the game's own Space or F; the
--     mouse-button ones are the press key);
--   * a rising alarm while the chasing spark is close.
-- Or the press key before starting: the tracing assistance does it all (Matt: "a thing that
-- does it for me is nice, but ideally an adapted form").
--
-- Hooks are installed only at startup: UE4SS 3.0.1 retains their registering Lua thread, which
-- is unsafe when registered from a transient dev task. Hooks keep paths/scalars; all widget
-- calls use a fresh lookup on the game thread.
local dispatch, state = require("dispatch"), require("state")
local speech, keys, diag = require("speech"), require("keys"), require("diag")
local bindings = require("bindings")
local ok_input, input = pcall(require, "input_bridge")
local audio
do
    local ok, mod = pcall(require, "audio_bridge")
    if ok and type(mod) == "table" and mod.init() then audio = mod end
end
local M = {}
local lesson, pending = nil, {}
local generation = state.generation
local function log(s) print("[Wandsong spells] " .. s .. "\n") end
local function path_of(o)
    local ok, full = pcall(function() return o:GetFullName() end)
    return ok and full:match("^%S+%s+(.+)$") or nil
end
local function focused()
    local ok, yes = pcall(function() return ok_input and input.focused() end)
    return ok and yes == true
end
local function screen()
    if not lesson or state.loading() or lesson.generation ~= state.generation then return nil end
    local o
    pcall(function()
        local found = StaticFindObject(lesson.path)
        if found and path_of(found) == lesson.path and found:IsValid()
           and found.Visibility ~= 1 and found.Visibility ~= 2 then o = found end
    end)
    return o
end
local function set_mode(mode)
    if lesson then lesson.mode = mode end
    -- While the wand is steered with the arrows, they mustn't also walk the review list.
    state.steering = mode == "adapted" or nil
end
local function clear()
    lesson = nil
    if state.activity == M then state.activity = nil end
    state.spell_lesson, state.steering = nil, nil
end
local function action(code)
    if not focused() or not screen() then return false end
    local ok = pcall(function()
        local mgr = FindFirstOf("UMGInputManager")
        assert(mgr and mgr:IsValid(), "input manager unavailable")
        mgr:OnInputAction(code, 0)
        mgr:OnInputAction(code, 1)
    end)
    return ok
end
local function press_key() return keys.describe_combo(keys.combo_of("press")) end
local function start_key() return bindings.spoken("UMGStartSpellMiniGame", "SpaceBar") end
local function sounds_ok()
    local w = require("world")
    return audio and not speech.is_muted() and (not w.sounds_enabled or w.sounds_enabled())
end
local function instructions()
    return (lesson and lesson.name or "Spell") .. " lesson. Press " .. start_key() ..
        " to trace it yourself, by ear: hold the arrow keys or W A S D the way each stroke goes. " ..
        "Each stroke's direction is spoken and a bell repeats it, higher for up, lower for down, " ..
        "from the left or the right. A tick means on course, a buzz off course. When a bell rings " ..
        "with a key, press that key. Or press " .. press_key() .. " and the mod traces it for you."
end
M.instructions = instructions

-- The key a checkpoint asks for (EUMGInputAction 77-80 = UMGSpellMinigameOption1-4).
local OPTIONS = { [77] = { "UMGSpellMinigameOption1", "SpaceBar" }, [78] = { "UMGSpellMinigameOption2", "F" },
                  [79] = { "UMGSpellMinigameOption3" }, [80] = { "UMGSpellMinigameOption4" } }
local function option_key(code)
    local o = OPTIONS[code]
    if not o then return nil end
    -- Options 3 and 4 are mouse buttons in the game: the press key stands in for them.
    if not o[2] then return press_key(), true end
    local k = bindings.key(o[1], o[2])
    if not k or not bindings.virtual_key(k) then return press_key(), true end
    return bindings.spoken(o[1], o[2]), false
end

-- Directions on screen (y grows downward), as words: the stroke "goes up right".
local WORDS = { "right", "up right", "up", "up left", "left", "down left", "down", "down right" }
local function direction_word(x, y)
    local a = math.deg(math.atan(-y, x))
    return WORDS[math.floor(((a % 360) + 22.5) / 45) % 8 + 1]
end
M.direction_word = direction_word

-- A bell placed left or right of the listener and pitched up or down: the stroke's way.
local function direction_cue(x, y)
    if not sounds_ok() then return end
    local px, py, pz, yaw = require("world").position()
    local f, r = math.rad(yaw or 0), math.rad((yaw or 0) + 90)
    local sx = px + math.cos(f) * 150 + math.cos(r) * x * 300
    local sy = py + math.sin(f) * 150 + math.sin(r) * x * 300
    audio.play("note", sx, sy, pz + 60, 0.6, 2 ^ (-y * 0.6))
end

-- Held steering keys as a screen direction (x right, y down), or nil.
local STEER = { { 0x25, -1, 0 }, { 0x41, -1, 0 }, { 0x27, 1, 0 }, { 0x44, 1, 0 },
                { 0x26, 0, -1 }, { 0x57, 0, -1 }, { 0x28, 0, 1 }, { 0x53, 0, 1 } }
local function held()
    if not (ok_input and input.down) then return nil end
    local hx, hy = 0, 0
    for _, s in ipairs(STEER) do
        local ok, down = pcall(input.down, s[1])
        if ok and down then hx, hy = hx + s[2], hy + s[3] end
    end
    hx, hy = math.max(-1, math.min(1, hx)), math.max(-1, math.min(1, hy))
    if hx == 0 and hy == 0 then return nil end
    local len = math.sqrt(hx * hx + hy * hy)
    return hx / len, hy / len
end

local STEER_PX = 80              -- mouse movement per 100 ms while steering (the assistance's)
local CUE_EVERY = 1.0            -- repeat the stroke's bell this often
local FEEDBACK_EVERY = 0.45
local ALARM_GAP = 0.15           -- the chasing spark within this share of the path: alarm

function M.press()
    local w = screen()
    if not w or not focused() then return end
    if lesson.assisted then
        lesson.assisted = false
        set_mode(nil)
        speech.say("Spell tracing assistance stopped.")
        return
    end
    -- Tracing by ear: a mouse-button checkpoint is open, and this key stands in for it.
    if lesson.mode == "adapted" and lesson.window_code and lesson.window_code >= 79 then
        if action(lesson.window_code) then log("checkpoint by press key " .. lesson.window_code) end
        return
    end
    local ok, waiting = pcall(function() return w:GetIsWaitingForStart() end)
    lesson.assisted, lesson.since, lesson.progress = true, os.clock(), -1
    lesson.checkpoint = nil
    set_mode("assist")
    if ok and waiting and not action(76) then
        lesson.assisted = false
        set_mode(nil)
        speech.say("Could not start the spell lesson. Try again.")
        return
    end
    speech.say("Tracing " .. lesson.name .. ". Press " .. press_key() .. " to stop assistance.")
end
function M.items()
    if not lesson then return {} end
    return { { text = instructions() },
        { text = lesson.assisted and "Stop tracing assistance" or "Start tracing assistance", button = true, on_press = M.press } }
end
M.title = "Spell lesson"
local EVENTS = { "OnMinigameFullyLoaded", "OnStartPressed", "OnEnterInputWindow",
    "OnInputSuccess", "OnInputFailure", "OnMinigameSuccess", "OnMinigameFailure", "OnExitPressed" }
for _, event in ipairs(EVENTS) do
    if type(RegisterCustomEvent) == "function" then
        local ok, err = pcall(RegisterCustomEvent, event, function(ctx, parameter)
            local p = path_of(ctx:get())
            if not p or not p:lower():find("spell", 1, true) then return end
            if event == "OnMinigameFullyLoaded" then state.spell_lesson = p end
            local n
            if event == "OnEnterInputWindow" or event == "OnInputSuccess" or event == "OnInputFailure" then
                pcall(function() n = parameter:get() end)
            end
            if #pending < 32 then pending[#pending + 1] = {
                event = event, path = p, number = type(n) == "number" and n or nil, generation = state.generation } end
        end)
        if not ok then log("hook failed " .. event .. ": " .. tostring(err)) end
    end
end

-- Tracing by ear, once per tick while the spark runs.
local function adapted_tick(w)
    local now = os.clock()
    local spark = w.PlayerSpark
    if not spark or not spark:IsValid() or spark.IsRunning ~= true then return end
    local segment = spark:GetCurrentPathSegment()
    local dx, dy = segment.EndPoint.X - segment.StartPoint.X, segment.EndPoint.Y - segment.StartPoint.Y
    local length = math.sqrt(dx * dx + dy * dy)
    if length <= 0 then return end
    local sx, sy = dx / length, dy / length
    local index
    pcall(function() index = spark:GetCurrentPathSegmentIndex() end)
    local id = tostring(index) .. ":" .. math.floor(dx) .. ":" .. math.floor(dy)
    if id ~= lesson.segment then
        lesson.segment = id
        speech.say(direction_word(sx, sy))
        direction_cue(sx, sy)
        lesson.next_cue = now + CUE_EVERY
        log("stroke " .. id .. " " .. direction_word(sx, sy))
    elseif now >= (lesson.next_cue or 0) then
        direction_cue(sx, sy)
        lesson.next_cue = now + CUE_EVERY
    end
    local hx, hy = held()
    if hx then
        input.mouse_move(math.floor(hx * STEER_PX + 0.5), math.floor(hy * STEER_PX + 0.5))
        if now >= (lesson.next_feedback or 0) and sounds_ok() then
            lesson.next_feedback = now + FEEDBACK_EVERY
            if hx * sx + hy * sy >= 0.75 then audio.play_ui("tick", 0.4, 1.3) else audio.play_ui("step_blocked", 0.5) end
        end
    end
    lesson.window_code = nil
    if w:GetIsInInputWindow() then
        local checkpoint = w:GetCurrentCheckpointData()
        local code = checkpoint.InputAction
        local cid = tostring(checkpoint.PathSplineIndex) .. ":" .. tostring(code)
        pcall(function() cid = cid .. ":" .. checkpoint.InputWindow.X .. ":" .. checkpoint.InputWindow.Y end)
        if type(code) == "number" then lesson.window_code = code end
        if cid ~= lesson.announced and type(code) == "number" then
            lesson.announced = cid
            local key = option_key(code)
            if sounds_ok() then audio.play_ui("chime", 0.7, 1.3) end
            if key then speech.say(key) end
            log("checkpoint window " .. cid)
        end
    end
    local mine, bad
    pcall(function() mine = spark:GetTotalDistanceAsPercent() end)
    pcall(function() bad = w.BadSpark:GetTotalDistanceAsPercent() end)
    if type(mine) == "number" and type(bad) == "number" and bad > 0.001 and mine - bad < ALARM_GAP
       and now >= (lesson.next_alarm or 0) and sounds_ok() then
        lesson.next_alarm = now + 0.5
        audio.play_ui("warn", 0.6, 1 + (ALARM_GAP - math.max(0, mine - bad)) * 4)
    end
end

-- Tracing assistance, once per tick: follow the stroke and press each checkpoint.
local function assist_tick(w)
    local spark = w.PlayerSpark
    if not spark or not spark:IsValid() or spark.IsRunning ~= true then return end
    local segment = spark:GetCurrentPathSegment()
    local dx, dy = segment.EndPoint.X - segment.StartPoint.X, segment.EndPoint.Y - segment.StartPoint.Y
    local length = math.sqrt(dx * dx + dy * dy)
    if length > 0 then input.mouse_move(math.floor(dx / length * 80 + 0.5), math.floor(dy / length * 80 + 0.5)) end
    if w:GetIsInInputWindow() then
        local checkpoint = w:GetCurrentCheckpointData()
        local code = checkpoint.InputAction
        local id = tostring(checkpoint.PathSplineIndex) .. ":" .. tostring(code)
        pcall(function() id = id .. ":" .. checkpoint.InputWindow.X .. ":" .. checkpoint.InputWindow.Y end)
        if type(code) == "number" and code >= 77 and code <= 80 and lesson.checkpoint ~= id then
            if action(code) then lesson.checkpoint = id; log("checkpoint " .. id) end
        end
    end
    local progress = spark:GetTotalDistanceAsPercent()
    if type(progress) == "number" then
        local quarter = math.floor(progress * 4)
        if quarter > lesson.progress then lesson.progress = quarter; log("progress " .. tostring(progress)) end
    end
end

dispatch.every(100, function()
    if generation ~= state.generation then
        generation = state.generation
        local keep = {}
        for _, e in ipairs(pending) do if e.generation == generation then keep[#keep + 1] = e end end
        pending = keep
        clear()
    end
    if state.loading() then
        -- The new screen may finish loading before the UI settling guard expires. Keep
        -- its same-generation event until then, without touching any widgets during load.
        if lesson then clear() end
        return
    end
    local events = pending
    pending = {}
    for _, e in ipairs(events) do
        if e.generation == state.generation then
            log(e.event .. " " .. e.path .. (e.number and (" " .. e.number) or ""))
            if e.event == "OnMinigameFullyLoaded" then
                lesson = { path = e.path, generation = generation, name = "Spell", assisted = false }
                local w = screen()
                if w then
                    pcall(function() lesson.name = w:GetMiniGameName():ToString() end)
                    state.spell_lesson, state.activity = e.path, M
                    speech.say(instructions())
                else clear() end
            elseif lesson and e.path == lesson.path then
                if e.event == "OnMinigameSuccess" then
                    speech.say(lesson.name .. " learned.")
                    clear()
                elseif e.event == "OnExitPressed" then clear()
                elseif e.event == "OnStartPressed" and not lesson.assisted then
                    -- Started with the game's own key: trace it by ear.
                    set_mode("adapted")
                    lesson.segment, lesson.announced, lesson.next_alarm = nil, nil, 0
                    if not (ok_input and input.down) then
                        speech.say("Steering the wand needs the updated input module. Press " .. press_key() ..
                            " for tracing assistance instead.")
                    end
                elseif e.event == "OnMinigameFailure" then
                    lesson.assisted = false
                    set_mode(nil)
                    speech.say("The trace was missed. Press " .. start_key() .. " to try again, or " ..
                        press_key() .. " for tracing assistance.")
                end
            end
        end
    end
    if not lesson then return end
    local w = screen()
    if not w then clear(); return end
    if lesson.mode == "adapted" then
        if not focused() then return end
        local ok, err = pcall(adapted_tick, w)
        if not ok then
            set_mode(nil)
            log("tracing by ear stopped: " .. tostring(err))
            speech.say("Tracing by ear stopped. Press " .. press_key() .. " for tracing assistance.")
        end
        return
    end
    if not lesson.assisted then return end
    if not focused() or state.paused then
        lesson.assisted = false
        set_mode(nil)
        speech.say("Spell tracing assistance stopped.")
        return
    end
    if os.clock() - lesson.since > 60 then
        lesson.assisted = false
        set_mode(nil)
        speech.say("The spell trace has stopped progressing. Press " .. press_key() .. " to try again.")
        return
    end
    local ok, err = pcall(assist_tick, w)
    if not ok then
        lesson.assisted = false
        set_mode(nil)
        log("assistance stopped: " .. tostring(err))
        speech.say("Spell tracing assistance could not continue. Press " .. press_key() .. " to retry.")
    end
end, "spell lesson", true)
return M
