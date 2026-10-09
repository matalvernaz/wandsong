-- The game's own quest markers: what a sighted player sees floating over the people and places the
-- current quest step wants. They're the beacon manager's HUD beacons of the active-mission type.
-- In the Ravenclaw common room (Oct 8) "Introduce yourself to Samantha, Everett and Amit" put one
-- over each of the three and gave no route; the scanner called all eight students "Student" and
-- Matt couldn't tell whom to talk to. Now the marked ones fill the scanner's quest category, say
-- "quest marker" wherever they're listed, and autowalk goes to the nearest when the game gives no
-- route (path.lua). Snapshots only: positions copied out each pass, no game object kept.
local world, dispatch = require("world"), require("dispatch")

local M = {}
local function log(s) print("[Wandsong markers] " .. s .. "\n") end

local ACTIVE_MISSION = 7                  -- EBeaconType BEACONTYPE_ACTIVEMISSION
local MATCH_CM, MATCH_DZ_CM = 200, 250    -- a marker floats over its character's head
local manager_path, next_search = nil, 0
local markers = {}                        -- { x, y, z, path, name, kind } (path: the marked thing)
local marked = {}                         -- path -> true
local last_count = 0

-- The beacon manager (long-lived), by its path, checked to still be the object the path names;
-- searched for again at most every 10 s.
local function manager()
    local m
    if manager_path then
        pcall(function() m = StaticFindObject(manager_path) end)
        local ok, same = pcall(function() return m:IsValid() and m:GetFullName():find(manager_path, 1, true) ~= nil end)
        if ok and same then return m end
    end
    if os.clock() < next_search then return nil end
    next_search = os.clock() + 10
    m = nil
    pcall(function()
        for _, o in ipairs(FindAllOf("BeaconManager") or {}) do
            local n = o:GetFullName()
            if not n:find("Default__", 1, true) then m = o; manager_path = n:match("^%S+%s+(.+)$") end
        end
    end)
    return m
end

--- The active quest step's markers now shown: { { x, y, z } }.
local function read()
    local out = {}
    local m = manager()
    if not m then return out end
    pcall(function()
        m.HudBeaconObjects:ForEach(function(_, e)
            local b = e:get()
            local t, active, hidden
            pcall(function() t = b.BeaconType end)
            if t ~= ACTIVE_MISSION then return end
            pcall(function() active = b.bIsBeaconActive end)
            pcall(function() hidden = b.bHudIconSuppressed end)
            if active == false or hidden == true then return end
            pcall(function()
                local p = b.BeaconWorldPosition
                out[#out + 1] = { x = p.X, y = p.Y, z = p.Z }
            end)
        end)
    end)
    return out
end

-- Each marker belongs to the thing right under it, a character before anything else.
local function match(list)
    local entries = world.entries and world.entries() or {}
    local now = {}
    for _, mk in ipairs(list) do
        local best, best_d, best_person
        for _, e in ipairs(entries) do
            if e.x and e.y then
                local d = math.sqrt((e.x - mk.x) ^ 2 + (e.y - mk.y) ^ 2)
                local person = e.kind == "person" or e.kind == "enemy" or e.kind == "beast"
                if d <= MATCH_CM and math.abs((e.z or mk.z) - mk.z) <= MATCH_DZ_CM
                   and (not best or (person and not best_person) or (person == best_person and d < best_d)) then
                    best, best_d, best_person = e, d, person
                end
            end
        end
        if best then
            mk.path, mk.name, mk.kind = best.path, best.name, best.kind
            now[best.path] = true
        end
    end
    marked = now
end

dispatch.every(1000, function()
    if not world.in_game() then markers, marked = {}, {}; return end
    local list = read()
    match(list)
    markers = list
    if #list ~= last_count then
        last_count = #list
        local names = {}
        for _, mk in ipairs(list) do names[#names + 1] = mk.name or string.format("%.0f %.0f %.0f", mk.x, mk.y, mk.z) end
        log(#list .. " quest markers" .. (#names > 0 and (": " .. table.concat(names, ", ")) or ""))
    end
end, "quest markers")

--- The markers now shown, each { x, y, z, path, name, kind } (path, name, kind when on a thing).
function M.list() return markers end
--- True when the quest marks this world entry.
function M.marked(path) return path ~= nil and marked[path] == true end
--- The nearest marker, with the marked thing's fresh position when it has one: { x, y, z, path, name }.
function M.nearest()
    local px, py, pz = world.position()
    if not px then return nil end
    local best, best_d
    for _, mk in ipairs(markers) do
        local x, y, z = mk.x, mk.y, mk.z
        if mk.path and world.locate then
            local p = world.locate(mk.path)
            if p then x, y, z = p[1], p[2], p[3] end
        end
        local d = math.sqrt((x - px) ^ 2 + (y - py) ^ 2 + ((z - pz) * 2) ^ 2)   -- other floors count double
        if not best_d or d < best_d then best, best_d = { x = x, y = y, z = z, path = mk.path, name = mk.name }, d end
    end
    return best
end
-- Tests: forget the cached manager.
function M.reset() manager_path, next_search, markers, marked, last_count = nil, 0, {}, {}, 0 end

return M
