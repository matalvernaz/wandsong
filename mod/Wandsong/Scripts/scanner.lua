--[[
    Scanner: speaks a prioritised, categorised readout of what's around the player (F9).
    It knows Hogwarts Legacy's real classes; anything in range it can't classify is logged
    so the categories can be improved.

    Class names below were harvested from the public Hogwarts Legacy SDK dump
    (Roadou/HogwartsLegacy-SDK, game module codename "Phoenix") and cross-checked against
    working UE4SS mods. Key facts that shape the design:
      * FindAllOf("Name") returns that class AND all subclasses. So we filter on BASE
        classes (e.g. "Enemy_Character" catches every hostile) — no IsA/hierarchy walking.
      * Native classes report their FName WITHOUT the A/U prefix ("AContainer" -> "Container").
        Blueprint classes report WITH a "_C" suffix ("BP_OL_Chest_C").
      * If a base string is wrong for this build, only that category returns empty and we
        log it — the scan as a whole still works and still teaches us.

    Design: categories are processed most-specific-first and each actor is claimed once
    (dedup by address), so an enemy (which is also an NPC_Character subclass) is reported as
    "enemy", not "NPC". Anything in range that no category claimed is LOGGED (not spoken) so
    we keep discovering classes exactly like the recon mod did.

    FLAGS to verify on the first live run (still can't test blind — the log tells us):
      * If a category's "found=N" is 0 for something you can clearly see, the base string is
        wrong for this build — the unclassified log dump will show the real name.
      * Clock handedness: UE yaw is left-handed. If "3 o'clock" reads as your left, set
        CLOCK_SIGN = -1.
      * math.atan two-arg (atan2) needs Lua 5.3+. If clock is always 12, swap to math.atan2.
      * GetAddress(): if the log shows "dedup=name" the address call failed and we fell back
        to GetFullName for identity — harmless, just noting which path ran.
--]]

local UNITS_PER_METRE = 100.0
local SCAN_RADIUS_M   = 40.0
local SCAN_RADIUS_U   = SCAN_RADIUS_M * UNITS_PER_METRE
local MAX_SPOKEN      = 6
local CLOCK_SIGN      = 1                 -- set to -1 if clock-directions come out mirrored
-- Log (never speak) in-range actors no category claimed. Debug only: it walks every Actor,
-- and in Hogwarts Legacy each FindAllOf costs ~34 ms and full sweeps have frozen the game.
local REPORT_UNCLASSIFIED = false

-- Categories in priority order (most specific first). Each actor is claimed by the FIRST
-- category whose FindAllOf returns it; later categories skip already-claimed actors.
-- `label` is what NVDA says. `classes` are UE4SS FindAllOf filters (base classes preferred).
local CATEGORIES = {
    { label = "enemy",        classes = { "Enemy_Character", "EnemyBroomRider" } },
    { label = "beast",        classes = { "Creature_Character" } },
    { label = "chest",        classes = { "Container", "BP_OL_Chest_C",
                                          "BP_HouseChest_C", "BP_Disillusionment_Chest_C" } },
    { label = "collectible",  classes = { "FieldGuidePage", "FlyingBook", "CooldownPickup" } },
    { label = "door",         classes = { "Door", "PadlockDoor", "Lockable" } },
    { label = "floo point",   classes = { "Floo", "BP_FastTravel_PillarPlaque_C" } },
    { label = "person",       classes = { "NPC_Character" } },   -- enemies/beasts already claimed
    { label = "interactable", classes = { "SimpleInteractObject", "InteractiveObjectActor" } },
}


local speech = require("speech")
local dispatch = require("dispatch")
local function write_speak(text) speech.say(text) end

local function bearing_to_clock(dx, dy, player_yaw_deg)
    local target_deg = math.deg(math.atan(dy, dx))
    local rel = ((target_deg - player_yaw_deg) * CLOCK_SIGN) % 360
    local hour = math.floor(((rel + 15) % 360) / 30)
    if hour == 0 then hour = 12 end
    return hour
end

local function class_name_of(actor)
    local ok, name = pcall(function() return actor:GetClass():GetFName():ToString() end)
    if ok and name then return name end
    return "<unknown>"
end

-- Stable per-actor identity for dedup across categories. Prefer the object address; fall
-- back to full name. Returns key, method_used.
local function actor_key(actor)
    local ok, addr = pcall(function() return actor:GetAddress() end)
    if ok and addr then return tostring(addr), "addr" end
    local ok2, full = pcall(function() return actor:GetFullName() end)
    if ok2 and full then return full, "name" end
    return nil, "none"
end

local function player_pawn()
    -- Confirmed by real mods: the player pawn is a Biped_Player.
    local ok, p = pcall(function() return FindFirstOf("Biped_Player") end)
    if ok and p and p:IsValid() then return p end
    -- Fallback: via the player controller (recon mod's original path).
    local pc = FindFirstOf("PlayerController")
    if pc and pc:IsValid() then
        local pawn = pc:K2_GetPawn()
        if pawn and pawn:IsValid() then return pawn end
    end
    return nil
end

local function scan_now()
    do
        local pawn = player_pawn()
        if not pawn then
            print("[Wandsong scanner] no player pawn (in a menu / loading?)\n")
            write_speak("No player found")
            return
        end

        local ploc = pawn:K2_GetActorLocation()
        local prot = pawn:K2_GetActorRotation()
        local px, py, pz = ploc.X, ploc.Y, ploc.Z
        local pyaw = prot.Yaw

        local claimed = {}   -- actor_key -> true
        local dedup_method = "addr"
        local hits = {}      -- { label=, m=, clock=, cname= }

        local function consider(actor, label)
            local ok = pcall(function()
                if not actor:IsValid() then return end
                local key, method = actor_key(actor)
                if method ~= "addr" then dedup_method = method end
                if key and claimed[key] then return end
                local loc = actor:K2_GetActorLocation()
                local dx, dy, dz = loc.X - px, loc.Y - py, loc.Z - pz
                local dist = math.sqrt(dx * dx + dy * dy + dz * dz)
                if dist > SCAN_RADIUS_U then return end
                if key then claimed[key] = true end
                hits[#hits + 1] = {
                    label = label,
                    cname = class_name_of(actor),
                    m     = dist / UNITS_PER_METRE,
                    clock = bearing_to_clock(dx, dy, pyaw),
                }
            end)
            return ok
        end

        -- Categorised passes, most-specific first.
        for _, cat in ipairs(CATEGORIES) do
            local found = 0
            for _, cls in ipairs(cat.classes) do
                local ok, actors = pcall(function() return FindAllOf(cls) end)
                if ok and actors then
                    for _, a in ipairs(actors) do
                        local before = #hits
                        consider(a, cat.label)
                        if #hits > before then found = found + 1 end
                    end
                end
            end
            print(string.format("[Wandsong scanner] %-12s in-range=%d\n", cat.label, found))
        end

        -- Discovery: log anything else in range that no category claimed.
        if REPORT_UNCLASSIFIED then
            local ok, actors = pcall(function() return FindAllOf("Actor") end)
            if ok and actors then
                local extra = 0
                for _, a in ipairs(actors) do
                    pcall(function()
                        if not a:IsValid() then return end
                        local key = actor_key(a)
                        if key and claimed[key] then return end
                        local loc = a:K2_GetActorLocation()
                        local dx, dy, dz = loc.X - px, loc.Y - py, loc.Z - pz
                        local dist = math.sqrt(dx * dx + dy * dy + dz * dz)
                        if dist > SCAN_RADIUS_U then return end
                        extra = extra + 1
                        print(string.format(
                            "[Wandsong scanner]  unclassified: %-44s %5.1fm\n",
                            class_name_of(a), dist / UNITS_PER_METRE))
                    end)
                end
                print(string.format(
                    "[Wandsong scanner] %d unclassified actor(s) in range (dedup=%s)\n",
                    extra, dedup_method))
            end
        end

        table.sort(hits, function(l, r) return l.m < r.m end)

        print(string.format("[Wandsong scanner] scan: %d categorised hit(s)\n", #hits))
        for i, h in ipairs(hits) do
            print(string.format("[Wandsong scanner]  %2d. %-12s %-40s %5.1fm  %2d o'clock\n",
                i, h.label, h.cname, h.m, h.clock))
        end

        if #hits == 0 then
            write_speak("Nothing of interest in range")
            return
        end
        local parts = {}
        for i = 1, math.min(MAX_SPOKEN, #hits) do
            local h = hits[i]
            parts[#parts + 1] = string.format(
                "%s, %d metres, %d o'clock", h.label, math.floor(h.m + 0.5), h.clock)
        end
        write_speak(table.concat(parts, ". "))
    end
end

require("keys").action{
    id = "scan", name = "What's around me, with distances and directions", group = "In the world",
    default = "f9", run = scan_now,
}

print("[Wandsong scanner] loaded. Press F9 in the world.\n")
