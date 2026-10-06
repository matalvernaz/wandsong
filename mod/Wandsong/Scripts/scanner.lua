-- Scanner: what's around me, by name, nearest first.
--
--   Page Down / Page Up      next / previous thing ("Professor Fig, 4 metres, ahead left, 1 of 6")
--   Home                     the current thing again, freshly, and turn to face it
--   Shift+Page Down / Up     next / previous category, empty ones skipped (everything, quest
--                            objective, people, enemies, ...)
--   Shift+Home               walk to the current thing (autowalk)
--   Shift+F9                 developer: write everything tracked to scan_dump.txt
-- Keys and categories follow the reference access mod's scanner.
--
-- It reads the world layer's background scan (one class per tick, nothing extra), so a key
-- press costs only a fresh position read per entry. Entries are kept by object path, never
-- by object, and every position is looked up again when it's spoken. The keys only act in
-- the world; in menus, scenes and loads they stay silent.

local dispatch = require("dispatch")
local world = require("world")
local state = require("state")
local keys = require("keys")
local speech = require("speech")
local diag = require("diag")

local M = {}

local function log(s) print("[Wandsong scanner] " .. s .. "\n") end

local CATEGORIES = {
    { kind = nil, name = "Everything" },
    -- Its own category, as in other access mods, so the objective doesn't crowd the list.
    { kind = "objective", name = "Quest objective" },
    { kind = "person", name = "People" },
    { kind = "enemy", name = "Enemies" },
    { kind = "beast", name = "Creatures" },
    { kind = "chest", name = "Chests" },
    { kind = "collect", name = "Collectibles" },
    { kind = "door", name = "Doors" },
    { kind = "usable", name = "Things to use" },
}
local REBUILD_AFTER = 3          -- seconds
local REBUILD_MOVED_CM = 500
local SAME_FLOOR_CM = 300        -- height difference still counted as the same floor
local RANGE_CM = 4000

local cat_i = 1
local list = {}                  -- { path, name, kind, x, y, z, d }
local built_at, built_x, built_y = -100, 0, 0
local selected = nil             -- path of the selected entry

local function metres(cm) return math.floor(cm / 100 + 0.5) end

local function build()
    local px, py, pz = world.position()
    local kind = CATEGORIES[cat_i].kind
    local out = {}
    if kind == "objective" then
        local o = require("path").objective()
        if o then
            out[1] = { path = "objective", name = o.name, kind = "objective", x = o.x, y = o.y, z = o.z,
                       point = true, floor = true,
                       d = math.sqrt((o.x - px) ^ 2 + (o.y - py) ^ 2 + (o.z - pz) ^ 2) }
        end
        list, built_at, built_x, built_y = out, os.clock(), px, py
        return
    end
    for _, e in ipairs(world.entries()) do
        if not kind or e.kind == kind then
            local p = world.locate(e.path)
            if p then
                local d = math.sqrt((p[1] - px) ^ 2 + (p[2] - py) ^ 2 + (p[3] - pz) ^ 2)
                if d <= RANGE_CM then
                    out[#out + 1] = { path = e.path, name = e.name, kind = e.kind, x = p[1], y = p[2], z = p[3], d = d,
                                      floor = math.abs(p[3] - pz) <= SAME_FLOOR_CM }
                end
            end
        end
    end
    -- Nearest first, with things on your own floor before things above or below.
    table.sort(out, function(a, b)
        if a.floor ~= b.floor then return a.floor end
        return a.d < b.d
    end)
    list, built_at, built_x, built_y = out, os.clock(), px, py
end

local function stale()
    local px, py = world.position()
    local age = os.clock() - built_at
    return age < 0 or age > REBUILD_AFTER or math.sqrt((px - built_x) ^ 2 + (py - built_y) ^ 2) > REBUILD_MOVED_CM
end

local function index_of(path)
    for i, e in ipairs(list) do if e.path == path then return i end end
    return nil
end

-- "Professor Fig, 4 metres, ahead left, 2 of 9", position read fresh. Returns false if the
-- thing has gone.
local function describe(i)
    local e = list[i]
    local p = e.point and { e.x, e.y, e.z } or world.locate(e.path)
    if not p then return false end
    local px, py, pz, yaw = world.position()
    local d = math.sqrt((p[1] - px) ^ 2 + (p[2] - py) ^ 2 + (p[3] - pz) ^ 2)
    local where = state.where(px, py, yaw, p[1], p[2]):gsub(",.*$", "")
    local dz = p[3] - pz
    local floor = dz > SAME_FLOOR_CM and ", above" or (dz < -SAME_FLOOR_CM and ", below" or "")
    local m = metres(d)
    local text = string.format("%s, %s, %s%s, %d of %d", e.name, m <= 1 and "close" or (m .. " metres"),
                               where, floor, i, #list)
    speech.say(text)
    log("say " .. e.path .. ": " .. text)
    return true
end

local function ready()
    if not world.in_game() then return false end
    return true
end

local function step(dir)
    if not ready() then return end
    if stale() then build() end
    if #list == 0 then
        speech.say(CATEGORIES[cat_i].kind and ("No " .. CATEGORIES[cat_i].name:lower() .. " nearby") or "Nothing nearby")
        return
    end
    local i = selected and index_of(selected)
    if not i then i = dir > 0 and 0 or 1 end
    for _ = 1, #list do
        i = (i - 1 + dir) % #list + 1
        selected = list[i].path
        if describe(i) then return end
        log("gone: " .. list[i].path)
    end
    speech.say("Everything that was here has gone")
    build()
end

local function current()
    if not ready() then return end
    local i = selected and index_of(selected)
    if not i then
        build()
        i = selected and index_of(selected)
    end
    if not i then step(1) return end
    if not describe(i) then speech.say(list[i].name .. " has gone"); selected = nil; return end
    -- As in other access mods, Home also turns you to face it.
    local e = list[i]
    if e.point then require("path").face_point(e.x, e.y, e.name)
    else require("path").face_to(e.path, e.name, true) end
end

local function category(dir)
    if not ready() then return end
    -- Empty categories are skipped (everything is always offered).
    for _ = 1, #CATEGORIES do
        cat_i = (cat_i - 1 + dir) % #CATEGORIES + 1
        selected = nil
        build()
        if #list > 0 or cat_i == 1 then break end
    end
    local c = CATEGORIES[cat_i]
    speech.say(c.name .. ", " .. (#list == 0 and "none nearby" or (#list .. " nearby")))
    if #list > 0 then
        selected = list[1].path
        dispatch.later(50, function() describe(1) end, "scanner first")
    end
end

local function with_selected(fn)
    if not ready() then return end
    local i = selected and index_of(selected)
    if not i then speech.say("Nothing selected. Use page down to pick something first.") return end
    fn(list[i])
end

keys.action{ id = "scan_next", name = "Next thing around you", group = "Scanner", default = "pagedown",
             run = function() step(1) end }
keys.action{ id = "scan_prev", name = "Previous thing around you", group = "Scanner", default = "pageup",
             run = function() step(-1) end }
keys.action{ id = "scan_repeat", name = "Current thing again, and turn to face it", group = "Scanner",
             default = "home", run = current }
keys.action{ id = "scan_cat_next", name = "Next scanner category", group = "Scanner", default = "shift+pagedown",
             run = function() category(1) end }
keys.action{ id = "scan_cat_prev", name = "Previous scanner category", group = "Scanner", default = "shift+pageup",
             run = function() category(-1) end }
keys.action{ id = "scan_walk", name = "Walk to the current thing", group = "Scanner", default = "shift+home",
             run = function() with_selected(function(e)
                 if e.point then require("path").walk_objective() else require("path").walk_to(e.path, e.name) end
             end) end }

-- Developer: everything the world scan is tracking, with name sources and positions.
local DUMP = (function()
    local src = debug.getinfo(1, "S").source or ""
    local dir = src:gsub("^@", ""):gsub("/", "\\"):match("^(.*)\\[^\\]+$") or "."
    return dir .. "\\..\\scan_dump.txt"
end)()
keys.action{ id = "scan_dump", name = "Developer: write what the scanner sees to a file", group = "Scanner",
             default = "shift+f9", run = function()
    if not ready() then speech.say(world.not_ready_reason()) return end
    local px, py, pz, yaw = world.position()
    local f = io.open(DUMP, "a")
    if not f then speech.say("Couldn't write the scan dump") return end
    local entries = world.entries()
    f:write(string.format("== %s, player at %.0f %.0f %.0f facing %.0f, %d tracked\n",
        os.date("%H:%M:%S"), px, py, pz, yaw, #entries))
    for _, e in ipairs(entries) do
        local p = world.locate(e.path)
        f:write(string.format("%s | %s | from %s | %s | %s\n", e.kind, e.name, tostring(e.name_src),
            p and string.format("%.1f m, at %.0f %.0f %.0f", math.sqrt((p[1] - px) ^ 2 + (p[2] - py) ^ 2 + (p[3] - pz) ^ 2) / 100,
                                p[1], p[2], p[3]) or "gone",
            e.path))
    end
    f:close()
    speech.say("Wrote " .. #entries .. " things to the scan dump")
end }

log("loaded")
return M
