-- Audit A18: a checkpoint is named with the key that answers it, and the press key answers
-- exactly the checkpoints it was named for: mouse-only or unbound options of any number. A
-- checkpoint with a keyboard key of its own (default or remapped) is named by that key.
local t = dofile("native/tests/testlib.lua")
Key.OEM_FIVE = 220   -- backslash, the press key
local f = assert(io.open(require("files").input(), "w"))
f:write('ActionMappings=(ActionName="UMGSpellMinigameOption1",Key=LeftMouseButton,GroupName="MinigamesGlobal")\n')
f:write('ActionMappings=(ActionName="UMGSpellMinigameOption3",Key=G,GroupName="MinigamesGlobal")\n')
f:close()
local events, actions, said = {}, {}, {}
RegisterCustomEvent = function(name, fn) events[name] = fn end
local state = require("state")
local keys = require("keys")
keys.action{ id = "press", name = "Press", default = "\\", run = function() end }
package.loaded.input_bridge = { focused = function() return true end, down = function() return false end,
    mouse_move = function() return true end }
package.loaded.audio_bridge = { init = function() return true end, play = function() end, play_ui = function() end }
package.loaded.world = { position = function() return 0, 0, 0, 0 end, sounds_enabled = function() return true end }
local speech = require("speech")
speech.say = function(s) said[#said + 1] = s end
speech.alert = function(s) said[#said + 1] = s end
local checkpoint, in_window = nil, false
local spark = { IsValid = function() return true end, IsRunning = true,
    GetCurrentPathSegment = function() return { StartPoint = { X = 100, Y = 900 }, EndPoint = { X = 100, Y = 500 } } end,
    GetCurrentPathSegmentIndex = function() return 0 end,
    GetPosition = function() return { X = 100, Y = 800 } end,
    GetTotalDistanceAsPercent = function() return 0.3 end }
local path = "/Game/UI_SpellMiniGame_C_1"
local widget = { Visibility = 0, IsValid = function() return true end, PlayerSpark = spark,
    GetFullName = function() return "SpellMiniGameBase " .. path end,
    GetMiniGameName = function() return { ToString = function() return "Lumos" end } end,
    GetIsWaitingForStart = function() return false end,
    GetIsInInputWindow = function() return in_window end,
    GetCurrentCheckpointData = function() return checkpoint end }
StaticFindObject = function(p) if p == path then return widget end end
FindFirstOf = function(cls)
    if cls == "UMGInputManager" then
        return { IsValid = function() return true end,
                 OnInputAction = function(_, code, kind) actions[#actions + 1] = { code, kind } end }
    end
end
local function event(name, number)
    events[name]({ get = function() return widget end }, { get = function() return number end })
end
local spells = require("spells")
local function assisted() return spells.items()[3].text == "Stop tracing assistance" end

event("OnMinigameFullyLoaded"); t.run(0.3)
event("OnStartPressed"); t.run(0.3)
assert(not assisted(), "traced by ear")
-- One checkpoint window after another: what it is named, and what the press key does there.
local cases = {
    { code = 77, named = "backslash", answered = true, why = "option 1 on the mouse only" },
    { code = 78, named = "f", answered = false, why = "option 2's default keyboard key" },
    { code = 79, named = "g", answered = false, why = "option 3 remapped to a keyboard key" },
    { code = 80, named = "backslash", answered = true, why = "option 4 unbound" },
}
for i, c in ipairs(cases) do
    checkpoint = { InputAction = c.code, PathSplineIndex = i, InputWindow = { X = 150, Y = 100 } }
    in_window = true; t.run(0.3)
    assert(said[#said] and said[#said]:find(c.named, 1, true), c.why .. ": named " .. tostring(said[#said]))
    local n = #actions
    spells.press(); t.run(0.1)
    if c.answered then
        assert(#actions == n + 2 and actions[n + 1][1] == c.code, c.why .. ": the press key answers it")
        assert(not assisted(), c.why .. ": the lesson stays traced by ear")
    else
        -- (Assistance, once started, answers the open checkpoint itself.)
        assert(assisted(), c.why .. ": the press key keeps its own meaning, tracing assistance")
        spells.press(); t.run(0.1)
        assert(not assisted(), "assistance stopped again")
        event("OnStartPressed"); t.run(0.1)
    end
    in_window = false; t.run(0.3)
end
print("spell checkpoint keys test passed")
