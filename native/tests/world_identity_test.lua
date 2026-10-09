-- Audit A15: between scan passes a new actor can take the address of one the game destroyed.
-- Without the deletion record nothing says so, and the old snapshot (its path, name and extra
-- data) must not carry over to the newcomer: the fresh object's own path decides.
local t = dofile("native/tests/testlib.lua")
local objects = {}
local function obj(cls, path, props)
    props.IsValid = function() return true end
    props.GetFullName = function() return cls .. " " .. path end
    props.GetAddress = function() return path end
    props.GetClass = function() return { GetFName = function() return { ToString = function() return cls end } end } end
    props.IsA = function() return false end
    objects[path] = props
    return props
end
local ui = obj("UIManager", "/Game/UI", { IsInPreGameplayState = function() return false end,
    IsAsyncScreenLoadInProgress = function() return false end, GetInMenuTransition = function() return false end,
    InPauseMode = function() return false end })
local pawn = obj("Biped_Player", "/Game/Player", { InCinematic = false,
    RootComponent = { RelativeLocation = { X = 0, Y = 0, Z = 0 } }, Controller = { ControlRotation = { Yaw = 0 } } })
local function person(path, x, id)
    local a = obj("BP_Student_C", path, { RootComponent = { RelativeLocation = { X = x, Y = 0, Z = 0 } },
        GetCharacterID = function() return { ToString = function() return id end } end })
    a.GetAddress = function() return 1234 end   -- the same memory, one after the other
    return a
end
local current = person("/Game/OldPerson", 100, "OldStudent")
FindFirstOf = function(cls) if cls == "UIManager" then return ui elseif cls == "Biped_Player" then return pawn end end
FindAllOf = function(cls) return cls == "NPC_Character" and { current } or {} end
StaticFindObject = function(path) return objects[path] end
package.loaded.tips = { once = function() end }
package.loaded.guide = { welcome = function() return "Welcome" end }
require("speech").say = function() end
local world = require("world")
world.on_scan("Student", function(_, e) e.extra.seen_as = e.extra.seen_as or e.path end)
t.run(8)
local old = world.entry("/Game/OldPerson")
assert(old and old.x == 100, "the first student is tracked")
objects["/Game/OldPerson"] = nil
current = person("/Game/NewPerson", 900, "NewStudent")
t.run(3)
assert(world.locate("/Game/OldPerson") == nil, "the old student is gone, not moved")
local new = world.entry("/Game/NewPerson")
assert(new and new.x == 900, "the newcomer is tracked under its own path")
assert(new.extra.seen_as == "/Game/NewPerson", "and none of the old one's extra data carries over")
local n = 0
for _, e in ipairs(world.entries()) do if e.kind == "person" then n = n + 1 end end
assert(n == 1, "one person, not two: " .. n)
-- The same actor seen again keeps its snapshot (no churn on every pass).
local extra = world.entry("/Game/NewPerson").extra
t.run(3)
assert(world.entry("/Game/NewPerson").extra == extra, "the same actor keeps its snapshot")
print("world identity test passed")
