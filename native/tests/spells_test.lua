local t = dofile("native/tests/testlib.lua")
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
print("spells test passed")
