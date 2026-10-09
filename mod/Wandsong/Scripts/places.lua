-- Places: the game's own map markers, as a list (F11 in the world). First the Floo Flames you
-- can travel to, nearest first; then what the map marks near you (Merlin trials, hamlets,
-- vaults, dens, vendors, astronomy tables and the rest), with direction, distance and whether
-- it's done. Pressing a Floo Flame travels there with the game's own fast travel
-- (FastTravelManager:StartFastTravelUsingID, where its map's Travel ends up) after the same
-- checks; a second press confirms. Pressing anything else sets the game's own route to it (the
-- path-navigation manager's SetBeaconPathTarget, as choosing a marker on the map does), and
-- the objective beacon and autowalk follow that route.
--
-- Read afresh each time the list opens, from the map subsystem's own per-category lists:
-- property reads on its marker records, which live as long as the game. Nothing is kept.
-- Unverified in game: the route call, and which name field holds the words players see
-- (BeaconLocName may be a key; the game's translator, feedback.translate, turns keys into
-- words). The first names read are logged with their raw fields.

local speech = require("speech")
local state = require("state")
local world = require("world")
local keys = require("keys")

local M = { title = "Places" }

local function log(s) print("[Wandsong places] " .. s .. "\n") end

local TRAVEL_LISTS = { "OverlandFastTravelLocationList", "HogwartsFastTravelLocationList", "HogsmeadeFastTravelLocationList" }
local MARKER_LISTS = {
    "OverlandSphinxPuzzleLocationList", "OverlandTreasureVaultLocationList", "OverlandAstronomyLocationList",
    "OverlandDemiguiseLocationList", "HogwartsDemiguiseLocationList", "HogsmeadeDemiguiseLocationList",
    "OverlandAncientMagicLocationList", "OverlandHamletLocationList", "OverlandBanditCampLocationList",
    "OverlandBeastDenLocationList", "OverlandEnemyDenLocationList", "OverlandDungeonsLocationList",
    "OverlandTentsLocationList", "OverlandBothyLocationList", "OverlandCombatChallengesLocationList",
    "HogsmeadeLocationList", "OverlandBroomPlatformLocationList", "OverlandBroomRaceLocationList",
    "OverlandBroomBalloonLocationList", "OverlandRuinLocationList", "VendorsLocationList",
}
local MAX_MARKERS = 40
local MAX_MARKER_CM = 300000    -- 3 km

-- EBeaconType -> what it is.
local KIND = {
    [1] = "hamlet", [2] = "Hogwarts", [3] = "Hogsmeade", [10] = "dungeon", [12] = "bandit camp",
    [13] = "bandit camp", [14] = "bandit camp", [15] = "bandit camp", [16] = "tent", [17] = "treasure vault",
    [18] = "beast den", [19] = "spider den", [20] = "troll den", [23] = "named enemy", [30] = "Floo Flame",
    [31] = "Floo Flame", [34] = "Merlin trial", [40] = "ancient magic", [41] = "astronomy table",
    [42] = "Demiguise moon", [43] = "ruin", [44] = "bothy", [45] = "combat challenge", [46] = "treasure chest",
    [47] = "chest", [56] = "broom platform", [57] = "broom race ring", [61] = "vendor", [64] = "dugbog den",
    [65] = "inferi den", [66] = "wolf den", [70] = "broom race", [71] = "hedge maze", [72] = "balloons",
    [77] = "travelling vendor",
}
-- EBeaconState -> what a sighted player reads off the icon; nil says nothing.
local STATE_WORDS = { [3] = "not discovered", [5] = "not finished", [6] = "locked", [11] = "done",
                      [12] = "your level is too low", [14] = "closed" }
local HIDDEN = { [0] = true, [1] = true, [2] = true }   -- none, under the fog, undiscovered and hidden
local HIDE_FROM_MAP = 128                               -- EBeaconFlags
local FAST_TRAVEL_LOCKED, FAST_TRAVEL_UNLOCKED = 8, 9

local function live(o)
    local name = ""
    pcall(function() if o:IsValid() then name = o:GetFullName() end end)
    return name ~= "" and not name:find("Default__", 1, true)
end
local function find_live(cls)
    local found
    pcall(function()
        for _, o in ipairs(FindAllOf(cls) or {}) do if live(o) then found = o end end
    end)
    return found
end
local function travel_manager()
    local m
    pcall(function()
        local cdo = StaticFindObject("/Script/Phoenix.Default__FastTravelManager")
        if cdo and cdo:IsValid() then m = cdo:Get() end
    end)
    if m and live(m) then return m end
    return find_live("FastTravelManager")
end
-- A yes/no question to a long-lived manager: true, false, or nil when it can't answer.
local function ask(o, fn, ...)
    local args = table.pack(...)
    local ok, v = pcall(function() return o[fn](o, table.unpack(args, 1, args.n)) end)
    if ok and type(v) == "boolean" then return v end
    return nil
end

local function str(v)
    if type(v) == "string" then return v end
    local s
    pcall(function() s = v:ToString() end)
    return type(s) == "string" and s or nil
end
local function read(b)
    local r = {}
    pcall(function() r.type = b.BeaconType end)
    pcall(function() r.state = b.BeaconState end)
    pcall(function() r.flags = b.BeaconFlags end)
    pcall(function() r.handle = b.BeaconHandle end)
    pcall(function() r.id = str(b.FastTravelLocationID) end)
    pcall(function() r.name = str(b.BeaconName) end)
    pcall(function() r.loc_name = str(b.BeaconLocName) end)
    pcall(function() local v = b.BeaconWorldPosition; r.x, r.y, r.z = v.X, v.Y, v.Z end)
    if type(r.x) ~= "number" or type(r.y) ~= "number" then return nil end
    return r
end

local function humanize(s)
    s = s:gsub("^FT_", ""):gsub("_", " "):gsub("(%l)(%u)", "%1 %2"):gsub("%s+", " ")
    return s:match("^%s*(.-)%s*$")
end
local names_logged = 0
local function display_name(r)
    local name
    local translate = require("feedback").translate
    for _, key in ipairs({ r.loc_name, r.name }) do
        if not name and key and key ~= "" and key ~= "None" then
            local t = translate(key)
            if t and t ~= key then name = t elseif key:find("%s") then name = key end
        end
    end
    if not name then
        local raw = (r.name and r.name ~= "" and r.name) or r.loc_name
        name = raw and raw ~= "" and humanize(raw) or KIND[r.type] or "A place"
    end
    if names_logged < 20 then
        names_logged = names_logged + 1
        log(string.format("name %q from loc name %q, name %q, id %q, type %s, state %s", name, tostring(r.loc_name),
            tostring(r.name), tostring(r.id), tostring(r.type), tostring(r.state)))
    end
    return name
end

local function where(px, py, yaw, x, y)
    local m = math.sqrt((x - px) ^ 2 + (y - py) ^ 2) / 100
    local dist = m < 1000 and (math.floor(m + 0.5) .. " metres") or string.format("%.1f kilometres", m / 1000)
    return state.where(px, py, yaw, x, y):match("^[^,]+") .. ", " .. dist
end

local function collect(sub, lists, keep)
    local out, seen = {}, {}
    for _, prop in ipairs(lists) do
        pcall(function()
            sub[prop]:ForEach(function(_, e)
                local r
                pcall(function() r = read(e:get()) end)
                local id = r and (r.handle or (r.x .. " " .. r.y))
                if r and not seen[id] and keep(r) then
                    seen[id] = true
                    out[#out + 1] = r
                end
            end)
        end)
    end
    return out
end

local function key(id) return keys.describe_combo(keys.combo_of(id)) end

-- --- Travel and routes --------------------------------------------------------------------
-- Why the game wouldn't take a journey there now, or nil. Each answer must be the expected one.
local function travel_blocker(ftm, id)
    if not ftm then return "Fast travel isn't available right now." end
    if ask(ftm, "IsFastTravelling") ~= false then return "Fast travel isn't available right now." end
    if ask(ftm, "IsFastTravelDisabled") ~= false or ask(ftm, "IsFastTravelAvailable") ~= true then
        return "The game doesn't allow fast travel right now."
    end
    if ask(ftm, "IsFastTravelUnlockedForLocation", id) ~= true then return "That Floo Flame isn't unlocked yet." end
    if ask(ftm, "IsFastTravelAvailableForLocation", id) ~= true then return "You can't travel there right now." end
    return nil
end

local confirm_id, confirm_at = nil, -10
--- Travel to a Floo Flame by its location id; the first press asks, the second goes.
function M.travel(id, name)
    if confirm_id ~= id or os.clock() - confirm_at > 6 then
        confirm_id, confirm_at = id, os.clock()
        speech.say("Travel to " .. name .. "? Press " .. key("press") .. " again to go.")
        return
    end
    confirm_id = nil
    if not world.in_game() then speech.say(world.not_ready_reason()); return end
    local ftm = travel_manager()
    local why = travel_blocker(ftm, id)
    if why then speech.say(why); return end
    -- FromType 1 is the map; travel type 0 the plain journey.
    local ok, err = pcall(function() ftm:StartFastTravelUsingID(id, 1, 0) end)
    if not ok then
        log("StartFastTravelUsingID " .. id .. " failed: " .. tostring(err))
        speech.say("The game didn't start the journey.")
        return
    end
    log("fast travel to " .. id)
    if state.close_screen then state.close_screen() end
    state.mark_loading(10)
    speech.say("Travelling to " .. name .. ".")
end

local route_set = false
--- Set the game's own route to a map marker (by its beacon handle).
function M.route(handle, name)
    local mgr = require("path").manager()
    if not mgr or type(handle) ~= "number" then speech.say("The game's route isn't available right now."); return end
    local ok, err = pcall(function() mgr:SetBeaconPathTarget(handle, false, name) end)
    if not ok then
        log("SetBeaconPathTarget " .. tostring(handle) .. " failed: " .. tostring(err))
        speech.say("The game didn't take that route.")
        return
    end
    route_set = true
    log("route to beacon " .. tostring(handle) .. " (" .. name .. ")")
    if state.close_screen then state.close_screen() end
    speech.say("Route set to " .. name .. ". " .. key("autowalk") .. " walks you there, and the beacon follows it.")
end

function M.clear_route()
    local mgr = require("path").manager()
    local ok = mgr ~= nil and pcall(function() mgr:ClearPathTarget() end)
    route_set = false
    speech.say(ok and "Route cleared." or "The game's route isn't available right now.")
end

-- --- The list ---------------------------------------------------------------------------------
function M.items()
    local items = {}
    if not world.in_game() then items[1] = { text = world.not_ready_reason() }; return items end
    local sub = find_live("MapSubSystem")
    if not sub then items[1] = { text = "The game's map isn't available right now." }; return items end
    local px, py, _, yaw = world.position()
    local function dist(r) return (r.x - px) ^ 2 + (r.y - py) ^ 2 end
    local function nearest_first(a, b) return dist(a) < dist(b) end

    local ftm = travel_manager()
    local floos = collect(sub, TRAVEL_LISTS, function(r)
        if not r.id or r.id == "" or r.state == FAST_TRAVEL_LOCKED then return false end
        if r.state == FAST_TRAVEL_UNLOCKED then return true end
        return ftm ~= nil and ask(ftm, "IsFastTravelUnlockedForLocation", r.id) == true
    end)
    table.sort(floos, nearest_first)
    -- Each entry has an id: the list is sorted by distance afresh at every refresh, and the
    -- review keys and Press follow the entry, not its place in the list.
    items[#items + 1] = { id = "floo flames", text = #floos > 0 and ("Floo Flames you can travel to, nearest first: " .. #floos)
                                                                 or "No Floo Flames unlocked yet." }
    for _, r in ipairs(floos) do
        local name = display_name(r)
        items[#items + 1] = { id = "floo " .. r.id, text = name .. ", " .. where(px, py, yaw, r.x, r.y), button = true,
                              on_press = function() M.travel(r.id, name) end }
    end

    local marks = collect(sub, MARKER_LISTS, function(r)
        return not HIDDEN[r.state] and ((r.flags or 0) & HIDE_FROM_MAP) == 0 and dist(r) <= MAX_MARKER_CM ^ 2
    end)
    table.sort(marks, nearest_first)
    items[#items + 1] = { id = "map markers", text = #marks > 0 and "On the map near you, nearest first" or "Nothing else on the map within 3 kilometres." }
    for i = 1, math.min(#marks, MAX_MARKERS) do
        local r = marks[i]
        local name = display_name(r)
        local kind = KIND[r.type]
        local text = name .. ((kind and kind:lower() ~= name:lower()) and (", " .. kind) or "") ..
                     (STATE_WORDS[r.state] and (", " .. STATE_WORDS[r.state]) or "") .. ", " .. where(px, py, yaw, r.x, r.y)
        items[#items + 1] = { id = "marker " .. tostring(r.handle or (r.x .. " " .. r.y)), text = text, button = true,
                              on_press = function() M.route(r.handle, name) end }
    end
    if route_set then
        items[#items + 1] = { id = "clear route", text = "Clear the route you set", button = true, on_press = M.clear_route }
    end
    return items
end

keys.action{
    id = "places", name = "Places on the map, and Floo Flames to travel to", group = "In the world", default = "f11",
    run = function()
        if not world.in_game() then speech.say(world.not_ready_reason()); return end
        if state.open_screen then state.open_screen(M, "travel there or set a route to it") end
    end,
}

return M
