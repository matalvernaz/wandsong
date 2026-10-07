-- Tips: one-time explanations, spoken the first time something comes up (the first time in
-- the world, the first enemy, the first ledge...) and remembered across sessions in
-- tips_seen.txt beside the mod, so they don't repeat. Each tip queues behind whatever is being
-- said rather than interrupting it.

local speech = require("speech")
local keys = require("keys")

local M = {}

local FILE = require("files").runtime("tips_seen.txt", false)

local seen = {}
do
    local f = io.open(FILE, "r")
    if f then
        for line in f:lines() do seen[line] = true end
        f:close()
    end
end

--- The spoken name of a mod action's current key, e.g. "page down".
function M.key(id) return keys.describe_combo(keys.combo_of(id)) end

--- Say `text` (a string, or a function returning one) the first time `id` comes up.
function M.once(id, text)
    if seen[id] then return false end
    seen[id] = true
    local f = io.open(FILE, "a")
    if f then f:write(id .. "\n"); f:close() end
    speech.say(type(text) == "function" and text() or text, true)
    return true
end

--- Forget every tip, so they all play again (from the guide).
function M.reset()
    seen = {}
    os.remove(FILE)
end

return M
