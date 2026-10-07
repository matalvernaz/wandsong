-- Keys: one key handler for the whole mod, and rebindable mod actions.
--
-- UE4SS can't remove a key bind once registered, so instead of binding each mod action to a
-- key, this registers every key once (plain, Shift, Ctrl, Ctrl+Shift) and looks up what the
-- press means right now. Rebinding a mod action is then just changing a table entry, and a
-- "press the key you want" capture mode is trivial.
--
-- Mod actions are declared by the modules that own them:
--   keys.action{ id = "review_next", name = "Next item on screen", group = "Menus",
--                default = "]", run = function() ... end }
-- Combos are written like "]", "shift+]", "ctrl+;", "ctrl+shift+;", "f9", "pagedown".
-- The player's choices are saved in keys.ini beside this script; anything not listed there
-- uses its default.

local dispatch = require("dispatch")
local diag = require("diag")

local M = {}

local function log(s) print("[Wandsong keys] " .. s .. "\n") end

-- --- Key names ----------------------------------------------------------------------------

-- Spoken names and combo-string names for UE4SS Key enum entries.
local SPOKEN = {
    OEM_FOUR = "left bracket", OEM_SIX = "right bracket", OEM_FIVE = "backslash",
    OEM_ONE = "semicolon", OEM_SEVEN = "apostrophe", OEM_TWO = "forward slash", OEM_PERIOD = "period",
    OEM_COMMA = "comma", OEM_MINUS = "minus", OEM_PLUS = "equals", OEM_THREE = "grave accent",
    PAGE_UP = "page up", PAGE_DOWN = "page down", HOME = "home", END = "end",
    INS = "insert", DEL = "delete", RETURN = "enter", SPACE = "space", TAB = "tab",
    BACKSPACE = "backspace", ESCAPE = "escape", UP_ARROW = "up arrow", DOWN_ARROW = "down arrow",
    LEFT_ARROW = "left arrow", RIGHT_ARROW = "right arrow",
}
local SHORT = {
    OEM_FOUR = "[", OEM_SIX = "]", OEM_FIVE = "\\", OEM_ONE = ";", OEM_SEVEN = "'",
    OEM_TWO = "/", OEM_PERIOD = ".", OEM_COMMA = ",", OEM_MINUS = "-", OEM_PLUS = "=",
    OEM_THREE = "`", PAGE_UP = "pageup", PAGE_DOWN = "pagedown", DEL = "delete", INS = "insert",
    RETURN = "enter",
}
-- NVDA owns these (Insert and Caps Lock as its modifier, the number pad for review).
local NVDA_KEYS = { INS = true, CAPS_LOCK = true }

local function enum_name_for(short)
    for name in pairs(Key) do
        local s = SHORT[name] or name:lower()
        if s == short then return name end
    end
    return nil
end

local function spoken_key(name)
    if SPOKEN[name] then return SPOKEN[name] end
    local n = name:gsub("^NUM_", "numpad "):gsub("_", " "):lower()
    return n
end

-- "ctrl+shift+]" -> { ctrl = true, shift = true, key = "OEM_SIX" }
local function parse(combo)
    if not combo or combo == "" then return nil end
    local c = { ctrl = false, shift = false }
    local rest = combo:lower()
    while true do
        local m, r = rest:match("^(%a+)%+(.+)$")
        if m == "ctrl" then c.ctrl = true; rest = r
        elseif m == "shift" then c.shift = true; rest = r
        else break end
    end
    c.key = enum_name_for(rest)
    if not c.key then return nil end
    return c
end

local function combo_id(ctrl, shift, key)
    return (ctrl and "ctrl+" or "") .. (shift and "shift+" or "") .. key
end

function M.describe_combo(combo)
    local c = parse(combo)
    if not c then return "none" end
    return (c.ctrl and "control " or "") .. (c.shift and "shift " or "") .. spoken_key(c.key)
end

-- --- Actions and bindings ---------------------------------------------------------------

local actions, order = {}, {}
local by_combo = {}           -- combo id -> action id
local SAVE = nil              -- path of keys.ini

local function script_dir()
    local src = debug.getinfo(1, "S").source or ""
    return src:gsub("^@", ""):gsub("/", "\\"):match("^(.*)\\[^\\]+$") or "."
end

local function rebuild()
    by_combo = {}
    for _, id in ipairs(order) do
        local a = actions[id]
        local c = parse(a.combo)
        if c then
            local key = combo_id(c.ctrl, c.shift, c.key)
            if by_combo[key] then log("conflict: " .. a.combo .. " used by " .. by_combo[key] .. " and " .. id) end
            by_combo[key] = id
        end
    end
end

local function load_saved()
    SAVE = require("files").runtime("keys.ini", true)
    local saved = {}
    local f = io.open(SAVE, "r")
    if f then
        for line in f:lines() do
            local id, combo = line:match("^%s*([%w_]+)%s*=%s*(.-)%s*$")
            if id then saved[id] = combo end
        end
        f:close()
    end
    return saved
end
local saved = load_saved()

local function save()
    local f = io.open(SAVE, "w")
    if not f then return false end
    f:write("; Wandsong key bindings. Delete a line to go back to its default.\n")
    for _, id in ipairs(order) do
        local a = actions[id]
        if a.combo ~= a.default then f:write(id .. " = " .. (a.combo or "") .. "\n") end
    end
    f:close()
    return true
end

--- Declare a mod action. Returns nothing; the key handler finds it by its combo.
function M.action(def)
    assert(def.id and def.run, "keys.action needs id and run")
    def.group = def.group or "Wandsong"
    def.combo = saved[def.id] or def.default
    if not actions[def.id] then order[#order + 1] = def.id end
    actions[def.id] = def
    rebuild()
end

function M.actions()
    local list = {}
    for _, id in ipairs(order) do list[#list + 1] = actions[id] end
    return list
end

function M.combo_of(id) return actions[id] and actions[id].combo end

--- What a combo is already used for by the mod (action or nil).
function M.mod_user_of(combo)
    local c = parse(combo)
    if not c then return nil end
    local id = by_combo[combo_id(c.ctrl, c.shift, c.key)]
    return id and actions[id]
end

function M.nvda_clash(combo)
    local c = parse(combo)
    return c and (NVDA_KEYS[c.key] or c.key:find("^NUM_") ~= nil) or false
end

function M.rebind(id, combo)
    local a = actions[id]
    if not a or not parse(combo) then return false end
    local old = a.combo
    a.combo = combo
    if not save() then a.combo = old; return false end
    rebuild()
    return true
end

-- --- Capture mode ("press the key you want") --------------------------------------------

local capture = nil   -- function(combo_string) while capturing

-- Observers see every key press (combo string and UE4SS key name) before actions run. They
-- run on UE4SS's key thread: set a flag, never touch game objects.
local observers = {}
function M.observe(fn) observers[#observers + 1] = fn end

function M.capture_next(fn) capture = fn end
function M.cancel_capture() capture = nil end

-- --- The one handler ----------------------------------------------------------------------

local QUIET_KEYS = { W = true, A = true, S = true, D = true, SPACE = true, LEFT_SHIFT = true,
                     SHIFT = true, LEFT_CONTROL = true, CONTROL = true }
local function on_press(ctrl, shift, key)
    local short = SHORT[key] or key:lower()
    local combo = (ctrl and "ctrl+" or "") .. (shift and "shift+" or "") .. short
    for _, f in ipairs(observers) do pcall(f, combo, key) end
    if capture then
        local fn = capture
        capture = nil
        diag.trace("key captured " .. combo)
        dispatch.run(function() fn(combo, key) end, "key capture")
        return
    end
    local id = by_combo[combo_id(ctrl, shift, key)]
    if not id then
        -- Game keys too (not movement), so the log shows what opened a menu or started something.
        if not QUIET_KEYS[key] then log("game key " .. combo) end
        return
    end
    local a = actions[id]
    if a.when and not a.when() then diag.trace("key " .. combo .. " -> " .. id .. " (not now)"); return end
    log("pressed " .. combo .. " -> " .. id)
    dispatch.run(a.run, "action " .. id)
end

local registered = 0
for name, value in pairs(Key) do
    if type(value) == "number" then
        for _, mods in ipairs({ { false, false }, { false, true }, { true, false }, { true, true } }) do
            local ctrl, shift = mods[1], mods[2]
            local list = {}
            if ctrl then list[#list + 1] = ModifierKey.CONTROL end
            if shift then list[#list + 1] = ModifierKey.SHIFT end
            local ok
            if #list > 0 then
                ok = pcall(RegisterKeyBind, value, list, function() on_press(ctrl, shift, name) end)
            else
                ok = pcall(RegisterKeyBind, value, function() on_press(false, false, name) end)
            end
            if ok then registered = registered + 1 end
        end
    end
end
log("listening on " .. registered .. " key combinations")

return M
