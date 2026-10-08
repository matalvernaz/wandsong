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
show_task, task_text = true, "Find Professor Fig"
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
print("objective test passed")
