-- Dialogue choices (the game's option panel, mid-scene). In the Sorting (Oct 8) the game read
-- only the reply in focus; Matt pressed the arrows ("That works once this scene ends"), then the
-- review keys ("Nothing to read on this screen", "No menu is open"), and didn't know Enter says
-- the reply. Each reply now says its place, the first choice says how to choose, the arrows and
-- review keys move through the replies, and the press key says one.
local t = dofile("native/tests/testlib.lua")
for k, v in pairs({ OEM_FOUR = 219, OEM_SIX = 221, OEM_FIVE = 220, OEM_ONE = 186, OEM_SEVEN = 222,
                    OEM_MINUS = 189, OEM_PLUS = 187, F11 = 122, F12 = 123, RETURN = 13 }) do Key[k] = v end
local handlers = {}
RegisterKeyBind = function(key, mods, fn) if type(mods) == "function" then handlers[key] = mods end end
-- The game window "has focus"; nothing is sent to the real desktop.
package.loaded.input_bridge = { focused = function() return true end, key = function() end,
    mouse_move = function() end }
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
local ui = obj("UIManager", "/Game/UI", {
    IsInPreGameplayState = function() return false end, IsAsyncScreenLoadInProgress = function() return false end,
    GetInMenuTransition = function() return false end, InPauseMode = function() return false end })
local pawn = obj("Biped_Player", "/Game/Player", { InCinematic = true,
    RootComponent = { RelativeLocation = { X = 0, Y = 0, Z = 0 } }, Controller = { ControlRotation = { Yaw = 0 } } })

-- The panel: three replies; the game's reader names the one in focus.
local replies = { "I can't wait to start classes.", "I'm worried I'll fall behind.", "I'd rather not say." }
local reads_itself, reader_empty = true, false
local read_menu
local panel = obj("UI_BP_OptionPanel_C", "/Engine/Transient.GI.UI_BP_OptionPanel_C_1", {
    Visibility = 0, CurrentIndex = 0, maxOptionIndex = 2,
    IsInViewport = function() return true end,
    -- The game's reader names the reply in focus, except once the choice has been up a while
    -- (live, Oct 8: empty); each reply's button keeps its text.
    GatherMenuReaderStrings = function(self) return reader_empty and {} or { replies[self.CurrentIndex + 1] } end,
    OptionsArray = { ForEach = function(_, fn)
        for i = 1, 3 do
            fn(i, { get = function() return { Visibility = 4, DisplayText = { GetText = function()
                return { ToString = function() return replies[i] end } end } } end })
        end
    end },
})
local sent = {}
local mgr = { IsValid = function() return true end, OnInputAction = function(_, action, event)
    if event ~= 0 then return end
    sent[#sent + 1] = action
    if action == 53 then panel.CurrentIndex = math.min(panel.CurrentIndex + 1, 2) end
    if action == 52 then panel.CurrentIndex = math.max(panel.CurrentIndex - 1, 0) end
    if (action == 52 or action == 53) and reads_itself then read_menu({ get = function() return panel end }) end
end }
FindFirstOf = function(cls)
    if cls == "UIManager" then return ui elseif cls == "Biped_Player" then return pawn
    elseif cls == "UMGInputManager" then return mgr end
end
FindAllOf = function(cls) if cls == "UI_BP_OptionPanel_C" then return { panel } end return {} end
StaticFindObject = function(path) return objects[path] end
RegisterLoadMapPostHook = function() end
package.loaded.audio_bridge = { init = function() return true end, play_ui = function() end, play = function() end,
    listener = function() end, stop_all = function() end }
package.loaded.tips = { once = function() end, reset = function() end }
package.loaded.guide = { welcome = function() return "Welcome" end }
local said = {}
require("speech").say = function(s) said[#said + 1] = s end
local state = require("state")
require("world")
require("menus")
require("path")
read_menu = assert(t.hooks["/Script/Phoenix.PhoenixUserWidget:ReadMenu"], "ReadMenu hook registered")
t.run(7)   -- a scene: the world gate stays shut

-- The choice comes up: the reply, its place, and how to choose.
read_menu({ get = function() return panel end })
t.run(0.2)
local first = said[#said] or ""
assert(first:find("I can't wait to start classes. 1 of 3", 1, true), "the reply and its place: " .. first)
assert(first:find("Up and down arrows, or w and s, choose a reply; enter says it.", 1, true), "how to choose: " .. first)

-- Down arrow: the next reply, read once (the game reads it out itself).
local before = #said
t.action("turn_around")()
t.run(0.6)
assert(sent[#sent] == 53, "down arrow sends the panel's next-reply action")
assert(#said == before + 1 and said[#said] == "I'm worried I'll fall behind. 2 of 3", "the next reply, once: " .. tostring(said[#said]))

-- Where the game doesn't read it out, the mod does, from the reply's own button.
reads_itself, reader_empty = false, true
before = #said
handlers[Key.OEM_SIX]()   -- ] (review_next)
t.run(0.6)
assert(sent[#sent] == 53, "the review key moves through the replies too")
assert(#said == before + 1 and said[#said] == "I'd rather not say. 3 of 3", "read by the mod: " .. tostring(said[#said]))
t.action("where_am_i")()
t.run(0.6)
assert(sent[#sent] == 52 and said[#said]:find("2 of 3", 1, true), "up arrow goes back: " .. tostring(said[#said]))

-- The press key says the reply; then the arrows are the mod's again.
t.action("press")()
t.run(0.2)
assert(sent[#sent] == 54, "the press key sends the panel's confirm action")
local count = #sent
assert(not state.choice_step(1) and #sent == count, "once a reply is said, no choice is up")

-- Enter (the game's own key for it) ends the choice too; the hint isn't repeated.
reads_itself, reader_empty = true, false
panel.CurrentIndex = 0   -- the next conversation's choice
local before_read = #said
read_menu({ get = function() return panel end })
t.run(0.2)
assert(#said == before_read + 1 and said[#said]:find(" of 3", 1, true), "a new choice is read: " .. tostring(said[#said]))
assert(not said[#said]:find("Up and down arrows", 1, true), "the hint comes once a session")
handlers[Key.RETURN]()
t.run(0.2)
count = #sent
assert(not state.choice_step(1) and #sent == count, "Enter said the reply: no choice is up")
print("choices test passed")
