-- Guide: how Wandsong works, as a mod screen read with the review keys. Opened with
-- the help key in the world (in menus the help key describes the screen instead). Keys are
-- named as currently bound, so the guide stays right after rebinding.

local tips = require("tips")
local k = tips.key

local M = { title = "Wandsong guide" }

local function sections()
    return {
        { "Getting started",
          "Wandsong describes the world with sound while you play, without any keys. " ..
          "Keys are only for extra detail. Go through this guide with " .. k("review_next") .. " and " ..
          k("review_prev") .. ", and close it with " .. k("back") .. "." },
        { "What you hear",
          "People make a soft two-note sound from where they stand, creatures the same sound lower, " ..
          "enemies a low growl. Chests and collectibles sparkle, doors knock. Walls are a soft rush that " ..
          "gets louder as you get closer; an airy burst means a wall beside you has ended, like a doorway. " ..
          "The objective beacon pings along the game's route to your objective. Press " .. k("sounds") ..
          " to hear every sound with its meaning, and " .. k("what_was_that") .. " to have the last sounds named." },
        { "Jumping, climbing and drops",
          "A quick two-note hop means something low ahead: press space to jump over it. Four rising notes mean " ..
          "a ledge you can climb: walk into it and press space. Falling notes mean the ground drops away ahead. " ..
          "A soft tick right after means it's straight ahead of you." },
        { "What's around you: the scanner",
          k("scan_next") .. " and " .. k("scan_prev") .. " go through the things around you, nearest first, " ..
          "with their name, distance and direction. " .. k("scan_repeat") .. " says the current one again, freshly. " ..
          k("scan_cat_next") .. " and " .. k("scan_cat_prev") .. " pick a category: the quest objective, " ..
          "people, enemies, creatures, chests, collectibles, doors or things to use; empty ones are skipped. " ..
          k("scan_repeat") .. " also turns you to face it, and " .. k("scan_walk") .. " walks you there." },
        { "Getting where you're going",
          k("autowalk") .. " walks you along the game's route to your objective, or follows the person " ..
          "leading you when there is one; any movement key stops it. W A S D move you yourself. " ..
          k("turn_left") .. " and " .. k("turn_right") .. " turn you 45 degrees, with shift for 90, and " ..
          k("turn_around") .. " turns you round. " .. k("where_am_i") .. " says which way you face and where " ..
          "the objective is. " .. k("beacon_toggle") .. " turns the beacon off or on." },
        { "Spells and fighting",
          k("face_target") .. " turns you to the nearest enemy. Forward slash casts your basic spell at " ..
          "whatever is in front of you, period locks on to a target, Q blocks, and left control dodges. " ..
          "1 to 4 cast your other spells." },
        { "Menus and screens",
          "In menus, " .. k("review_next") .. " and " .. k("review_prev") .. " go through everything on the " ..
          "screen, " .. k("press") .. " presses the current item, and " .. k("back") .. " goes back. " ..
          k("read_all") .. " reads the whole screen, and " .. k("help") .. " describes it; press it twice " ..
          "for every key. " .. k("controls") .. " opens the Controls menu, where you can change any key, " ..
          "the game's included." },
        { "Speech",
          k("repeat") .. " repeats what was said; press it again to go further back. " .. k("mute") ..
          " turns Wandsong's speech and sounds off or on, and " .. k("world_toggle") ..
          " just the world sounds. If something goes wrong, " .. k("diag_mark") .. " marks the moment in " ..
          "the log so it can be fixed." },
    }
end

function M.items()
    local items = {}
    for _, s in ipairs(sections()) do
        items[#items + 1] = { text = s[1] .. ". " .. s[2] }
    end
    -- Every key, grouped, as currently bound (a key glossary, as other access mods have).
    local keys = require("keys")
    local groups, order = {}, {}
    for _, a in ipairs(keys.actions()) do
        if not a.id:find("^dev_") and not a.id:find("dump") then
            if not groups[a.group] then groups[a.group] = {}; order[#order + 1] = a.group end
            table.insert(groups[a.group], keys.describe_combo(a.combo) .. ": " .. a.name)
        end
    end
    for _, g in ipairs(order) do
        items[#items + 1] = { text = "Keys, " .. g .. ". " .. table.concat(groups[g], ". ") .. "." }
    end
    items[#items + 1] = { text = "Open the Controls menu, to change any key", button = true, on_press = function()
        require("state").open_screen(require("controls"), "change one")
    end }
    items[#items + 1] = { text = "Learn the sounds", button = true, on_press = function()
        require("state").open_screen(require("sounds"), "hear it")
    end }
    items[#items + 1] = { text = "Play the first-time tips again", button = true, on_press = function()
        tips.reset()
        require("speech").say("The first-time tips will play again as things come up.")
    end }
    return items
end

--- The welcome said the first time you're in the world.
function M.welcome()
    return "Welcome to the world. Wandsong describes it with sound as you play. " ..
           k("scan_next") .. " tells you what's around you, " .. k("autowalk") .. " walks you to your objective, " ..
           "and the arrow keys turn you. Press " .. k("guide") .. " any time for the full guide and every key."
end

return M
