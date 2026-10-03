-- Wandsong: blind accessibility for Hogwarts Legacy.
-- Speech goes through the player's screen reader (via wandsong_helper.exe and Prism).

local speech = require("speech")
speech.start()

require("menus")
require("scanner")

speech.say("Wandsong ready. Semicolon for help.")
print("[Wandsong] loaded\n")
