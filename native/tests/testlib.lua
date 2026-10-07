-- Deterministic clock and UE4SS stand-ins. No windows, game input or player settings.
assert(os.getenv("WANDSONG_TEST_DIR"), "Run tests with tools/run_tests.py (isolated settings required)")
package.path = "mod/Wandsong/Scripts/?.lua;" .. package.path
local M = { now = 0, hooks = {}, actions = {} }
os.clock = function() return M.now end
LoopAsync = function(_, fn) M.loop = fn end
ExecuteInGameThread = function(fn) fn() end
RegisterKeyBind = function() end
RegisterHook = function(name, fn) M.hooks[name] = fn; return 1, 2 end
ModifierKey = { CONTROL = 1, SHIFT = 2 }
Key = { SPACE = 32, ESCAPE = 27, OEM_TWO = 191, OEM_COMMA = 188, OEM_PERIOD = 190,
    OEM_THREE = 192, F5 = 116, F6 = 117, F7 = 118, F8 = 119, F9 = 120,
    UP_ARROW = 38, DOWN_ARROW = 40, LEFT_ARROW = 37, RIGHT_ARROW = 39,
    HOME = 36, END = 35, PAGE_UP = 33, PAGE_DOWN = 34, INS = 45, DEL = 46, CAPS_LOCK = 20 }
for n = 65, 90 do Key[string.char(n)] = n end
function M.run(seconds, before)
    local count = math.floor(seconds / 0.02 + 0.5)
    for _ = 1, count do
        M.now = M.now + 0.02
        if before then before() end
        if M.loop then M.loop() end
    end
end
function M.action(id)
    for _, a in ipairs(require("keys").actions()) do if a.id == id then return a.run end end
    error("missing action " .. id)
end
return M
