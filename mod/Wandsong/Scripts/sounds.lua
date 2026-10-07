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
    { "ping", "Objective beacon: a ping from a point about 8 metres along the game's route to your objective. Follow it and you follow the path. Higher means the path goes up, lower means down." },
    { "arrive", "Arrived at your objective." },
    { "step", "Footstep: one per stride while you walk. No steps means you're standing still." },
    { "land", "Landing: you've come down from a jump or a fall." },
    { "step_blocked", "Bump: you're pushing to move but something is in the way." },
    { "wall_preview", "Wall: a soft rushing sound from each nearby wall, louder as you get closer. Silence means open space." },
    { "opening", "Opening: a wall beside you has ended, like a doorway or a side passage. It comes from that side." },
    { "ledge", "Drop-off: the ground falls away ahead of you. Lower means a bigger drop." },
    { "hop", "Low obstacle ahead: something knee-high you can jump or vault over with " .. require("bindings").spoken("AM_Jump", "SpaceBar") .. "." },
    { "climb", "Climbable ledge ahead: walk into it and press " .. require("bindings").spoken("AM_Jump", "SpaceBar") .. " to climb up." },
    { "tick", "Lined up: a soft tick right after an obstacle sound means it's straight ahead of you. Also plays when you turn with the arrow keys." },
    { "warn", "Incoming attack: the high alert means you can block with Protego." },
    { "warn", "Unblockable attack: the lower alert means dodge.", 0.65 },
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
