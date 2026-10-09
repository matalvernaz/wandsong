-- The Sorting Hat's house screen (UI_BP_SortingHat_C) as a menu of the four houses. Oct 9: Matt
-- couldn't choose a different house. The screen comes up in a scene the UI manager doesn't
-- report, so the mod took it for play (the arrows turned the camera, Enter did nothing), and on
-- it another house is chosen only by clicking its crest: the screen listens to Confirm, Back
-- (Escape) and Accept (F) alone, nothing that moves between houses.
--
-- So the mod lists the houses, starting on the hat's suggestion (Matt: "a menu with the default
-- being what it suggests"); the arrows move, and Enter or the press key asks once, then
-- decides. Under it, the game's own way, found on the live screen (Oct 9): it opens on the hat's
-- (or the imported Wizarding World) house; Back shows all four crests; a crest's own select
-- handler (what clicking it runs) puts that house on show; Accept takes the house shown. The
-- mod always picks through the crests, then accepts only once the screen shows the very house
-- the player chose. While the screen is up the world layer stands down (world.lua: "sorting").
local dispatch, state, speech, keys = require("dispatch"), require("state"), require("speech"), require("keys")

local M = { title = "The Sorting" }
local function log(s) print("[Wandsong sorting] " .. s .. "\n") end

local CLASS = "UI_BP_SortingHat_C"
local OWNER = "UI_BP_SortingHat"              -- its bound events: BndEvt__UI_BP_SortingHat_<crest>_...
local ACCEPT, BACK = 75, 1                    -- EUMGInputAction: UMGHouseSelectSwitchMode (F), UMGBack
-- HouseStateIndex: the opening view (0, its house not trusted: the mod never accepts there), all
-- four crests (1), a picked house to accept (2). Back goes 0 to 1, 1 to 2, 2 to 1.
local OPENING, SHOWS_ALL, PICKED = 0, 1, 2
-- HouseIds, and the game's own words for each (read from the screen, Oct 9).
local HOUSES = {
    { id = 0, name = "Gryffindor", crest = "gryffindor", words = "known for daring, bravery, and chivalry" },
    { id = 1, name = "Hufflepuff", crest = "hufflepuff", words = "known for patience, loyalty and hard work" },
    { id = 2, name = "Ravenclaw", crest = "ravenclaw", words = "known for intelligence, creativity, and wit" },
    { id = 3, name = "Slytherin", crest = "slytherin", words = "known for cunning, ambition and a hunger for power" },
}
local STEP_MS = 800                           -- the screen's own transitions between steps
-- The screen takes no input while the hat talks (HatTalking): Accept sent during its remark on a
-- picked crest was dropped (Oct 9), and the mod had already said the house. So Accept waits for
-- the hat, up to TALK_WAIT, and the choice counts as made only once the screen has gone.
local TALK_WAIT, GONE_MS, ACCEPT_TRIES = 25, 2500, 3
local CONFIRM_FOR = 15                        -- seconds a first press waits for the second (its
                                              -- question alone takes 4 s to say: 6 was too short)

local suggested, ww = nil, nil                -- house ids: the hat's, the player's Wizarding World
local confirm_id, confirm_at = nil, -10
local busy_until = -1                        -- a choice is being carried out (its steps take 1.6 s)

--- The house screen, fresh: the widget at the path ReadMenu gave, still in the viewport.
local function screen()
    local path = state.sorting_path
    if not path then return nil end
    local w
    pcall(function() w = StaticFindObject(path) end)
    local ok = false
    pcall(function()
        ok = w:IsValid() and w:GetFullName():match("^%S+%s+(.+)$") == path and w:IsInViewport() == true
    end)
    return ok and w or nil
end

local function int(w, field)
    local v
    pcall(function() v = w[field] end)
    return math.type(v) == "integer" and v or nil
end

local function send(action)
    local mgr = FindFirstOf("UMGInputManager")
    if not (mgr and mgr:IsValid()) then log("no UMGInputManager"); return false end
    local ok, err = pcall(function() mgr:OnInputAction(action, 0) end)
    if not ok then log("action " .. action .. " failed: " .. tostring(err)); return false end
    dispatch.later(50, function()
        local fresh = FindFirstOf("UMGInputManager")
        pcall(function() if fresh and fresh:IsValid() then fresh:OnInputAction(action, 1) end end)
    end, "sorting key release", true)
    log("sent action " .. action)
    return true
end

--- Run a crest's own bound handler on the screen ("OnHouseHovered", "OnHouseSelected"): exactly
--- that crest's, by its full name, never another's.
local function crest_event(w, crest, kind)
    local prefix = "BndEvt__" .. OWNER .. "_" .. crest .. "_K2Node_ComponentBoundEvent_"
    local found
    pcall(function()
        w:GetClass():ForEachFunction(function(f)
            local n = f:GetFName():ToString()
            if n:sub(1, #prefix) == prefix and n:find(kind, #prefix + 1, true) then found = n end
        end)
    end)
    if not found then log("no " .. kind .. " handler for " .. crest); return false end
    local ok, err = pcall(function() w[found](w) end)
    log(kind .. " " .. crest .. ": " .. (ok and "ok" or tostring(err)))
    return ok
end

local function house_of(id)
    for _, h in ipairs(HOUSES) do if h.id == id then return h end end
end

local function fail(why)
    busy_until = -1
    log("not chosen: " .. why)
    speech.say("The hat didn't take that choice, so nothing was decided. Choose again.")
end

local function accept(h, tries, since)
    tries, since = tries or 0, since or os.clock()
    local w = screen()
    if not w then return fail("the screen closed") end
    if int(w, "HouseStateIndex") ~= PICKED or int(w, "NewHouse") ~= h.id then
        return fail("the screen shows house " .. tostring(int(w, "NewHouse")) .. ", state " .. tostring(int(w, "HouseStateIndex")))
    end
    local talking = false
    pcall(function() talking = w.HatTalking == true end)
    if talking and os.clock() - since < TALK_WAIT then
        dispatch.later(300, function() accept(h, tries, since) end, "sorting accept")
        return
    end
    if not send(ACCEPT) then return fail("Accept wasn't sent") end
    log("Accept sent for " .. h.name .. (tries > 0 and (", try " .. (tries + 1)) or ""))
    dispatch.later(GONE_MS, function()
        if screen() then
            if tries + 1 < ACCEPT_TRIES then accept(h, tries + 1, os.clock()) else fail("Accept wasn't taken") end
            return
        end
        busy_until = -1
        log("accepted " .. h.name)   -- the hat says it: nothing over its verdict
        if state.screen_open(M) and state.close_screen then state.close_screen() end
    end, "sorting accepted")
end

local function pick(h)
    local w = screen()
    if not w then return fail("the screen closed") end
    if int(w, "HouseStateIndex") ~= SHOWS_ALL then return fail("the crests aren't shown") end
    crest_event(w, h.crest, "OnHouseHovered")
    if not crest_event(w, h.crest, "OnHouseSelected") then return fail("no select handler") end
    dispatch.later(STEP_MS, function() accept(h) end, "sorting accept")
end

--- Carry out the choice: accept it if it's the house picked and shown, else show all the crests
--- (from the opening view or another pick) and pick it.
local function choose(h)
    local w = screen()
    if not w then speech.say("The Sorting Hat's screen has closed."); return end
    busy_until = os.clock() + TALK_WAIT + 15
    speech.say("Choosing " .. h.name .. ".")
    local st, shown = int(w, "HouseStateIndex"), int(w, "NewHouse")
    log(string.format("choose %s: state %s, shown %s", h.name, tostring(st), tostring(shown)))
    if st == PICKED and shown == h.id then accept(h); return end
    if st == SHOWS_ALL then pick(h); return end
    if (st ~= OPENING and st ~= PICKED) or not send(BACK) then return fail("unknown screen state " .. tostring(st)) end
    dispatch.later(STEP_MS, function() pick(h) end, "sorting pick")
end

local function press(h)
    if os.clock() < busy_until then return end
    if confirm_id ~= h.id or os.clock() - confirm_at > CONFIRM_FOR then
        confirm_id, confirm_at = h.id, os.clock()
        speech.say("Join " .. h.name .. "? Press " .. keys.describe_combo(keys.combo_of("press")) ..
                   " or enter again to choose it. The hat's choice is final.")
        return
    end
    confirm_id = nil
    choose(h)
end

function M.items()
    local items = {}
    for _, h in ipairs(HOUSES) do
        local notes = {}
        if h.id == suggested then notes[#notes + 1] = "the hat's suggestion" end
        if h.id == ww then notes[#notes + 1] = "your Wizarding World house" end
        items[#items + 1] = { id = "house " .. h.id, button = true,
            text = h.name .. ", " .. h.words .. (#notes > 0 and (", " .. table.concat(notes, ", ")) or ""),
            on_press = function() press(h) end }
    end
    return items
end
--- Where the menu starts: on the hat's suggestion.
function M.initial()
    for i, h in ipairs(HOUSES) do if h.id == suggested then return i end end
    return 1
end
M.intro = function()
    local s = house_of(suggested)
    return "Choose your house with the up and down arrows, then enter." ..
           (s and (" The hat suggests " .. s.name .. ".") or "")
end

--- menus.lua hands over the house screen when the game reads it (ReadMenu): the first time,
--- the menu opens; later reads (the screen changing between its views) say nothing more.
function M.noticed(path)
    local first = state.sorting_path ~= path
    state.sorting_path = path
    if not first and state.screen_open and state.screen_open(M) then return end
    local w = screen()
    if not w then return end
    suggested = int(w, "SuggestedHouse")
    ww = nil
    pcall(function()
        if w.HasWWHouse == true then
            local name = w.WWHouse:ToString()
            for _, h in ipairs(HOUSES) do if h.name:lower() == tostring(name):lower() then ww = h.id end end
        end
    end)
    busy_until, confirm_id = -1, nil
    log(string.format("house screen: suggested %s, Wizarding World %s", tostring(suggested), tostring(ww)))
    if state.open_screen then state.open_screen(M, "choose it") end
end

-- The screen gone (chosen, with the game's own keys too): the world gate forgets its path
-- (world.lua), and the menu goes with it.
dispatch.every(500, function()
    if state.sorting_path or not (state.screen_open and state.screen_open(M)) then return end
    log("house screen closed")
    busy_until, confirm_id = -1, nil
    if state.close_screen then state.close_screen() end
end, "sorting screen watch")

return M
