-- Game settings: the game's own accessibility settings that Wandsong builds on, switched
-- with the setters on the game's settings object (PhoenixGameSettings), the way its own
-- Accessibility menu does, then saved with SaveSettings.
--
-- Three kinds:
--   * needed: the game's audio cues (its sound visualizer and cue icons), which gamecues.lua
--     listens to. Set at every start, before a save loads (the HUD reads the switch when it's
--     built), unless the player switched them off on the Controls screen (game_settings.txt).
--     Every start, because whether the game keeps a change across its own settings restore
--     isn't known yet.
--   * once: subtitles, the minimap path line, target names and highlights, objective markers:
--     turned on at the first start with this version, said aloud, then left to the player.
--   * offered: spell toggle, sprint and walk toggle, camera aiming: never switched by the mod
--     on its own; the Controls screen lists them with the rest, to switch there.
-- Every start logs the values.

local dispatch = require("dispatch")
local speech = require("speech")

local M = {}

local function log(s) print("[Wandsong settings] " .. s .. "\n") end

local FILE = require("files").runtime("game_settings.txt")
local ONCE_VERSION = 1          -- raise it, with `since` on new "once" options, to add more
local CUE_OPACITY = 1.0

local OPTIONS = {
    { id = "cues", kind = "needed", short = "audio cues",
      name = "Audio cues, the game's sound icons, which Wandsong listens to" },
    { id = "subtitles", kind = "once", since = 1, short = "subtitles", name = "Subtitles",
      prop = "SubtitlesEnabled", setter = "SetSubtitlesEnabled" },
    { id = "path_line", kind = "once", since = 1, short = "the path line", name = "Path line on the minimap",
      prop = "PathLineEnabled", setter = "SetMiniMapPathEnabled" },
    { id = "target_name", kind = "once", since = 1, short = "target names", name = "Target names",
      prop = "ShowTargetName", setter = "SetShowTargetName" },
    { id = "target_highlights", kind = "once", since = 1, short = "target highlights", name = "Target highlights",
      prop = "ShowTargetHighlights", setter = "SetShowTargetHighlights" },
    { id = "hud_beacons", kind = "once", since = 1, short = "objective markers", name = "Objective markers",
      prop = "ShowHudBeacons", setter = "SetShowHudBeacons" },
    { id = "spell_toggle", kind = "offered", short = "spell toggle",
      name = "Spell toggle: spells you would hold stay on with one press",
      prop = "bAccessibilitySpellToggle", setter = "SetAccessibilitySpellToggle" },
    { id = "sprint_toggle", kind = "offered", short = "sprint and walk toggle",
      name = "Sprint and walk toggle on the keyboard",
      prop = "bEnableKeyboardSprintWalkToggle", setter = "SetEnableKeyboardSprintWalkToggle" },
    { id = "camera_aiming", kind = "offered", short = "camera aiming",
      name = "Camera aiming: spells go where the camera points",
      prop = "AlwaysUseCameraAiming", setter = "SetAlwaysUseCameraAiming",
      allowed = "AllowOptionToSetAlwaysUseCameraAiming" },
}
local LOGGED = { "AudioVisualizer", "AccessibilityAudioCueOpacity", "AccessibilityAudioCueScale", "SubtitlesEnabled",
    "PathLineEnabled", "ShowTargetName", "ShowTargetHighlights", "ShowHudBeacons", "MenuReaderEnabled",
    "MenuReaderVolume", "bAccessibilitySpellToggle", "bEnableKeyboardSprintWalkToggle", "AlwaysUseCameraAiming",
    "HighContrastMode" }

-- --- The mod's own record (game_settings.txt): once=<version done>, cues=on|off --------------
local saved = {}
local function load_file()
    saved = {}
    local f = io.open(FILE, "r")
    if not f then return end
    for line in f:lines() do
        local k, v = line:match("^%s*([%w_]+)%s*=%s*(.-)%s*$")
        if k then saved[k] = v end
    end
    f:close()
end
local function save_file()
    local f = io.open(FILE, "w")
    if not f then log("could not write " .. FILE); return end
    for _, k in ipairs({ "once", "cues" }) do
        if saved[k] then f:write(k .. "=" .. saved[k] .. "\n") end
    end
    f:close()
end

-- --- The game's settings object ----------------------------------------------------------
-- A long-lived engine object, asked for afresh each time (never kept). Its class default
-- object answers GetPhoenixGameSettings; FindAllOf is the fallback. Never the template.
local function live(o)
    local name = ""
    pcall(function() if o:IsValid() then name = o:GetFullName() end end)
    return name ~= "" and not name:find("Default__", 1, true)
end
local function settings()
    local s
    pcall(function()
        local cdo = StaticFindObject("/Script/Phoenix.Default__PhoenixGameSettings")
        if cdo and cdo:IsValid() then s = cdo:GetPhoenixGameSettings() end
    end)
    if s and live(s) then return s end
    s = nil
    pcall(function()
        for _, o in ipairs(FindAllOf("PhoenixGameSettings") or {}) do
            if live(o) then s = o end
        end
    end)
    return s
end

local function call(s, fn, ...)
    local args = table.pack(...)
    local ok, err = pcall(function() return s[fn](s, table.unpack(args, 1, args.n)) end)
    if not ok then log(fn .. " failed: " .. tostring(err)) end
    return ok
end

local function cues_on(s)
    local visualizer, opacity
    pcall(function() visualizer, opacity = s.AudioVisualizer, s.AccessibilityAudioCueOpacity end)
    return visualizer == true and type(opacity) == "number" and opacity > 0
end
local function set_cues(s, on)
    local ok = call(s, "SetAudioVisualizer", on)
    if on then
        local opacity
        pcall(function() opacity = s.AccessibilityAudioCueOpacity end)
        if not (type(opacity) == "number" and opacity > 0) then
            ok = call(s, "SetAccessibilityAudioCueOpacity", CUE_OPACITY) and ok
        end
    end
    return ok
end

-- An option's state: true/false, or nil when it can't be read (or isn't offered here).
local function value(s, o)
    if o.id == "cues" then return cues_on(s) end
    local v
    pcall(function() v = s[o.prop] end)
    if type(v) == "boolean" then return v end
    return nil
end
local function allowed(s, o)
    if not o.allowed then return true end
    local ok, v = pcall(function() return s[o.allowed](s) end)
    return ok and v == true
end
local function set(s, o, on)
    if o.id == "cues" then return set_cues(s, on) end
    return call(s, o.setter, on)
end
local function save(s)
    if call(s, "SaveSettings") then log("saved") end
end

local function log_values(s)
    local parts = {}
    for _, p in ipairs(LOGGED) do
        local v
        pcall(function() v = s[p] end)
        parts[#parts + 1] = p .. "=" .. tostring(v)
    end
    log("game settings: " .. table.concat(parts, ", "))
end

local function controls_key()
    local ok, k = pcall(function()
        local keys = require("keys")
        return keys.describe_combo(keys.combo_of("controls"))
    end)
    return ok and k or "the Controls key"
end

--- Set what this start needs (see the top of this file). True once the game's settings object
--- was there to set.
function M.apply()
    local s = settings()
    if not s then return false end
    load_file()
    local changed, turned_on = false, {}
    if saved.cues ~= "off" and not cues_on(s) then
        if set_cues(s, true) then changed = true; turned_on[#turned_on + 1] = "audio cues" end
    end
    local done = tonumber(saved.once) or 0
    local first = done < ONCE_VERSION
    if first then
        for _, o in ipairs(OPTIONS) do
            if o.kind == "once" and o.since > done and value(s, o) == false and set(s, o, true) then
                changed = true
                turned_on[#turned_on + 1] = o.short
            end
        end
        saved.once = tostring(ONCE_VERSION)
        save_file()
    end
    if changed then save(s) end
    log_values(s)
    if #turned_on > 0 then
        log("turned on: " .. table.concat(turned_on, ", "))
        if first then
            dispatch.later(6000, function()
                speech.say("Wandsong turned on these game settings: " .. table.concat(turned_on, ", ") ..
                    ". Change them on the Controls screen, " .. controls_key() ..
                    ", or in the game's Accessibility settings.", true)
            end, "game settings notice", true)
        end
    end
    return true
end

--- Switch one option (by id) and save; says the new state.
function M.toggle(id)
    local s = settings()
    local o
    for _, x in ipairs(OPTIONS) do if x.id == id then o = x end end
    if not s or not o or not allowed(s, o) then speech.say("That setting isn't available right now."); return end
    local now = value(s, o)
    if now == nil then speech.say("That setting can't be read right now."); return end
    if not set(s, o, not now) then speech.say("The game didn't take that change."); return end
    if o.id == "cues" then
        load_file()
        saved.cues = now and "off" or "on"
        save_file()
    end
    save(s)
    speech.say(o.short:sub(1, 1):upper() .. o.short:sub(2) .. (now and " off" or " on"))
end

--- Items for the Controls screen: each of the game's settings above with its state.
function M.items()
    local items = { { text = "The game's accessibility settings" } }
    local s = settings()
    if not s then
        items[#items + 1] = { text = "The game's settings aren't available right now." }
        return items
    end
    for _, o in ipairs(OPTIONS) do
        local v = value(s, o)
        if v ~= nil and allowed(s, o) then
            items[#items + 1] = { text = o.name .. ": " .. (v and "on" or "off"), button = true,
                                  on_press = function() M.toggle(o.id) end }
        end
    end
    return items
end

-- At the first ticks, at the main menu: before a save loads and the HUD reads the switches.
local tries = 0
dispatch.every(1000, function()
    tries = tries + 1
    local ok = M.apply()
    if not ok and tries >= 30 then log("the game's settings object wasn't found; nothing was set") end
    return ok or tries >= 30
end, "game settings", true)

return M
