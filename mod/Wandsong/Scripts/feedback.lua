-- Gameplay information from the events that update the game's own HUD.
-- Hooks copy scalars/paths only. No actor calls, widget polling or retained UObjects.
-- Reflected names: Roadou/HogwartsLegacy-SDK, Phoenix and UI_BP_InteractBlip headers.
local dispatch = require("dispatch")
local state = require("state")
local world = require("world")
local speech = require("speech")
local keys = require("keys")
local bindings = require("bindings")
local M = {}
local queue, prompt, active_prompt = {}, nil, nil
local health, potions, low, critical = nil, nil, false, false
local generation = state.generation
local last_attack, last_prompt = -10, nil
local audio
do
    local ok, a = pcall(require, "audio_bridge")
    if ok and type(a) == "table" and a.init() then audio = a end
end
local function value(p)
    local ok, v = pcall(function() return p:get() end)
    return ok and v or nil
end
local function context_path(ctx, class_fragment)
    local ok, name = pcall(function() return ctx:get():GetFullName() end)
    if ok and name:find(class_fragment, 1, true) then return name:match("^%S+%s+(.+)$") end
end
local function record(kind, data)
    if #queue < 64 then queue[#queue + 1] = { kind = kind, data = data, at = os.clock(), generation = state.generation } end
end
local function hook(name, fn)
    if type(RegisterCustomEvent) ~= "function" then return end
    local ok, err = pcall(RegisterCustomEvent, name, fn)
    print("[Wandsong feedback] " .. (ok and "hooked " or "hook failed ") .. name ..
          (ok and "" or ": " .. tostring(err)) .. "\n")
end
hook("UpdateHealthBar", function(ctx, pct)
    if context_path(ctx, "QuickHealthActions") then record("health", value(pct)) end
end)
hook("DisplayItemCount", function(ctx, count)
    if context_path(ctx, "QuickHealthActions") then record("potions", value(count)) end
end)
hook("ReceiveIndicatorStart", function(ctx, parry, unblockable)
    if context_path(ctx, "AttackIndicator") then
        record("attack", { parry = value(parry), unblockable = value(unblockable) })
    end
end)
hook("ShowButtonInfo", function(ctx, shown)
    local path = context_path(ctx, "UI_BP_InteractBlip")
    if path then record("prompt", { path = path, shown = value(shown) == true }) end
end)

local function health_update(pct)
    if type(pct) ~= "number" or pct ~= pct or pct < 0 or pct > 1 then return end
    health = math.floor(pct * 100 + 0.5)
    if pct > 0.55 then low = false end
    if pct > 0.25 then critical = false end
    if pct <= 0 then return end
    if pct <= 0.2 and not critical then
        critical, low = true, true
        speech.say("Health critical, " .. health .. " percent. " .. bindings.spoken("AM_Health", "G") .. " heals.")
    elseif pct <= 0.5 and not low then
        low = true
        speech.say("Health below half, " .. health .. " percent.", true)
    end
end

local function read_prompt(path)
    local ok, text = pcall(function()
        local widget = StaticFindObject(path)
        if not widget or not widget:IsValid() then return end
        local panel = widget.ButtonPrompt
        if panel and (panel.Visibility == 1 or panel.Visibility == 2 or panel.RenderOpacity == 0) then return end
        local action = widget.ActionText.Text:ToString()
        action = action:gsub("<[^>]*>", ""):gsub("%s+", " "):match("^%s*(.-)%s*$")
        if action == "" then return end
        return "Press " .. bindings.spoken("AM_Interact", "F") .. " to " .. action:lower() .. "."
    end)
    if ok and text then
        if text ~= last_prompt then
            last_prompt = text
            speech.say(text, true)
            print("[Wandsong feedback] prompt: " .. text .. "\n")
        end
    end
end

dispatch.every(100, function()
    if generation ~= state.generation then
        generation = state.generation
        queue, prompt, health, potions, last_prompt, active_prompt = {}, nil, nil, nil, nil, nil
        low, critical = false, false
    end
    if state.loading() then queue, prompt = {}, nil; return end
    local batch = queue
    queue = {}
    for _, e in ipairs(batch) do
        if e.generation == generation then
            if e.kind == "health" then
                if world.in_game() then health_update(e.data)
                elseif type(e.data) == "number" and e.data >= 0 and e.data <= 1 then health = math.floor(e.data * 100 + 0.5) end
            elseif e.kind == "potions" and type(e.data) == "number" and e.data >= 0 then potions = math.floor(e.data)
            elseif e.kind == "prompt" then
                if e.data.shown then
                    if active_prompt ~= e.data.path then last_prompt = nil end
                    active_prompt = e.data.path
                    prompt = { path = e.data.path, until_t = e.at + 10 }
                elseif active_prompt == e.data.path then
                    prompt, last_prompt, active_prompt = nil, nil, nil
                end
            elseif e.kind == "attack" and world.in_game() and not speech.is_muted()
                   and world.sounds_enabled() and os.clock() - e.at < 0.75 and os.clock() - last_attack > 0.2 then
                local danger = e.data.unblockable == true
                if danger or e.data.parry == true then
                    last_attack = os.clock()
                    local meaning = danger and ("Unblockable attack. Dodge with " .. bindings.spoken("AM_Dodge", "LeftControl"))
                        or ("Incoming attack. Block with " .. bindings.spoken("AM_Protego", "Q"))
                    if audio then audio.play_ui("warn", 0.9, danger and 0.65 or 1) else speech.say(meaning) end
                    state.cue(meaning)
                    print("[Wandsong feedback] " .. meaning .. "\n")
                end
            end
        end
    end
    if prompt and world.in_game() and not world.ui_busy() then
        if os.clock() < prompt.until_t then read_prompt(prompt.path) end
        prompt = nil
    end
end, "gameplay feedback", true)

keys.action{ id = "gauges", name = "Read health and healing potions", group = "In the world", default = "end",
    run = function()
        if not world.in_game() then speech.say(world.not_ready_reason()); return end
        speech.say((health and ("Health " .. health .. " percent") or "Health hasn't been reported by the game yet") ..
            (potions and (". " .. potions .. " healing potions") or ""))
    end }
return M
