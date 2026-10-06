-- Runs controls.lua and keys.lua outside the game with UE4SS stubbed out, against a COPY of
-- the player's Input.ini (pointed to by LOCALAPPDATA). Usage, from native\build\Release:
--   set LOCALAPPDATA=<temp dir containing "Hogwarts Legacy\Saved\Config\WindowsNoEditor\Input.ini">
--   luahost.exe controls_test.lua

-- Never run against the player's real settings: this test rebinds keys and applies presets.
if not (os.getenv("LOCALAPPDATA") or ""):lower():find("temp", 1, true) then
    print("controls test skipped: point LOCALAPPDATA at a temp copy of the game's config first (see above)")
    return
end

local scripts = "C:/claudeProjects/wandsong/mod/Wandsong/Scripts"
package.path = scripts .. "/?.lua;" .. package.path

-- Minimal UE4SS stand-ins.
LoopAsync = function() end
ExecuteInGameThread = function(f) f() end
local binds = 0
RegisterKeyBind = function() binds = binds + 1 end
ModifierKey = { SHIFT = 1, CONTROL = 2, ALT = 3 }
Key = { OEM_FOUR = 219, OEM_SIX = 221, OEM_FIVE = 220, OEM_ONE = 186, OEM_SEVEN = 222,
        OEM_TWO = 191, OEM_MINUS = 189, OEM_PLUS = 187, F9 = 120, ESCAPE = 27, J = 74,
        NINE = 57, DEL = 46, INS = 45, NUM_FIVE = 101 }

local keys = require("keys")
print("binds registered: " .. binds)

-- A couple of mod actions, as menus.lua would declare them.
keys.action{ id = "press", name = "Press the current item", group = "Menus and screens", default = "\\", run = function() end }
keys.action{ id = "scan", name = "What's around me", group = "In the world", default = "f9", run = function() end }

local controls = require("controls")
local items = controls.items()
print("items: " .. #items)
for i = 1, math.min(18, #items) do print("  " .. items[i].text) end

-- Simulate rebinding the basic cast to Slash through the menu's own flow.
local said = {}
local speech = require("speech")
speech.say = function(t) said[#said + 1] = t end
for _, it in ipairs(items) do
    if it.text:find("^Basic cast") then
        it.on_press()
        print("prompt: " .. said[#said])
        -- Pretend the player pressed J (the game's quest key): expect a clash warning? J is a
        -- single game key, so the game binding is allowed with a note.
        keys.capture_next(nil)
        break
    end
end
-- Drive the capture directly: press Slash.
local capture_fn
local real_capture = keys.capture_next
keys.capture_next = function(fn) capture_fn = fn end
for _, it in ipairs(controls.items()) do
    if it.text:find("^Basic cast") then it.on_press(); break end
end
capture_fn("/", "OEM_TWO")
print("after slash: " .. said[#said])
for _, it in ipairs(controls.items()) do
    if it.text:find("^Basic cast") then print("  now: " .. it.text) end
end
-- NVDA key and a mod-key clash.
for _, it in ipairs(controls.items()) do
    if it.text:find("^Dodge") then it.on_press(); break end
end
capture_fn("insert", "INS")
print("insert: " .. said[#said])
capture_fn("\\", "OEM_FIVE")
print("backslash: " .. said[#said])
keys.capture_next = real_capture
