-- Wandsong: blind accessibility for Hogwarts Legacy.
-- Speech goes through the player's screen reader (via wandsong_helper.exe and Prism).

local diag = require("diag")   -- first: it captures every later log line
local speech = require("speech")
speech.start()

require("gamesettings")
require("menus")
require("scanner")
require("world")
require("surroundings")
require("path")
require("gamecues")
require("feedback")
require("combat")
require("hotspots")
require("target")
require("places")
require("subtitles")
require("spells")
require("statues")
require("ai_walk")

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

-- Developer console (Ctrl+Shift+F11): run dev_eval.lua from the mod folder on the game
-- thread and log what it returns. Lets a tester explore live game objects without
-- restarting the game; does nothing unless that file exists.
local function dev_run(chunk)
    local ok, res = pcall(chunk)
    if type(res) == "table" then
        local out = {}
        for k, v in pairs(res) do out[#out + 1] = tostring(k) .. "=" .. tostring(v) end
        table.sort(out)
        res = table.concat(out, "; ")
    end
    return ok, tostring(res)
end
keys.action{
    id = "dev_eval", name = "Developer: run dev_eval.lua and log the result", group = "Menus and screens",
    default = "ctrl+shift+f11",   -- F12 is dev_sdk
    run = function()
        local path = require("files").runtime("dev_eval.lua")
        local chunk, err = loadfile(path)
        if not chunk then diag.log("dev_eval: " .. tostring(err)); speech.say("No developer script"); return end
        local ok, res = dev_run(chunk)
        diag.log("dev_eval " .. (ok and "ok: " or "error: ") .. res)
        speech.say("Developer script " .. (ok and "ran" or "failed"))
    end,
}

-- The same without a key press: tools/dev.ps1 drops dev_request.lua into the mod folder, and
-- within a second it runs on the game thread (never during a load) and its result goes to
-- dev_result.txt. Testing then never has to send keystrokes to the game. Silent: the player
-- hears nothing. Never register hooks from a request (UE4SS keeps the request's Lua thread).
local files = require("files")
local REQUEST, RESULT = files.runtime("dev_request.lua"), files.runtime("dev_result.txt")
require("dispatch").every(1000, function()
    local f = io.open(REQUEST, "r")
    if not f then return end
    local src = f:read("a")
    f:close()
    os.remove(REQUEST)
    local chunk, err = load(src, "=dev_request")
    local ok, res = false, tostring(err)
    if chunk then ok, res = dev_run(chunk) end
    diag.log("dev_request " .. (ok and "ok: " or "error: ") .. res)
    local out = io.open(RESULT, "w")
    if out then out:write((ok and "ok\n" or "error\n") .. res .. "\n"); out:close() end
end, "dev request")

speech.say("Wandsong ready. Semicolon for help.")
print("[Wandsong] loaded\n")
