-- Wandsong: blind accessibility for Hogwarts Legacy.
-- Speech goes through the player's screen reader (via wandsong_helper.exe and Prism).

local diag = require("diag")   -- first: it captures every later log line
local speech = require("speech")
speech.start()

require("menus")
require("scanner")
require("world")
require("surroundings")
require("path")
require("gamecues")

-- Diagnostics mark: the player says "something odd just happened"; the log records the
-- moment, with what was spoken just before, so it's easy to find afterwards.
local keys = require("keys")
keys.action{
    id = "diag_mark", name = "Mark this moment in the diagnostic log", group = "Menus and screens",
    -- F8: the game uses none of F5-F8. (Ctrl+Shift+M was also the game's M, which opens the map.)
    default = "f8",
    run = function()
        local said = {}
        for i = 3, 1, -1 do
            local s = speech.recent(i)
            if s then said[#said + 1] = '"' .. s .. '"' end
        end
        diag.mark("last spoken: " .. table.concat(said, " / "))
        speech.say("Marked in the log")
    end,
}

speech.say("Wandsong ready. Semicolon for help.")
print("[Wandsong] loaded\n")
