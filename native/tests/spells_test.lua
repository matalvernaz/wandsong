local t = dofile("native/tests/testlib.lua")
Key.OEM_FIVE = 220   -- backslash, the press key
local events, actions, moves, said, kinds = {}, {}, {}, {}, {}
RegisterCustomEvent = function(name, fn) events[name] = fn end
local focus, visible, waiting = true, true, true
local state = require("state")
local keys = require("keys")
keys.action{ id = "press", name = "Press", default = "\\", run = function() end }
package.loaded.input_bridge = { focused = function() return focus end,
    mouse_move = function(x,y) moves[#moves+1] = {x,y}; return true end }
local speech = require("speech")
speech.say = function(s, queue) said[#said+1] = s; kinds[#said] = queue and "queued" or "say" end
speech.alert = function(s) said[#said+1] = s; kinds[#said] = "alert" end
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

-- The symbol as the player hears it. Revelio, segment by segment as the spark ran it in Matt's
-- attempt (Oct 8): a stem up, a curve round to the right and back, a leg down to the right.
local rel = { {0,-613}, {16,-86}, {39,-65}, {61,-61}, {81,-38}, {62,-12}, {84,10}, {82,40}, {33,31},
    {42,49}, {25,51}, {14,63}, {2,59}, {-8,54}, {-22,52}, {-28,42}, {-36,41}, {-49,30}, {-64,24},
    {-62,8}, {210,227} }
local revelio, x0, y0 = {}, 500, 900
for _, r in ipairs(rel) do revelio[#revelio+1] = { x0, y0, x0 + r[1], y0 + r[2] }; x0, y0 = x0 + r[1], y0 + r[2] end
local function words(segs, complete)
    local out = {}
    for _, s in ipairs(spells.strokes(segs, complete)) do out[#out+1] = s.word end
    return table.concat(out, ", ")
end
assert(words(revelio, true) == "up, right, down, left, down right",
    "a curve is named by the arrows it turns through: " .. words(revelio, true))
assert(words({ {154,916,508,131}, {508,131,871,947} }, true) == "up right, down right",
    "Lumos, a V of two diagonal strokes: " .. words({ {154,916,508,131}, {508,131,871,947} }, true))
assert(words({ {0,0,300,0}, {300,0,340,-10}, {340,-10,640,-10} }, true) == "right",
    "a short jog is part of the stroke around it")
-- On course: within 67.5 degrees of the stroke, here or a little behind or ahead.
local corner = { {0,600,0,300}, {0,300,300,300} }   -- up 300, then right 300
assert(spells.accepts(corner, 100, 0, -1), "up on the up stroke")
assert(not spells.accepts(corner, 100, 1, 0), "right long before the corner is off course")
assert(spells.accepts(corner, 220, 1, 0), "right just before the corner: anticipation counts")
assert(spells.accepts(corner, 400, 0, -1), "still up just after the corner: reaction time counts")
assert(not spells.accepts(corner, 500, 0, -1), "still up well after the corner is off course")
assert(spells.accepts({ {0,100,100,0} }, 50, 1, 0), "right alone on a 45 degree up right stroke")
assert(not spells.accepts({ {0,100,100,0} }, 50, 0, 1), "down on an up right stroke is off course")
assert(spells.along(corner, corner[2], { 150, 290 }) == 450, "distance along the path")

event("OnMinigameFullyLoaded"); t.run(0.3)
assert(state.spell_lesson == path and state.activity == spells, "lesson immediately blocks world features")
t.run(0.3)
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
state.mark_loading(1); t.run(1.5)
-- Fresh module state for the by-ear part (audio is captured from here on).
package.loaded.audio_bridge = { init = function() return true end,
    play = function(name, x, y, z, vol, pitch) played[#played + 1] = { name = name, pitch = pitch } end,
    play_ui = function(name, vol, pitch) ui[#ui + 1] = name end }
package.loaded.spells = nil
package.loaded.world = { position = function() return 0, 0, 0, 0 end, sounds_enabled = function() return true end }
spells = require("spells")
local function count(list, name)
    local c = 0
    for _, v in ipairs(list) do if v == name or (type(v) == "table" and v.name == name) then c = c + 1 end end
    return c
end

-- The symbol here: up 400, then right 400. The game hands its path over as the lesson sets up.
local segs = { {100,900,100,500}, {100,500,500,500} }
local seg, index, pos = 1, 0, { 100, 900 }
spark.GetCurrentPathSegment = function()
    local s = segs[seg]
    return { StartPoint = {X=s[1],Y=s[2]}, EndPoint = {X=s[3],Y=s[4]} }
end
spark.GetCurrentPathSegmentIndex = function() return index end
spark.GetPosition = function() return { X = pos[1], Y = pos[2] } end
spark.GetTotalDistanceAsPercent = function() return 0.5 end
widget.BadSpark = { GetTotalDistanceAsPercent = function() return 0 end }
checkpoint = { InputAction = 77, PathSplineIndex = 0, InputWindow = {X=150,Y=100}, Location = {X=100,Y=650} }
waiting, in_window = true, false
local function spline_param(list)
    return { get = function() return { PathSegments = { ForEach = function(_, fn)
        for i, s in ipairs(list) do
            fn(i, { get = function() return { StartPoint = {X=s[1],Y=s[2]}, EndPoint = {X=s[3],Y=s[4]} } end })
        end
    end } } end }
end
events.OnPathSplineSet({get=function() return widget end}, spline_param(segs))
event("OnMinigameFullyLoaded"); t.run(0.3)
local intro = said[#said]
assert(intro:find("Arrows: up, right.", 1, true), "the symbol's arrows are said before starting: " .. intro)
assert(intro:find("the first is space, right after the start", 1, true), "the first checkpoint's key is known before starting: " .. intro)
assert(spells.tutorial() == "", "the game's tracing tutorial right after doesn't repeat the introduction")

local n_actions, n_moves = #actions, #moves
event("OnStartPressed"); t.run(0.2)
assert(state.steering, "steering keeps the arrows off the review list")
assert(said[#said] == "up. space next" and kinds[#said] == "alert",
    "the first stroke and the coming checkpoint's key, together: " .. tostring(said[#said]))
assert(#moves == n_moves and #actions == n_actions, "nothing moves until the player steers")
t.run(0.8)
assert(count(played, "note") > 0 and played[#played].pitch > 1, "not steering: a higher bell for the way up")
held_keys[0x26] = true
t.run(0.5)
local mv = moves[#moves]
assert(mv and mv[1] == 0 and mv[2] == -80, "held up moves the wand up the stroke")
assert(ui[#ui] == "tick", "on course: a tick")
local n_said = #said
pos = { 100, 640 }; in_window = true; t.run(0.2)
assert(ui[#ui] == "chime" or count(ui, "chime") > 0, "the checkpoint's window opens with a chime")
assert(#said == n_said, "a key named before its window isn't named again with the chime")
event("OnInputSuccess", 0); t.run(0.2)
assert(ui[#ui] == "item", "a press that counted sparkles")
-- The next checkpoint's key is named first; the stroke word straight after it waits its turn.
in_window = false
checkpoint = { InputAction = 78, PathSplineIndex = 1, InputWindow = {X=150,Y=100}, Location = {X=400,Y=500} }
pos = { 100, 700 }; t.run(0.1)
assert(said[#said] == "f next" and kinds[#said] == "alert", "the coming checkpoint's key: " .. tostring(said[#said]))
pos = { 100, 560 }; t.run(0.2)
assert(said[#said] == "right" and kinds[#said] == "queued", "a stroke word doesn't cut a key's name off: " ..
    tostring(said[#said]) .. " " .. tostring(kinds[#said]))
-- Round the corner, the old arrow counts for a moment.
seg, index, pos = 2, 1, { 150, 500 }; t.run(0.5)
mv = moves[#moves]
assert(mv[1] == 80 and mv[2] == 0 and ui[#ui] == "tick", "up just after the corner still follows the stroke")
pos = { 300, 500 }; local n_played = #played; t.run(0.5)
mv = moves[#moves]
assert(mv[1] == 0 and mv[2] == -80 and ui[#ui] == "step_blocked", "up well after the corner is off course")
assert(#played > n_played, "off course: the bell points the way")
held_keys[0x26], held_keys[0x27] = nil, true; t.run(0.5)
assert(ui[#ui] == "tick", "right on the right stroke: on course")
held_keys[0x27] = nil
-- A mouse-button checkpoint: named with its chime, answered with the press key.
checkpoint = { InputAction = 79, PathSplineIndex = 9, InputWindow = {X=150,Y=100} }
in_window = true; t.run(0.3)
assert(said[#said] == "backslash" and ui[#ui] == "chime", "a mouse-button checkpoint names the press key: " .. tostring(said[#said]))
n_said = #said; t.run(0.5)
assert(#said == n_said, "each checkpoint is announced once")
n_actions = #actions
spells.press(); t.run(0.1)
assert(actions[#actions][1] == 79 and #actions == n_actions + 2, "the press key answers a mouse-button checkpoint")
in_window = false
widget.BadSpark.GetTotalDistanceAsPercent = function() return 0.45 end
local warns = count(ui, "warn")
t.run(1.2)
assert(count(ui, "warn") > warns, "the chasing spark close behind sounds an alarm")
event("OnInputFailure", 2); t.run(0.2)
event("OnMinigameFailure"); t.run(0.3)
local miss = said[#said]
assert(not state.steering and miss:find("Press space to try again", 1, true), "a miss stops steering and says how to retry")
assert(miss:find("50 percent of the way", 1, true) and miss:find("at the right stroke", 1, true), "where it was caught: " .. miss)
assert(miss:find("Chimes answered: 1 of 2", 1, true), "how the checkpoints went: " .. miss)

-- Without the game's path the way is recorded as the spark runs, and named as it comes.
state.mark_loading(1); t.run(1.5)
seg, index, pos = 1, 0, { 100, 900 }
checkpoint = { InputAction = 77, PathSplineIndex = 0, InputWindow = {X=150,Y=100} }
event("OnMinigameFullyLoaded"); t.run(0.6)
assert(said[#said]:find("Revelio lesson", 1, true) and not said[#said]:find("Arrows", 1, true),
    "no arrows promised when the symbol isn't known: " .. said[#said])
event("OnStartPressed"); t.run(0.2)
assert(said[#said] == "up", "the first stroke from the spark's own segment: " .. tostring(said[#said]))
seg, index, pos = 2, 1, { 120, 500 }; t.run(0.2)
assert(said[#said] == "right", "the next stroke as the spark reaches it: " .. tostring(said[#said]))
-- A path from the game that doesn't hold the spark's segment isn't trusted.
event("OnMinigameFailure"); t.run(0.3)
events.OnPathSplineSet({get=function() return widget end}, spline_param({ {0,0,0,-50}, {0,-50,50,-50} }))
t.run(0.2)
seg, index, pos = 1, 0, { 100, 900 }
event("OnStartPressed"); t.run(0.2)
assert(said[#said] == "up", "a mismatched path falls back to the recorded one: " .. tostring(said[#said]))
print("spells test passed")
