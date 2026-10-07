-- Menu code must never call into a screen after the game has closed it. On Oct 6 (10:15 PM)
-- the focus poller called GatherMenuReaderStrings on the Field Guide 200 ms after the pause
-- menu closed, when the game had already freed it, and the game crashed: the poller trusted
-- the gate's cached "a menu is up" from its previous tick. Now the UI manager is asked right
-- before every widget read, and a looked-up object whose name no longer matches its path
-- (a destroyed object is renamed None) is treated as gone.
local t = dofile("native/tests/testlib.lua")
for k, v in pairs({ OEM_FOUR = 219, OEM_SIX = 221, OEM_FIVE = 220, OEM_ONE = 186, OEM_SEVEN = 222,
                    OEM_MINUS = 189, OEM_PLUS = 187, F11 = 122, F12 = 123 }) do Key[k] = v end
local objects = {}
local function obj(cls, path, props)
    props.IsValid = function() return true end
    props.GetFullName = function() return cls .. " " .. path end
    props.GetAddress = function() return path end
    props.GetClass = function() return { GetFName = function() return { ToString = function() return cls end } end } end
    props.GetOuter = function() return nil end
    objects[path] = props
    return props
end
local paused = false
local ui = obj("UIManager", "/Game/UI", {
    IsInPreGameplayState = function() return false end, IsAsyncScreenLoadInProgress = function() return false end,
    GetInMenuTransition = function() return false end, InPauseMode = function() return paused end })
local pawn = obj("Biped_Player", "/Game/Player", { InCinematic = false,
    RootComponent = { RelativeLocation = { X = 0, Y = 0, Z = 0 } }, Controller = { ControlRotation = { Yaw = 0 } } })
local tutorial_system = obj("TutorialSystem", "/Game/Tutorials", {})
FindFirstOf = function(cls)
    if cls == "UIManager" then return ui elseif cls == "Biped_Player" then return pawn
    elseif cls == "TutorialSystem" then return tutorial_system end
end
FindAllOf = function() return {} end
StaticFindObject = function(path) return objects[path] end
RegisterLoadMapPostHook = function() end
package.loaded.audio_bridge = { init = function() return true end, play_ui = function() end, listener = function() end, stop_all = function() end }
package.loaded.tips = { once = function() end }
package.loaded.guide = { welcome = function() return "Welcome" end }
local said = {}
require("speech").say = function(s) said[#said + 1] = s end
local world = require("world")
require("menus")
local read_menu = assert(t.hooks["/Script/Phoenix.PhoenixUserWidget:ReadMenu"], "ReadMenu hook registered")

local function screen(path, counter)
    local s = obj("UI_BP_FieldGuide_C", path, { Visibility = 0, RenderOpacity = 1,
        IsInViewport = function() return true end,
        GatherMenuReaderStrings = function() counter.n = counter.n + 1; return { "Select: backslash" } end })
    return s
end

t.run(7)
assert(world.in_game(), "gameplay gate opened")

-- The pause menu opens and the game reads its screen; the mod follows that screen's focus.
paused = true
t.run(0.3)
assert(not world.gameplay(), "a pause menu is a menu")
local calls = { n = 0 }
local guide = screen("/Engine/Transient.GI.UI_BP_FieldGuide_C_1", calls)
read_menu({ get = function() return guide end })
t.run(1.2)
assert(calls.n > 0, "the screen is read while the menu is up")
local before = #said
t.action("review_next")()
assert(#said > before and said[#said]:find("Nothing to read", 1, true), "review keys work on the open screen: " .. tostring(said[#said]))

-- The menu closes. The game frees the screen within a frame; the gate's next look may be
-- 250 ms away. Nothing may call into the screen from now on.
paused = false
local n = calls.n
guide.GatherMenuReaderStrings = function() error("called a widget the game has freed") end
t.run(1.0)
assert(calls.n == n, "no call into the screen after the menu closed")
assert(world.gameplay(), "a closed menu counts as gameplay at once")
before = #said
t.action("review_next")()
assert(said[#said]:find("No menu is open", 1, true) or said[#said]:find("Nothing to read", 1, true),
       "review keys leave the closed screen alone: " .. tostring(said[#said]))

-- The game may free a screen before its flags change: a looked-up object whose name no longer
-- matches its path (destroyed objects are renamed None) is never touched.
paused = true
t.run(1.0)
local ghost_calls = { n = 0 }
local ghost = screen("/Engine/Transient.GI.UI_BP_FieldGuide_C_2", ghost_calls)
read_menu({ get = function() return ghost end })
t.run(1.2)
assert(ghost_calls.n > 0, "the second screen is read while it is up")
ghost.GetFullName = function() return "UI_BP_FieldGuide_C /Engine/Transient.GI.None" end
n = ghost_calls.n
t.run(1.0)
assert(ghost_calls.n == n, "a destroyed (renamed) screen is never called")
t.action("review_next")()
assert(not said[#said]:find("Select", 1, true), "review keys do not read a destroyed screen")

-- A non-modal tutorial can stop the opening scene until G is pressed. It used to announce
-- once, then the review keys said there was nothing to read. Keep its strings, not widgets.
paused = false
t.run(6)
local prompt = obj("UI_BP_Tutorial_NonModal_C", "/Game/TutorialPrompt", {
    Visibility = 0, RenderOpacity = 1, IsInViewport = function() return true end,
    GatherMenuReaderStrings = function() return { "G to Heal." } end })
tutorial_system.CurrentTutorialScreen = prompt
read_menu({ get = function() return prompt end })
t.run(0.6)
prompt.GatherMenuReaderStrings = function() error("must not poll tutorial widgets during gameplay") end
t.action("read_all")()
assert(said[#said]:find("G to Heal", 1, true), "the active tutorial can be re-read in gameplay")
t.action("review_next")()
assert(said[#said]:find("G to Heal", 1, true), "brackets review the active prompt")
tutorial_system.CurrentTutorialScreen = nil
t.run(0.6)
t.action("read_all")()
assert(not said[#said]:find("G to Heal", 1, true), "dismissed tutorials never linger in review")
print("menus test passed")
