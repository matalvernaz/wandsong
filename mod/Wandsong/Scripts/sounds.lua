-- Sounds: a legend of every Wandsong sound. Each entry says what the sound means;
-- pressing it plays it. Shown as a mod screen through the review keys.

local M = { title = "Wandsong sounds" }

local LEGEND = {
    { "chime", "Chime: you're in the world and Wandsong's world sounds are on. Plays when gameplay starts." },
    { "person", "Person nearby: a student, professor or ghost. It plays from where they are." },
    { "person", "Creature nearby: the same sound, lower.", 0.7 },
    { "enemy", "Enemy nearby: a low growl from where it is, repeating more often than other sounds." },
    { "door", "Door: a low knock from the door's position." },
    { "item", "Collectible, like a Field Guide page: a bright sparkle." },
    { "item", "Chest: the same sparkle, lower.", 0.8 },
    { "ping", "Objective beacon: where your current objective is. Coming soon." },
    { "tick", "Beacon tick: comes faster as you get closer. Coming soon." },
    { "arrive", "Arrived at your objective. Coming soon." },
    { "warn", "Incoming attack: block or dodge now. Coming soon." },
    { "step_blocked", "Bumped into something you can't walk through. Coming soon." },
    { "wall", "A wall close by on that side. Coming soon." },
    { "opening", "An opening or doorway on that side. Coming soon." },
}

function M.items()
    local world = require("world")
    local items = { { text = "Each sound below plays when you press it. Positioned sounds come from where the thing is; these previews play in the centre." } }
    for _, e in ipairs(LEGEND) do
        local name, text, pitch = e[1], e[2], e[3]
        items[#items + 1] = {
            text = text, button = true,
            on_press = function() world.preview(name, pitch) end,
        }
    end
    return items
end

return M
