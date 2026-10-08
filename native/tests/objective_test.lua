-- Objectives as the HUD shows them: the quest's title alone (between two tasks) isn't a new
-- objective; and an objective naming someone the story has introduced ("Find Professor Fig")
-- is walked to when the game gives no route and no destination (the vault, Oct 8: Fig was
-- 100 m away in the dark and autowalk had nowhere to go).
local t = dofile("native/tests/testlib.lua")
local said, vks = {}, {}
local yaw = 0
local px, py = 0, 0
package.loaded.audio_bridge = { init = function() return true end, play = function() return true end,
    play_ui = function() return true end, loop = function() return true end, stop = function() end, stop_all = function() end }
package.loaded.input_bridge = { focused = function() return true end,
    key = function(vk, down) vks[#vks + 1] = { vk = vk, down = down }; return true end,
    mouse_move = function(dx) yaw = (yaw + dx * 0.04 + 180) % 360 - 180; return true end,
    down = function() return false end }
local fig = { path = "/Game/Vault.BP_Student_C_1", kind = "person", name = "Professor Fig", name_src = "subtitles",
              x = 10000, y = 0, z = 0 }
local controller = { ControlRotation = setmetatable({ Pitch = 0 }, { __index = function(_, k) if k == "Yaw" then return yaw end end }) }
package.loaded.world = {
    in_game = function() return true end, ui_busy = function() return false end,
    pawn = function() return { Controller = controller } end,
    position = function() return px, py, 0, yaw end,
    nearest = function() return nil end,
    entries = function() return { fig } end,
    locate = function(path) if path == fig.path then return { fig.x, fig.y, fig.z } end end,
}

-- The game's path manager: no route, no destination.
local empty = { GetArrayNum = function() return 0 end }
local mgr = { PathTS = empty, GuidePathPoints = empty, IsValid = function() return true end,
              GetFullName = function() return "BP_PathNavigationManager_C /Game/Fake.Mgr" end,
              GetMissionDestinationLocation = function() return { X = 0, Y = 0, Z = 0 } end }
local nav_to
mgr.FindPathToLocationSynchronously = function(_, _, from, to)
    nav_to = to
    local pts = { { X = from.X, Y = from.Y, Z = 0 }, { X = to.X, Y = to.Y, Z = 0 } }
    return { PathPoints = setmetatable({ GetArrayNum = function() return #pts end }, { __index = function(_, i) return pts[i] end }) }
end
-- The HUD's quest banner and task checkboxes.
local function widget(path, field, text_of)
    local w = { IsValid = function() return true end, IsVisible = function() return true end,
                GetFullName = function() return "UI_Widget_C " .. path end }
    w[field] = { GetText = function() return { ToString = function() return text_of() end } end }
    return w
end
local task_text = "Protego incoming enemy attacks (1/3)"
local banner = widget("/Engine/Transient.Banner", "StepTitleText", function() return "The Path to Hogwarts" end)
local task = widget("/Engine/Transient.Task", "CheckboxText", function() return task_text end)
local show_task = true
FindAllOf = function(cls)
    if cls == "BP_PathNavigationManager_C" then return { mgr } end
    if cls == "UI_BP_MissionBanner_New_C" then return { banner } end
    if cls == "UI_BP_MissionBannerCheckbox_C" then return show_task and { task } or {} end
    return {}
end
StaticFindObject = function(p)
    if p == "/Engine/Transient.Banner" then return banner end
    if p == "/Engine/Transient.Task" then return show_task and task or nil end
    return mgr
end
require("speech").say = function(s) said[#said + 1] = s end
require("path")

t.run(4.5)                                   -- first reading: not announced
assert(#said == 0, "the first objective isn't announced: " .. tostring(said[1]))
show_task = false                            -- between tasks: the title alone
t.run(16)
for _, s in ipairs(said) do assert(not s:find("New objective", 1, true), "title alone announced: " .. s) end
-- The counter moving on is progress, said short; a counted task that's new is said in full.
show_task, task_text = true, "Protego incoming enemy attacks (2/3)"
t.run(16)
assert(said[#said] == "2 of 3.", "progress on the same task: " .. tostring(said[#said]))
task_text = "Destroy statues (0/4)"
t.run(16)
assert(said[#said] == "New objective: Destroy statues, 0 of 4.", "a new counted task: " .. tostring(said[#said]))
-- The HUD names the action by its icon; the key that does it is said too.
task_text = "Tap to destroy statues with Basic Cast"
t.run(16)
assert(said[#said] == "New objective: Destroy statues with Basic Cast (left mouse button)",
    "the objective names the key: " .. tostring(said[#said]))
task_text = "Find Professor Fig"
t.run(16)
local found = false
for _, s in ipairs(said) do if s == "New objective: Find Professor Fig" then found = true end end
assert(found, "the new task is announced: " .. table.concat(said, " | "))

-- No route and no destination: the objective names Fig, so Fig is where autowalk goes.
t.action("autowalk")()
assert(said[#said]:find("^Walking to the objective"), "walks to the person the objective names: " .. tostring(said[#said]))
t.run(1)
assert(nav_to and nav_to.X == 10000, "the navmesh is asked for a path to Fig")

-- The game puts the player back (the dark maze returns you to its start when you stray):
-- autowalk stops instead of walking into it again and again.
px = -3000
t.run(0.5)
assert(said[#said]:find("the game moved you back", 1, true), "stops when moved back: " .. tostring(said[#said]))

-- "Stay close to Professor Fig" holds after the objective moves on: wandering 15 m off
-- failed the quest (Oct 8, the statue puzzle). Past 10 m the mod says where Fig is, past 14 m
-- again, urgently; back within 7 m, it starts over.
local alerts = {}
require("speech").alert = function(s) alerts[#alerts + 1] = s end
px, py, fig.x, fig.y = 0, 0, 300, 0
task_text = "Stay Close to Professor Fig"
t.run(5)
task_text = "Discover the statue's secret"
t.run(5)
assert(#alerts == 0, "close by: nothing")
px = -800
t.run(2)
assert(alerts[1] and alerts[1]:find("^Professor Fig is ahead, 11 metres%. Stay close, or the quest fails%."),
    "past 10 m, where Fig is: " .. tostring(alerts[1]))
t.run(3)
assert(#alerts == 1, "said once")
px = -1200
t.run(2)
assert(alerts[2] and alerts[2]:find("^Go back to Professor Fig now", 1), "past 14 m, urgently: " .. tostring(alerts[2]))
px = 0
t.run(2)
px = -800
t.run(2)
assert(#alerts == 3, "back close by, it starts over")
require("state").mark_loading(1)
t.run(3)
px = -1500
t.run(3)
assert(#alerts == 3, "a load ends it")
print("objective test passed")
