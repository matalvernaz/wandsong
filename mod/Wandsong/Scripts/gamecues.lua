-- Game cues: listens to Hogwarts Legacy's own accessibility "audio cue" events.
--
-- The game has a system for deaf players that shows an icon when something audible happens:
-- an interactable comes into range, footsteps, a door, loot, an alerted enemy, a beast's
-- roar, being detected while sneaking, Revelio, being hit (with the angle). Those events name
-- what happened and the actor involved, which is exactly what a blind player needs too.
--
-- For now this only LOGS what arrives, to learn whether the hooks fire in this build and how
-- often, before any sound is attached to them. Hooks stay trivial: record the event type and
-- the actor's path, and log on the dispatcher's next tick.

local dispatch = require("dispatch")
local diag = require("diag")

local M = {}

local function log(s) print("[Wandsong gamecues] " .. s .. "\n") end

local TYPES = {
    [0] = "interact", "footsteps", "spellcaster", "alert", "beast roar", "destructible",
    "running water", "door", "negative interaction", "broom", "loot", "beast aware", "hit",
    "ambient conversation", "stealth detected", "revelio bell", "none",
}

local pending = {}    -- events recorded by hooks, waiting for the next tick
local counts = {}     -- "<kind> <type>" -> count this session
local logged = {}     -- first few of each kind are logged in full

local function param(p)
    local v
    pcall(function() v = p:get() end)
    return v
end

local function actor_path(p)
    local name
    pcall(function()
        local a = p:get()
        if a and a:IsValid() then name = a:GetFullName() end
    end)
    return name or "none"
end

local function record(kind, type_param, actor_param)
    local t = type_param and param(type_param)
    pending[#pending + 1] = { kind = kind, type = TYPES[t] or tostring(t), actor = actor_param and actor_path(actor_param) or "none" }
end

local HOOKS = {
    { "/Script/Phoenix.UIAccessibilityManager:TriggerAccessibilityEvent", function(_, t, a) record("event", t, a) end },
    { "/Script/Phoenix.UIAccessibilityManager:TriggerAccessibilityEventEnter", function(_, t, a) record("enter", t, a) end },
    { "/Script/Phoenix.UIAccessibilityManager:TriggerAccessibilityEventLeave", function(_, t, a) record("leave", t, a) end },
    { "/Script/Phoenix.UIAccessibilityManager:TriggerAccessibilityEventDamage", function(_, a) record("damage", nil, a) end },
    { "/Script/Phoenix.UIManager:TriggerAccessibility", function(_, t, a) record("ui", t, a) end },
}

for _, h in ipairs(HOOKS) do
    local ok, err = pcall(RegisterHook, h[1], function(...)
        diag.trace("hook " .. h[1]:match(":(.+)$"))
        h[2](...)
    end)
    log((ok and "hooked " or "could not hook ") .. h[1] .. (ok and "" or (": " .. tostring(err))))
end

dispatch.every(250, function()
    if #pending == 0 then return end
    local batch = pending
    pending = {}
    for _, e in ipairs(batch) do
        local key = e.kind .. " " .. e.type
        counts[key] = (counts[key] or 0) + 1
        logged[key] = (logged[key] or 0) + 1
        if logged[key] <= 5 then log(key .. " from " .. e.actor) end
    end
end, "game cues", true)

dispatch.every(30000, function()
    local parts = {}
    for k, v in pairs(counts) do parts[#parts + 1] = k .. "=" .. v end
    if #parts > 0 then
        table.sort(parts)
        log("totals: " .. table.concat(parts, ", "))
    end
end, "game cue totals", true)

-- What the game's own cue settings are, so we know whether it's producing cues at all.
dispatch.later(15000, function()
    local s
    pcall(function()
        for _, o in ipairs(FindAllOf("PhoenixGameSettings") or {}) do
            if not o:GetFullName():find("Default__", 1, true) then s = o end
        end
    end)
    if not s then return end
    local vals = {}
    for _, f in ipairs({ "AccessibilityAudioCueOpacity", "AccessibilityAudioCueScale", "PathLineEnabled", "ShowHudBeacons" }) do
        local v
        pcall(function() v = s[f] end)
        vals[#vals + 1] = f .. "=" .. tostring(v)
    end
    log("game settings: " .. table.concat(vals, ", "))
end, "game cue settings")

return M
