-- Holding (lifetime_enabled.txt): the objects passes find are kept, and the nearest are read
-- again between passes, each only after the deletion record (the real lifetime_bridge.dll,
-- with only start() stood in for) says the game hasn't deleted it. A deleted object is dropped
-- without being touched at all.
local t = dofile("native/tests/testlib.lua")
if package.config:sub(1, 1) ~= "\\" then print("world hold test skipped (Windows only)"); return end
local record = require("lifetime_bridge")
local started = 0
package.loaded.lifetime_bridge = setmetatable({ start = function() started = started + 1; return true, "test listener" end },
    { __index = record })
local flag = assert(io.open(require("files").runtime("lifetime_enabled.txt"), "w")); flag:write("on\n"); flag:close()

local objects = {}
local function obj(cls, path, props)
    props.IsValid = function() return true end
    props.GetFullName = function() return cls .. " " .. path end
    props.GetAddress = function() return path end
    objects[path] = props
    return props
end
local ui = obj("UIManager", "/Game/UI", { IsInPreGameplayState = function() return false end,
    IsAsyncScreenLoadInProgress = function() return false end, GetInMenuTransition = function() return false end,
    InPauseMode = function() return false end })
local pawn = obj("Biped_Player", "/Game/Player", { InCinematic = false, RootComponent = { RelativeLocation = { X = 0, Y = 0, Z = 0 } },
    Controller = { ControlRotation = { Yaw = 0 } } })
FindFirstOf = function(cls) if cls == "UIManager" then return ui elseif cls == "Biped_Player" then return pawn end end
local classes = {}
StaticFindObject = function(p)
    local c = p:match("^/Script/Phoenix%.(.+)$")
    if c then classes[c] = classes[c] or { IsValid = function() return true end, name = c }; return classes[c] end
    return objects[p]
end

-- World actors: every read of a deleted one is recorded.
local touched_dead = {}
local next_address = 0x7ff600000000
local function actor(cls, path, x, isa)
    next_address = next_address + 0x400
    local data = { address = next_address, dead = false, isa = isa or {},
                   RootComponent = { RelativeLocation = { X = x, Y = 0, Z = 0 } } }
    local methods = {
        IsValid = function() return true end,
        GetFullName = function() return cls .. " " .. path end,
        GetAddress = function() return data.address end,
        GetClass = function() return { GetFName = function() return { ToString = function() return cls end } end } end,
        IsA = function(_, c) return data.isa[c.name] == true end,
    }
    local a = setmetatable({}, { __index = function(_, k)
        if data.dead then touched_dead[#touched_dead + 1] = path .. ":" .. tostring(k) end
        if methods[k] then return methods[k] end
        if k == "RootComponent" then return data.RootComponent end
    end })
    return a, data
end

local chars, queries = {}, 0
FindAllOf = function(cls)
    if cls == "NPC_Character" then queries = queries + 1; return chars end
    return {}
end
package.loaded.audio_bridge = { init = function() return true end, play_ui = function() end, play = function() end,
    listener = function() end, stop_all = function() end }
package.loaded.tips = { once = function() end }
package.loaded.guide = { welcome = function() return "Welcome" end }
require("speech").say = function() end
local world = require("world")

local function until_pass()
    local q = queries
    for _ = 1, 300 do t.run(0.02); if queries > q then return end end
    error("no character pass for 6 s")
end

t.run(7)
assert(world.in_game() and started == 1, "the listener starts once, on the game thread")

-- A student is found by a pass, then read again between passes.
local student, sd = actor("BP_Student_C", "/Game/Hall.Student", 600)
chars = { student }
local reads = 0
world.on_scan("BP_Student", function(_, e) reads = reads + 1; e.extra.reads = reads end)
until_pass(); t.run(0.1)
assert(world.locate("/Game/Hall.Student")[1] == 600, "found by the pass")
until_pass()
local q, r = queries, reads
sd.RootComponent.RelativeLocation.X = 800
t.run(0.3)
assert(queries == q, "no pass in between")
assert(world.locate("/Game/Hall.Student")[1] == 800, "held: read again between passes")
assert(reads > r, "readers run again with each refresh")

-- Calm (nobody hostile about): the character pass runs about every 3 s, not every 1.2 s.
q = queries
t.run(7.2)
assert(queries - q >= 2 and queries - q <= 3, "calm: fewer character passes, got " .. (queries - q))
-- Walking 5 m brings the next pass forward.
until_pass()
q = queries
pawn.RootComponent.RelativeLocation.X = 600
t.run(1.6)
assert(queries > q, "a pass at the next turn after walking 5 m")

-- An enemy turns up: passes every 1.2 s again.
local bandit, bd = actor("BP_Bandit_C", "/Game/Hall.Bandit", 1200, { Enemy_Character = true })
chars = { student, bandit }
t.run(3.7)
local entries = world.entries()
local found
for _, e in ipairs(entries) do if e.path == "/Game/Hall.Bandit" then found = e end end
assert(found and found.kind == "enemy", "the bandit is an enemy")
q = queries
t.run(6)
assert(queries - q >= 4, "enemies about: a pass every 1.2 s, got " .. (queries - q))

-- The game deletes the bandit right after a pass: the record drops it at the next refresh,
-- before any pass, and nothing reads it again.
until_pass()
record.test_notify(bd.address)
bd.dead = true
chars = { student }
t.run(0.25)
assert(world.locate("/Game/Hall.Bandit") == nil, "deleted: dropped by the record within a refresh")
assert(world.lifetime_report():find("dropped as deleted 1", 1, true), world.lifetime_report())
t.run(3)
assert(#touched_dead == 0, "a deleted object is never touched: " .. table.concat(touched_dead, ", "))

-- The game reuses the address for someone new: a new thing, held and read like any other.
local ghost, gd = actor("BP_Ghost_C", "/Game/Hall.Ghost", 900)
gd.address = bd.address
chars = { student, ghost }
until_pass(); t.run(0.1)
assert(world.locate("/Game/Hall.Ghost")[1] == 900 and world.locate("/Game/Hall.Bandit") == nil, "the new object at the old address")
gd.RootComponent.RelativeLocation.X = 950
t.run(0.3)
assert(world.locate("/Game/Hall.Ghost")[1] == 950, "and it's held")
assert(#touched_dead == 0, "still nothing dead touched: " .. table.concat(touched_dead, ", "))

-- A load forgets everything held.
require("state").mark_loading(1)
t.run(0.5)
assert(record.stats().watched == 0, "a load clears the record's watches")
assert(#world.entries() == 0, "and the world's snapshots")
print("world hold test passed")
