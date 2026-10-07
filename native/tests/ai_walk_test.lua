-- The AI walk: off unless switched on; when on, every way out hands the character back to the
-- player's controller in a fixed order.
local t = dofile("native/tests/testlib.lua")
local calls, said = {}, {}
local px, py, pz, in_game = 0, 0, 100, true
local objects = {}
local function obj(cls, path, props)
    props = props or {}
    props.IsValid = function() return true end
    props.GetFullName = function() return cls .. " " .. path end
    objects[path] = props
    return props
end
local function log_call(name) calls[#calls + 1] = name end
local pc = obj("BP_PhoenixPlayerController_C", "/Game/PC")
local pawn = obj("BP_Biped_Player_C", "/Game/Player", {
    Controller = pc,
    CharacterMovement = { MaxWalkSpeed = 600, StopMovementImmediately = function() log_call("stop character") end },
    RootComponent = { CapsuleRadius = 30, CapsuleHalfHeight = 90,
        SetCapsuleSize = function() log_call("restore capsule") end },
})
pc.Possess = function(_, p) log_call("player possesses"); p.Controller = pc end
local move_status, move_result = 3, 2
local ai = obj("AIController", "/Game/AI_1", {
    Possess = function(self, p) log_call("ai possesses"); p.Controller = self end,
    MoveToLocation = function() log_call("move"); return move_result end,
    GetMoveStatus = function() return move_status end,
    StopMovement = function() log_call("ai stop") end,
    UnPossess = function() log_call("unpossess") end,
    K2_DestroyActor = function() log_call("destroy ai") end,
})
local statics = obj("GameplayStatics", "/Script/Engine.Default__GameplayStatics", {
    BeginDeferredActorSpawnFromClass = function() log_call("spawn"); return ai end,
    FinishSpawningActor = function(_, a) return a end,
})
obj("Class", "/Script/AIModule.AIController")
StaticFindObject = function(p) return objects[p] end
package.loaded.world = { in_game = function() return in_game end, position = function() return px, py, pz, 0 end,
    pawn = function() return pawn end }
require("speech").say = function(s) said[#said + 1] = s end
local walk = require("ai_walk")
local function order() return table.concat(calls, ", ") end

-- Off: never starts.
assert(not walk.enabled() and not walk.start({ 1000, 0, 100 }, "the door"), "off unless switched on")
assert(#calls == 0, "nothing spawned while off")

-- The probe works while off (it's how the walk gets checked) and hands control back.
local report = walk.probe()
assert(report:find("spawn: ok", 1, true) and report:find("possess: ok", 1, true) and report:find("hand back: ok", 1, true),
    "probe: " .. report)
assert(pawn.Controller == pc, "the probe gives the character back")
assert(order() == "spawn, ai possesses, stop character, ai stop, unpossess, player possesses, destroy ai",
    "the probe hands back in order: " .. order())

-- Switched on: walks, and on arrival hands back in order.
local flag = assert(io.open(require("files").runtime("ai_walk_enabled.txt"), "w")); flag:write("on\n"); flag:close()
calls = {}
assert(walk.enabled() and walk.start({ 1000, 0, 100 }, "the door"), "starts when switched on")
assert(walk.active() and pawn.Controller == ai and said[#said]:find("pathfinding", 1, true), "the AI controller walks")
t.run(1)
assert(walk.active(), "still walking while it moves")
px = 500; t.run(1)
px = 950; t.run(0.5)
assert(not walk.active() and pawn.Controller == pc, "arrived: control is back")
assert(said[#said] == "Arrived at the door.", "arrival is said")
assert(order() == "spawn, ai possesses, move, stop character, ai stop, unpossess, player possesses, destroy ai",
    "hand-back order on arrival: " .. order())

-- A movement key takes control back at once.
calls, px = {}, 0
assert(walk.start({ 1000, 0, 100 }, "the door"))
t.run(0.6)
walk.stop("you moved"); t.run(0.2)
assert(not walk.active() and pawn.Controller == pc, "stopping hands the character back")

-- No progress: stops and says how far it got.
calls, px = {}, 0
assert(walk.start({ 3000, 0, 100 }, "the door"))
t.run(5)
assert(not walk.active() and said[#said]:find("got stuck too", 1, true), "no progress: stuck, said")
assert(pawn.Controller == pc, "stuck: control is back")

-- The game's path ends short.
calls, px, move_status = {}, 0, 0
assert(walk.start({ 3000, 0, 100 }, "the door"))
px = 300; t.run(2)
assert(not walk.active() and said[#said]:find("stopped 27 metres", 1, true), "path ended short: " .. said[#said])
move_status = 3

-- A scene starting ends it with the hand-back; a load just forgets it.
calls, px = {}, 0
assert(walk.start({ 3000, 0, 100 }, "the door"))
in_game = false; t.run(0.3)
assert(not walk.active() and pawn.Controller == pc, "a scene hands back")
in_game = true
calls = {}
assert(walk.start({ 3000, 0, 100 }, "the door"))
require("state").mark_loading(1); t.run(0.5)
assert(not walk.active(), "a load ends it")
assert(not walk.start({ 3000, 0, 100 }, "the door"), "never starts during a load")
t.run(1)
-- The load rebuilt the world: the player's controller holds the character again. A walk
-- never starts from a character an AI controller holds.
local leftover = pawn.Controller
assert(leftover == ai, "a load leaves the hand-back to the game")
assert(not walk.start({ 3000, 0, 100 }, "the door"), "never hands back to an AI controller")
pawn.Controller = pc

-- No path: never leaves the AI holding the character.
calls, move_result = {}, 0
assert(not walk.start({ 3000, 0, 100 }, "the door"), "no path: not started")
assert(pawn.Controller == pc, "no path: control is back")
print("ai walk test passed")
