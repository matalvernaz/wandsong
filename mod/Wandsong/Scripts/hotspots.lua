-- Ancient magic hotspots the game won't offer to use. The vault's gate hotspot (Oct 8 and 9) is
-- active, activated and allows interaction, the game counts you inside its radius, and yet it
-- never wants to be interacted with: no Investigate prompt, and F does nothing. Its Blueprint
-- reports the reaching-out animation that comes first as disabled. Facing it, putting Lumos
-- out and walking out and back in all left it so (its inside flag stays set 2.8 m away). In the
-- recording the prompt appears in the swirl and the player channels the magic, which opens the
-- gate; the hotspot's own InteractionInitiated does exactly that (Oct 9, Matt's game).
--
-- So, standing in a hotspot that's ready but offers nothing for a moment, with no other prompt
-- up, the mod says what the prompt would ("Press f to investigate."), and F does it, once per
-- hotspot and map, on the fresh object found at that moment. Where the game shows its prompt,
-- F is the game's and this stays silent.
local world, dispatch, state, speech = require("world"), require("dispatch"), require("state"), require("speech")
local keys, bindings = require("keys"), require("bindings")

local M = {}
local function log(s) print("[Wandsong hotspots] " .. s .. "\n") end

local REACH_CM = 150             -- standing in the swirl
local OFFER_AFTER = 2            -- seconds stuck before the mod speaks for the prompt
local use_at = -100              -- when the interact key was last pressed
local used = {}                  -- hotspots the mod has used on this map, by path
local offered = nil              -- the hotspot the mod has said "press f" for
local stuck_since = nil
local generation = state.generation

local function prompt_up()
    local ok, fb = pcall(require, "feedback")
    return ok and type(fb) == "table" and fb.prompt_active and fb.prompt_active() or false
end
local function near(e)
    local px, py, pz = world.position()
    if not (px and e.x) then return false end
    return math.sqrt((e.x - px) ^ 2 + (e.y - py) ^ 2) <= REACH_CM and math.abs((e.z or pz) - pz) < 300
end
--- Ready but offering nothing: the state the vault's gate hotspot sticks in.
local function stuck(h)
    return h ~= nil and h.active and h.activated and h.allow and not h.wants
end
M.stuck = stuck

-- The world scan's pass copies each hotspot's flags (fresh objects, never kept).
world.on_scan("AncientMagicHotSpot", function(a, e)
    local h = {}
    pcall(function() h.allow = a.allowInteract == true end)
    pcall(function() h.wants = a.WantsToBeInteractable == true end)
    pcall(function() h.activated = a.IsActivated == true end)
    pcall(function() h.active = a.bHotSpotActive == true end)
    e.extra = e.extra or {}
    e.extra.hotspot = h
end)

keys.observe(function(_, key)
    if key == bindings.key("AM_Interact", "F") then use_at = os.clock() end
end)

-- Do what the prompt would: the hotspot found afresh now, its own InteractionInitiated.
local function use(path)
    for _, a in ipairs(FindAllOf("AncientMagicHotSpot") or {}) do
        local full
        pcall(function() full = a:GetFullName() end)
        if full and full:match("^%S+%s+(.+)$") == path then
            local pawn = world.pawn and world.pawn()
            local ok, err = pcall(function() a:InteractionInitiated(pawn) end)
            log("used " .. path .. ": " .. (ok and "ok" or tostring(err)))
            return ok
        end
    end
    log("not found to use: " .. path)
    return false
end

dispatch.every(250, function()
    if generation ~= state.generation then generation, used, offered, stuck_since = state.generation, {}, nil, nil end
    if not world.in_game() then stuck_since = nil; return end
    local here
    for _, e in ipairs(world.entries and world.entries() or {}) do
        if e.kind == "magic" and not used[e.path] and e.extra and stuck(e.extra.hotspot) and near(e) then here = e; break end
    end
    if not here or prompt_up() then
        stuck_since = nil
        if not here then offered = nil end
        return
    end
    if os.clock() - use_at < 1 then
        use_at = -100
        used[here.path] = true
        if use(here.path) then speech.say("Investigating the ancient magic.") end
        return
    end
    stuck_since = stuck_since or os.clock()
    if offered ~= here.path and os.clock() - stuck_since >= OFFER_AFTER then
        offered = here.path
        speech.say("Press " .. bindings.spoken("AM_Interact", "F") .. " to investigate.")
        log("offered " .. here.path)
    end
end, "stuck hotspots")

return M
