-- Controls: one accessible place for every control, the game's and the mod's.
--
-- The menu lists actions grouped by situation (On foot, Spells and combat, Riding and
-- flying, ...; then the mod's own groups). Each entry reads the same way whoever owns it:
-- "Basic cast: left mouse button, slash". Pressing an entry asks for a new key; clashes with
-- other game controls, other mod controls and NVDA are named before anything changes.
--
-- Game bindings come from the game's own Input.ini, which it loads at startup, so a changed
-- game key takes effect the next time the game starts (the mod says so). Mod keys change at
-- once.

local keys = require("keys")
local speech = require("speech")

local M = {}

local function log(s) print("[Wandsong controls] " .. s .. "\n") end

local INPUT_INI = require("files").input()
local bindings = require("bindings") -- capture currently active keys before automatic edits

-- Friendly names for the game's actions; anything missing is derived from its id.
local NAMES = {
    AM_Stupefy = "Basic cast", AM_AimMode = "Aim mode", AM_Dodge = "Dodge",
    AM_Protego = "Protego, block", AM_Oppugno = "Oppugno", AM_Interact = "Interact",
    AM_Jump = "Jump", AM_Sprint = "Sprint", MKB_ToggleWalkJog = "Toggle walk and jog",
    AM_Health = "Drink a healing potion", AM_Revelio = "Revelio", LockOn = "Lock on",
    AM_Navigation = "Show the way to your objective", AM_CriticalFinisher = "Ancient magic finisher",
    AM_SpellButton1 = "Spell slot 1", AM_SpellButton2 = "Spell slot 2",
    AM_SpellButton3 = "Spell slot 3", AM_SpellButton4 = "Spell slot 4",
    AM_Loadout1 = "Spell set 1", AM_Loadout2 = "Spell set 2", AM_Loadout3 = "Spell set 3",
    AM_Loadout4 = "Spell set 4", AM_LoadoutNext = "Next spell set", AM_LoadoutPrevious = "Previous spell set",
    AM_ItemMenu = "Tool wheel", UMGPauseMenu = "Pause menu", UMGMapScreenToggle = "Map",
    UMGInventoryScreenToggle = "Gear", UMGQuestScreenToggle = "Quests", UMGTalentsScreenToggle = "Talents",
    UMGChallengeScreenToggle = "Challenges", UMGCharacterScreenToggle = "Collections",
    UMGCompendiumScreenToggle = "Field guide", UMGOwlMailScreenToggle = "Owl post",
    UMGSettingsScreenToggle = "Settings", UMGActionScreenToggle = "Action screen",
    BroomBoost = "Broom boost", Mount_TakeOff = "Take off", Mount_Dismount = "Dismount",
    Mount_KeyboardWalk = "Mount walk", BroomShowControls = "Show flying controls",
    MiniGame_AutoSolve = "Auto-solve a minigame", MiniGame_Cancel = "Leave a minigame",
    UMGSkipCinematicOrConversation = "Skip a cutscene or conversation",
    UMGOptionPanelNext = "Next dialogue choice", UMGOptionPanelPrevious = "Previous dialogue choice",
    UMGOptionPanelConfirm = "Choose dialogue option", UMGOptionPanelCancel = "Leave a conversation",
    UMGMapScreenWaypoint = "Map: place a marker", UMGMapScreenFastTravel = "Map: fast travel",
    UMGTrackQuest = "Quests: track quest", UMGGadgetWheelConfirm = "Tool wheel: choose",
    Transfig_Confirm = "Transfiguration: confirm",
}
local GROUPS = {
    OnFoot = "On foot", SpellsActions = "Spells and combat", AccessingMenus = "Opening menus",
    Mounts = "Riding and flying", Dialogue = "Conversations", Map = "Map", Inventory = "Gear",
    Transfiguration = "Transfiguration", Beasts = "Beasts", QuestsScreen = "Quests",
    ItemMenu = "Tool wheel", MinigamesGlobal = "Minigames", WingardiumLevioso = "Wingardium Leviosa",
}
local GROUP_ORDER = { "On foot", "Spells and combat", "Riding and flying", "Conversations",
                      "Opening menus", "Tool wheel", "Map", "Quests", "Gear", "Minigames",
                      "Transfiguration", "Wingardium Leviosa", "Beasts" }

-- Unreal key names -> spoken words.
local UE_SPOKEN = {
    LeftMouseButton = "left mouse button", RightMouseButton = "right mouse button",
    MiddleMouseButton = "middle mouse button", MouseScrollUp = "scroll up",
    MouseScrollDown = "scroll down", SpaceBar = "space", LeftShift = "left shift",
    RightShift = "right shift", LeftControl = "left control", RightControl = "right control",
    LeftAlt = "left alt", RightAlt = "right alt", BackSpace = "backspace", CapsLock = "caps lock",
    Slash = "forward slash", Period = "period", Comma = "comma", Semicolon = "semicolon",
    Apostrophe = "apostrophe", LeftBracket = "left bracket", RightBracket = "right bracket",
    Backslash = "backslash", Hyphen = "minus", Equals = "equals", Tilde = "grave accent",
    PageUp = "page up", PageDown = "page down",
    One = "1", Two = "2", Three = "3", Four = "4", Five = "5", Six = "6", Seven = "7",
    Eight = "8", Nine = "9", Zero = "0",
}
local function spoken_ue(k) return UE_SPOKEN[k] or (#k == 1 and k or k:gsub("(%l)(%u)", "%1 %2"):lower()) end

-- UE4SS key enum name -> Unreal key name, for writing game bindings.
local TO_UE = {
    OEM_TWO = "Slash", OEM_PERIOD = "Period", OEM_COMMA = "Comma", OEM_ONE = "Semicolon",
    OEM_SEVEN = "Apostrophe", OEM_FOUR = "LeftBracket", OEM_SIX = "RightBracket",
    OEM_FIVE = "Backslash", OEM_MINUS = "Hyphen", OEM_PLUS = "Equals", OEM_THREE = "Tilde",
    DEL = "Delete", INS = "Insert", HOME = "Home", END = "End", PAGE_UP = "PageUp",
    PAGE_DOWN = "PageDown", SPACE = "SpaceBar", RETURN = "Enter", TAB = "Tab",
    BACKSPACE = "BackSpace", ESCAPE = "Escape", UP_ARROW = "Up", DOWN_ARROW = "Down",
    LEFT_ARROW = "Left", RIGHT_ARROW = "Right", RIGHT_SHIFT = "RightShift",
    LEFT_SHIFT = "LeftShift", RIGHT_CONTROL = "RightControl", LEFT_CONTROL = "LeftControl",
    ONE = "One", TWO = "Two", THREE = "Three", FOUR = "Four", FIVE = "Five", SIX = "Six",
    SEVEN = "Seven", EIGHT = "Eight", NINE = "Nine", ZERO = "Zero",
}
local function to_ue(enum_name)
    if TO_UE[enum_name] then return TO_UE[enum_name] end
    if enum_name:match("^%u$") or enum_name:match("^F%d+$") then return enum_name end
    return nil
end

-- --- Reading the game's bindings ------------------------------------------------------

local function humanize(id)
    local n = id:gsub("^AM_", ""):gsub("^UMG", ""):gsub("^MKB_", ""):gsub("_", " ")
    return (n:gsub("(%l)(%u)", "%1 %2"))
end

local function read_game()
    local f = io.open(INPUT_INI, "r")
    if not f then return nil end
    local actions, order = {}, {}
    for line in f:lines() do
        local name, key, group = line:match('^ActionMappings=%(ActionName="([^"]+)".-Key=([%w_]+),.-GroupName="([^"]*)"')
        if name and not key:find("^Gamepad") then
            local top = group:match("^([^|]+)") or group
            local gname = GROUPS[top]
            if gname then
                local a = actions[name]
                if not a then
                    a = { id = name, name = NAMES[name] or humanize(name), group = gname, keys = {} }
                    actions[name] = a
                    order[#order + 1] = name
                end
                local seen = false
                for _, k in ipairs(a.keys) do if k == key then seen = true end end
                if not seen then a.keys[#a.keys + 1] = key end
            end
        end
    end
    f:close()
    return actions, order
end

-- Which game action already uses an Unreal key (keyboard), if any.
local function game_user_of(ue_key, except)
    local actions = read_game() or {}
    for id, a in pairs(actions) do
        if id ~= except then
            for _, k in ipairs(a.keys) do if k == ue_key then return a end end
        end
    end
    local id = bindings.conflict(ue_key, except)
    if id then return { id = id, name = NAMES[id] or humanize(id) } end
    return nil
end

-- Replace the keyboard keys of a game action with one key, keeping mouse bindings.
local function write_game_key(action_id, ue_key)
    local f = io.open(INPUT_INI, "r")
    if not f then return false end
    local out, keyboard_template, any_template, insert_at = {}, nil, nil, nil
    for line in f:lines() do
        local name, key = line:match('^ActionMappings=%(ActionName="([^"]+)".-Key=([%w_]+),')
        if name == action_id and not key:find("^Gamepad") then
            any_template = any_template or line
            insert_at = insert_at or (#out + 1)
            if key:find("Mouse") then
                out[#out + 1] = line                       -- mouse bindings stay
            else
                keyboard_template = keyboard_template or line   -- old keyboard keys are replaced
            end
        else
            out[#out + 1] = line
        end
    end
    f:close()
    local template = keyboard_template or any_template
    if not template then return false end
    -- Back up the game's file the first time we change it.
    local bak = io.open(INPUT_INI .. ".wandsong-backup", "r")
    if bak then bak:close() else
        local src, dst = io.open(INPUT_INI, "rb"), io.open(INPUT_INI .. ".wandsong-backup", "wb")
        if src and dst then dst:write(src:read("a")) end
        if src then src:close() end
        if dst then dst:close() end
    end
    local new = template:gsub("Key=[%w_]+,", "Key=" .. ue_key .. ",", 1)
                        :gsub("bShift=True", "bShift=False"):gsub("bCtrl=True", "bCtrl=False")
                        :gsub("bAlt=True", "bAlt=False")
    table.insert(out, insert_at, new)
    local w = io.open(INPUT_INI, "w")
    if not w then return false end
    w:write(table.concat(out, "\n") .. "\n")
    w:close()
    return true
end

-- --- The menu --------------------------------------------------------------------------

local function describe_game(a)
    local ks = {}
    for _, k in ipairs(a.keys) do ks[#ks + 1] = spoken_ue(k) end
    return a.name .. ": " .. (#ks > 0 and table.concat(ks, ", ") or "no key")
end

local function rebind_mod(a)
    speech.say("Press the new key for " .. a.name .. ", or Escape to cancel.")
    keys.capture_next(function(combo, enum_name)
        if enum_name == "ESCAPE" then speech.say("Cancelled. " .. a.name .. " stays " .. keys.describe_combo(a.combo) .. "."); return end
        local spoken = keys.describe_combo(combo)
        if keys.nvda_clash(combo) then
            speech.say(spoken .. " belongs to your screen reader. Press another key, or Escape.")
            return rebind_mod(a)
        end
        local other = keys.mod_user_of(combo)
        if other and other.id ~= a.id then
            speech.say(spoken .. " is already " .. other.name .. ". Press another key, or Escape.")
            return rebind_mod(a)
        end
        local ue = to_ue(enum_name)
        local game = ue and game_user_of(ue)
        if game then
            speech.say(spoken .. " is the game's key for " .. game.name ..
                       "; the game would react to it too. Press another key, or Escape.")
            return rebind_mod(a)
        end
        if keys.rebind(a.id, combo) then
            speech.say(a.name .. " is now " .. spoken .. ".")
        else
            speech.say("Couldn't save that key. Your previous binding is unchanged.")
        end
    end)
end

local function rebind_game(a)
    speech.say("Press the new keyboard key for " .. a.name .. ", or Escape to cancel. Mouse bindings stay as they are.")
    keys.capture_next(function(combo, enum_name)
        if enum_name == "ESCAPE" then speech.say("Cancelled."); return end
        local spoken = keys.describe_combo(combo)
        if combo:find("+", 1, true) then
            speech.say("Game controls take a single key. Press one key, or Escape.")
            return rebind_game(a)
        end
        if keys.nvda_clash(combo) then
            speech.say(spoken .. " belongs to your screen reader. Press another key, or Escape.")
            return rebind_game(a)
        end
        local mod = keys.mod_user_of(combo) or keys.mod_user_of("shift+" .. combo)
                    or keys.mod_user_of("ctrl+" .. combo) or keys.mod_user_of("ctrl+shift+" .. combo)
        if mod then
            speech.say(spoken .. " is Wandsong's key for " .. mod.name .. ". Press another key, or Escape.")
            return rebind_game(a)
        end
        local ue = to_ue(enum_name)
        if not ue then speech.say("I can't give the game that key. Press another one, or Escape."); return rebind_game(a) end
        local other = game_user_of(ue, a.id)
        local warn = other and (" Note: " .. spoken .. " also does " .. other.name .. " in some situations.") or ""
        if write_game_key(a.id, ue) then
            speech.say(a.name .. " is now " .. spoken .. ". It takes effect the next time you start the game." .. warn)
            log("game binding " .. a.id .. " -> " .. ue)
        else
            speech.say("Couldn't change that one, sorry.")
        end
    end)
end

-- No-mouse preset: a keyboard key for every action the game puts only on the mouse, for
-- players (laptops especially) who can't easily click. Mouse bindings stay.
local NO_MOUSE = {
    { "AM_Stupefy", "Slash" }, { "BroomBoost", "Slash" }, { "Transfig_Confirm", "Slash" },
    { "UMGGadgetWheelConfirm", "Slash" }, { "AM_AimMode", "RightShift" },
    { "AM_LoadoutPrevious", "Nine" }, { "AM_LoadoutNext", "Zero" },
    { "Transfig_RotateObject_Left", "Nine" }, { "Transfig_RotateObject_Right", "Zero" },
    { "UMGSkipCinematicOrConversation", "Delete" },
}

local function apply_no_mouse()
    local actions = read_game() or {}
    local done = 0
    for _, m in ipairs(NO_MOUSE) do
        local a = actions[m[1]]
        local has_keyboard = false
        if a then for _, k in ipairs(a.keys) do if not k:find("Mouse") then has_keyboard = true end end end
        if a and not has_keyboard and write_game_key(m[1], m[2]) then done = done + 1 end
    end
    speech.say("No-mouse controls applied to " .. done .. " actions. " ..
               "The Controls menu lists their assigned keys. Changes take effect the next time you start the game. " ..
               "Existing keyboard and mouse bindings stay as they are.")
end

-- Game actions whose only keyboard keys belong to the screen reader (NVDA takes Caps Lock,
-- Insert and the number pad for itself) move to a free key, automatically, once. Both keys
-- were checked unused by the game and the mod.
local SCREEN_READER_KEYS = { CapsLock = true, Insert = true }
local SCREEN_READER_FIXES = {
    { "LockOn", "Period", "Lock on" },
}
-- Menu navigation: the up and down arrows walk the mod's list of the screen (menus.lua), so the
-- game's own up/down navigation keeps W and S only. Otherwise both cursors move at once.
local ARROWS_TO_MOD = { { "UMGUINavigateUp", "W", "Up" }, { "UMGUINavigateDown", "S", "Down" } }
local function fix_screen_reader_keys()
    local actions = read_game()
    if not actions then return end
    local moved = {}
    for _, m in ipairs(SCREEN_READER_FIXES) do
        local a = actions[m[1]]
        local keyboard, taken = 0, 0
        if a then
            for _, k in ipairs(a.keys) do
                if not k:find("Mouse") then
                    keyboard = keyboard + 1
                    if SCREEN_READER_KEYS[k] or k:find("^NumPad") then taken = taken + 1 end
                end
            end
        end
        if keyboard > 0 and taken == keyboard and write_game_key(m[1], m[2]) then
            moved[#moved + 1] = m[3] .. " to " .. spoken_ue(m[2])
            log("screen reader key fix: " .. m[1] .. " -> " .. m[2])
        end
    end
    for _, m in ipairs(ARROWS_TO_MOD) do
        -- Menu navigation isn't in the Controls menu's groups: look in the file directly.
        local has_arrow = false
        local f = io.open(INPUT_INI, "r")
        if f then
            for line in f:lines() do
                if line:find('ActionName="' .. m[1] .. '"', 1, true) and line:find("Key=" .. m[3] .. ",", 1, true) then
                    has_arrow = true
                end
            end
            f:close()
        end
        if has_arrow and write_game_key(m[1], m[2]) then
            log("menu arrows: " .. m[1] .. " keeps only " .. m[2])
            moved[#moved + 1] = "menu " .. m[3]:lower() .. " navigation to the mod's list"
        end
    end
    if #moved > 0 then
        require("dispatch").later(4000, function()
            speech.say("Moved " .. table.concat(moved, ", ") .. ", away from a key your screen reader uses. " ..
                       "This takes effect the next time you start the game.", true)
        end, "screen reader key notice", true)
    end
end
-- Only inside the game: offline tests load this file too, and must never touch the player's
-- real settings (the UE4SS global exists only under UE4SS).
if type(UE4SS) == "table" or type(UE4SS) == "userdata" then pcall(fix_screen_reader_keys) end

--- Items for the review screen, grouped, with a press handler on each.
function M.items()
    local items = {}
    local function heading(t) items[#items + 1] = { text = t } end

    items[#items + 1] = { text = "Learn Wandsong's sounds", button = true,
                          on_press = function() require("state").open_screen(require("sounds"), "hear it") end }
    items[#items + 1] = { text = "Apply the no-mouse preset (keyboard keys for every mouse-only action)",
                          button = true, on_press = apply_no_mouse }
    -- The game's own accessibility settings the mod relies on or offers (gamesettings.lua).
    for _, it in ipairs(require("gamesettings").items()) do items[#items + 1] = it end

    local actions, order = read_game()
    if actions then
        local by_group = {}
        for _, id in ipairs(order) do
            local a = actions[id]
            by_group[a.group] = by_group[a.group] or {}
            table.insert(by_group[a.group], a)
        end
        for _, g in ipairs(GROUP_ORDER) do
            if by_group[g] then
                heading(g)
                for _, a in ipairs(by_group[g]) do
                    items[#items + 1] = { id = "game " .. a.id, text = describe_game(a), button = true,
                                          on_press = function() rebind_game(a) end }
                end
            end
        end
    else
        heading("Couldn't read the game's controls file")
    end

    local mod_groups, mod_order = {}, {}
    for _, a in ipairs(keys.actions()) do
        if not mod_groups[a.group] then mod_groups[a.group] = {}; mod_order[#mod_order + 1] = a.group end
        table.insert(mod_groups[a.group], a)
    end
    for _, g in ipairs(mod_order) do
        heading("Wandsong: " .. g)
        for _, a in ipairs(mod_groups[g]) do
            items[#items + 1] = { id = "mod " .. a.id, text = a.name .. ": " .. keys.describe_combo(a.combo), button = true,
                                  on_press = function() rebind_mod(a) end }
        end
    end
    return items
end

M.title = "Controls"
return M
