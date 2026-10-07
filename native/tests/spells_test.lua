local t = dofile("native/tests/testlib.lua")
Key.OEM_FIVE = 220   -- backslash, the press key
local events, actions, moves, said = {}, {}, {}, {}
RegisterCustomEvent = function(name, fn) events[name] = fn end
local focus, visible, waiting = true, true, true
local state = require("state")
local keys = require("keys")
keys.action{ id = "press", name = "Press", default = "\\", run = function() end }
package.loaded.input_bridge = { focused = function() return focus end,
    mouse_move = function(x,y) moves[#moves+1] = {x,y}; return true end }
require("speech").say = function(s) said[#said+1] = s end
local checkpoint = { InputAction = 78, PathSplineIndex = 3, InputWindow = {X=0.3,Y=0.5} }
local in_window = false
local spark = { IsValid = function() return true end, IsRunning = true,
    GetCurrentPathSegment = function() return {StartPoint={X=0,Y=0},EndPoint={X=3,Y=4}} end,
    GetTotalDistanceAsPercent = function() return 0.4 end }
local path = "/Game/UI_SpellMiniGame_C_1"
local widget = { Visibility = 0, IsValid = function() return visible end,
    GetFullName = function() return "SpellMiniGameBase " .. path end,
    GetMiniGameName = function() return {ToString=function() return "Revelio" end} end,
    GetIsWaitingForStart = function() return waiting end,
    GetIsInInputWindow = function() return in_window end,
    GetCurrentCheckpointData = function() return checkpoint end, PlayerSpark = spark }
StaticFindObject = function(p) if p == path then return widget end end
FindFirstOf = function(cls)
    if cls == "UMGInputManager" then return { IsValid=function() return true end,
        OnInputAction=function(_, code, kind)
            actions[#actions+1] = {code,kind}
            if code == 76 then waiting = false end
        end } end
end
local function event(name, number)
    events[name]({get=function() return widget end}, {get=function() return number end})
end
local spells = require("spells")
event("OnMinigameFullyLoaded"); t.run(0.3)
assert(state.spell_lesson == path and state.activity == spells, "lesson immediately blocks world features")
assert(said[#said]:find("Revelio lesson",1,true), "lesson and optional assistance are announced")
t.run(1)
assert(#actions == 0 and #moves == 0, "assistance never starts without the player's choice")
spells.press(); t.run(0.3)
assert(actions[1][1] == 76 and actions[2][2] == 1, "start uses the actual game input with a release")
assert(moves[1][1] == 48 and moves[1][2] == 64, "tracing follows the actual symbol segment")
in_window = true; t.run(0.3)
local n = #actions
assert(actions[n][1] == 78, "checkpoint uses the prompt's own action")
event("OnInputSuccess", 0); t.run(0.3)
assert(#actions == n, "one press per checkpoint even while its input window remains open")
focus = false; local m = #moves; t.run(0.4)
assert(#moves == m and #actions == n, "focus loss stops every synthetic input")
focus = true; t.run(0.4)
assert(#moves == m, "returning to the game does not silently resume assistance")
spells.press(); t.run(0.3)
event("OnMinigameFailure"); t.run(0.3)
assert(said[#said]:find("missed",1,true), "failure offers a retry instead of claiming success")
spells.press(); t.run(0.3)
event("OnMinigameSuccess"); t.run(0.3)
assert(said[#said] == "Revelio learned." and not state.activity and not state.spell_lesson,
    "only the actual game success event announces learning and restores the world")
event("OnMinigameFullyLoaded"); t.run(0.3); spells.press()
state.mark_loading(1); n, m = #actions, #moves; t.run(0.3)
assert(not state.activity and #actions == n and #moves == m, "load cancels the lesson without touching old widgets")
t.run(1.2); event("OnMinigameFullyLoaded"); t.run(0.3)
widget.GetFullName = function() return "SpellMiniGameBase /Game/None" end
spells.press(); t.run(0.3)
assert(not state.activity and #actions == n, "renamed stale widgets are never used")
widget.GetFullName = function() return "SpellMiniGameBase " .. path end
state.mark_loading(1)
event("OnMinigameFullyLoaded"); t.run(0.3)
assert(not state.activity, "a newly loaded lesson waits for the UI settling guard")
t.run(1)
assert(state.activity == spells, "the new lesson's loading event is not discarded")

-- Tracing by ear: started with the game's own key, the player steers with held keys.
local held_keys = {}
package.loaded.input_bridge.down = function(vk) return held_keys[vk] == true end
local played, ui = {}, {}
package.loaded.audio_bridge = nil
widget.GetFullName = function() return "SpellMiniGameBase " .. path end
state.mark_loading(1); t.run(1.5)
-- Fresh module state for the by-ear part (audio is captured from here on).
package.loaded.audio_bridge = { init = function() return true end,
    play = function(name, x, y, z, vol, pitch) played[#played + 1] = { name = name, pitch = pitch } end,
    play_ui = function(name, vol, pitch) ui[#ui + 1] = name end }
package.loaded.spells = nil
package.loaded.world = { position = function() return 0, 0, 0, 0 end, sounds_enabled = function() return true end }
local before_events = {}
for k, v in pairs(events) do before_events[k] = v end
spells = require("spells")
event("OnMinigameFullyLoaded"); t.run(0.3)
assert(said[#said]:find("by ear", 1, true) and said[#said]:find("arrow keys", 1, true),
    "the lesson explains tracing by ear with the real keys")
spark.GetCurrentPathSegment = function() return {StartPoint={X=0,Y=0},EndPoint={X=3,Y=-4}} end
spark.GetCurrentPathSegmentIndex = function() return 0 end
widget.BadSpark = { GetTotalDistanceAsPercent = function() return 0 end }
in_window = false
local n_actions, n_moves = #actions, #moves
event("OnStartPressed"); t.run(0.3)
assert(state.steering, "steering keeps the arrows off the review list")
assert(said[#said] == "up right", "the stroke's direction is spoken: " .. tostring(said[#said]))
assert(#played > 0 and played[#played].name == "note" and played[#played].pitch > 1, "a higher bell for a stroke going up")
assert(#moves == n_moves and #actions == n_actions, "nothing moves until the player steers")
held_keys[0x26], held_keys[0x27] = true, true
t.run(0.5)
local m = moves[#moves]
assert(m and m[1] > 0 and m[2] < 0, "held up and right move the wand up and right")
assert(ui[#ui] == "tick", "on course: a tick")
held_keys[0x26], held_keys[0x27], held_keys[0x41] = nil, nil, true
t.run(0.5)
assert(ui[#ui] == "step_blocked", "off course: a buzz")
held_keys[0x41] = nil
checkpoint.InputAction = 77; in_window = true
t.run(0.3)
assert(said[#said] == "space" and ui[#ui] == "chime", "a checkpoint rings and names its key: " .. tostring(said[#said]))
local n_said = #said
t.run(0.5)
assert(#said == n_said, "each checkpoint is announced once")
checkpoint.InputAction = 79; checkpoint.PathSplineIndex = 9
t.run(0.3)
assert(said[#said] == "backslash", "a mouse-button checkpoint names the press key: " .. tostring(said[#said]) .. " | " .. tostring(said[#said-1]))
n_actions = #actions
spells.press(); t.run(0.1)
assert(actions[#actions][1] == 79 and #actions == n_actions + 2, "the press key answers a mouse-button checkpoint")
in_window = false
widget.BadSpark.GetTotalDistanceAsPercent = function() return 0.35 end
local warns = 0
t.run(1.2)
for _, name in ipairs(ui) do if name == "warn" then warns = warns + 1 end end
assert(warns > 0, "the chasing spark close behind sounds an alarm")
event("OnMinigameFailure"); t.run(0.3)
assert(not state.steering and said[#said]:find("Press space to try again", 1, true), "a miss stops steering and says how to retry")
print("spells test passed")
