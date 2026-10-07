-- Spell-learning accessibility. Hooks are installed only at startup: UE4SS 3.0.1 retains
-- their registering Lua thread, which is unsafe when registered from a transient dev task.
-- Hooks keep paths/scalars; all widget calls use a fresh lookup on the game thread.
local dispatch, state = require("dispatch"), require("state")
local speech, keys, diag = require("speech"), require("keys"), require("diag")
local ok_input, input = pcall(require, "input_bridge")
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
local function clear()
    lesson = nil
    if state.activity == M then state.activity = nil end
    state.spell_lesson = nil
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
local function instructions()
    return (lesson and lesson.name or "Spell") .. " lesson. Press " .. press_key() ..
        " for tracing assistance. It guides the wand and presses the checkpoints for this lesson. " ..
        "Press it again to stop assistance. " .. require("bindings").spoken("UMGStartSpellMiniGame", "SpaceBar") ..
        " starts the original mouse lesson."
end
M.instructions = instructions
function M.press()
    local w = screen()
    if not w or not focused() then return end
    if lesson.assisted then
        lesson.assisted = false
        speech.say("Spell tracing assistance stopped.")
        return
    end
    local ok, waiting = pcall(function() return w:GetIsWaitingForStart() end)
    lesson.assisted, lesson.since, lesson.progress = true, os.clock(), -1
    lesson.checkpoint = nil
    if ok and waiting and not action(76) then
        lesson.assisted = false
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
                elseif e.event == "OnMinigameFailure" then
                    lesson.assisted = false
                    speech.say("The trace was missed. Press " .. press_key() .. " to try again.")
                end
            end
        end
    end
    if not lesson then return end
    local w = screen()
    if not w then clear(); return end
    if not lesson.assisted then return end
    if not focused() or state.paused then
        lesson.assisted = false
        speech.say("Spell tracing assistance stopped.")
        return
    end
    if os.clock() - lesson.since > 60 then
        lesson.assisted = false
        speech.say("The spell trace has stopped progressing. Press " .. press_key() .. " to try again.")
        return
    end
    local ok, err = pcall(function()
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
    end)
    if not ok then
        lesson.assisted = false
        log("assistance stopped: " .. tostring(err))
        speech.say("Spell tracing assistance could not continue. Press " .. press_key() .. " to retry.")
    end
end, "spell lesson", true)
return M
