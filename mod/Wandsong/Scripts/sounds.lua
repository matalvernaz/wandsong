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
    { "note", "Ancient magic hotspot: a deep bell from where ancient magic gathers, even far off. The game leads sighted players there with wisps of light.", 0.6 },
    { "item", "Something to use you picked with the scanner, like a lever: a higher sparkle, until you reach it.", 1.25 },
    { "ping", "Objective beacon: a ping from a point about 8 metres along the game's route to your objective. Follow it and you follow the path. Higher means the path goes up, lower means down." },
    { "arrive", "Arrived at your objective, or at the thing you picked with the scanner." },
    { "step", "Footstep: one per stride while you walk. No steps means you're standing still." },
    { "land", "Landing: you've come down from a jump or a fall." },
    { "step_blocked", "Bump: you're pushing to move but something is in the way." },
    { "wall_preview", "Wall: a soft rushing sound from each nearby wall, louder as you get closer. Silence means open space." },
    { "opening", "Opening: a wall beside you has ended, like a doorway or a side passage. It comes from that side." },
    { "ledge", "Drop-off: the ground falls away ahead of you. Lower means a bigger drop." },
    { "hop", "Low obstacle ahead: something knee-high you can jump or vault over with " .. require("bindings").spoken("AM_Jump", "SpaceBar") .. "." },
    { "climb", "Climbable ledge ahead: walk into it and press " .. require("bindings").spoken("AM_Jump", "SpaceBar") .. " to climb up." },
    { "tick", "Lined up: a soft tick right after an obstacle sound means it's straight ahead of you. Also plays when you turn with the arrow keys." },
    { "tick", "New target: a higher tick from where the enemy is when the game picks a new target for your spells. Locking on says its name and shield.", 1.3 },
    { "item", "Loot: the collectible sparkle from where something dropped, when the game's audio cues mark loot." },
    { "warn", "Incoming attack: the high alert means you can block with Protego." },
    { "warn", "Unblockable attack: the lower alert means dodge.", 0.65 },
    { "chime", "A block that worked: a bright chime, right after you block an attack.", 1.6 },
    { "tick", "Your spell hitting an enemy: a soft tick; higher means a weak spot.", 1.6 },
    { "note", "Statue puzzle, the knight's bell: a clear bell from where a puzzle knight kneels." },
    { "note", "Spell lesson, the way to go: a bell from the left or the right, higher for up and lower for down. It repeats while you're off course or not steering.", 1.3 },
    { "tick", "Spell lesson, on course: the arrow you hold points the way the stroke goes.", 1.3 },
    { "step_blocked", "Spell lesson, off course: the arrow you hold points another way." },
    { "chime", "Spell lesson, checkpoint: press the key named just before it, now.", 1.3 },
    { "item", "Spell lesson, a checkpoint press that counted: the spark speeds up.", 1.2 },
    { "warn", "Spell lesson, the chasing spark is close behind: keep the wand moving.", 1.4 },
    { "hum_preview", "Statue puzzle, a knight's line of sight: its hum, from the nearest point of the line it looks along, louder the closer you are. With your light on that line, the knight stands; three knights' hums make a chord where all their lines meet." },
}

function M.items()
    local world = require("world")
    local items = { { text = "Each sound below plays when you press it. Positioned sounds come from where the thing is; these previews play in the centre." },
                    { text = "Nearby things sound once as they come near, again as you pass close to a door, chest or collectible, and otherwise softly every 20 seconds. Enemies keep growling, and the thing you picked with the scanner keeps sounding until you reach it." } }
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
