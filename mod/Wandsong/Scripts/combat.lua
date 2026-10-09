-- Combat: what a sighted player sees of a fight beyond the attack warnings (feedback.lua), as
-- sound: your block working, your spells landing, enemies falling, and how many there are.
-- Matt (Oct 9, the vault's first fight): "a lot", through it "mainly by luck". The warnings came,
-- but nothing said a block had worked, a spell had hit, or how many were left; his Q presses
-- came a few seconds late or between attacks, and only the one a second after the alarm counted.
--
--   * a block that works (Biped_Player NotifySucessfulBlock): a bright chime, and the first few
--     times "Blocked." too, so the alarm-then-Q rhythm is learnt;
--   * your spell hitting (the HUD's damage numbers, UI_BP_DamageIndicators OnNPC_Damaged): a
--     soft tick, higher on a weak spot. Never speech: hits come fast;
--   * an enemy down (EncounterTracker OnCombatVolumeDeath): "One down, three left.";
--   * a fight starting (EncounterTracker StartEncounterForPlayersCombatVolume): "Fight: four
--     enemies." Speech only for counts.
-- Each event is logged as it arrives: which ones this game sends is unproven (Oct 9).
-- Hooks are registered once at startup and copy scalars and paths only; how many enemies are
-- left comes from the world scan's snapshot, never from looking anything up.
local dispatch, state, world, speech = require("dispatch"), require("state"), require("world"), require("speech")

local M = {}
local function log(s) print("[Wandsong combat] " .. s .. "\n") end

local audio
do
    local ok, a = pcall(require, "audio_bridge")
    if ok and type(a) == "table" and a.init() then audio = a end
end
local function sounds_ok()
    return audio and not speech.is_muted() and (not world.sounds_enabled or world.sounds_enabled())
end

local queue = {}
local function record(kind, data)
    if #queue < 64 then queue[#queue + 1] = { kind = kind, data = data, at = os.clock(), generation = state.generation } end
end
local function value(p)
    local ok, v = pcall(function() return p:get() end)
    return ok and v or nil
end
local function path_of(o)
    local ok, full = pcall(function() return o:GetFullName() end)
    return ok and type(full) == "string" and full:match("^%S+%s+(.+)$") or nil
end

local function native(path, fn)
    if type(RegisterHook) ~= "function" then return end
    local ok, err = pcall(RegisterHook, path, fn)
    if not ok then log("hook unavailable " .. path .. ": " .. tostring(err)) end
end
native("/Script/Phoenix.Biped_Player:NotifySucessfulBlock", function() record("block") end)
native("/Script/Phoenix.EncounterTracker:OnCombatVolumeDeath", function(_, _, dead)
    local p
    pcall(function() p = path_of(dead:get()) end)
    record("down", p)
end)
native("/Script/Phoenix.EncounterTracker:StartEncounterForPlayersCombatVolume", function() record("fight") end)
if type(RegisterCustomEvent) == "function" then
    local ok, err = pcall(RegisterCustomEvent, "OnNPC_Damaged", function(ctx, _, damage, weak)
        local p
        pcall(function() p = path_of(ctx:get()) end)
        if not (p and p:find("DamageIndicators", 1, true)) then return end
        record("hit", { damage = value(damage), weak = value(weak) == true })
    end)
    if not ok then log("hook unavailable OnNPC_Damaged: " .. tostring(err)) end
end

local COUNT = { "One", "Two", "Three", "Four", "Five", "Six", "Seven", "Eight", "Nine", "Ten" }
local function count_word(n) return COUNT[n] or tostring(n) end
local FIGHT_CM = 3000            -- enemies this near count as in the fight
local BLOCK_TEACH = 3            -- "Blocked." said this many times, then the chime alone
local fallen = {}                -- enemies reported down in this fight, by path
local blocks_said, last_hit, hits = 0, -10, 0
local generation = state.generation

--- Enemies near enough to count, not reported down (from the world scan's snapshot).
function M.enemies_left()
    local px, py = world.position()
    if not px then return 0 end
    local n = 0
    for _, e in ipairs(world.entries and world.entries() or {}) do
        if e.kind == "enemy" and e.x and not fallen[e.path]
           and math.sqrt((e.x - px) ^ 2 + (e.y - py) ^ 2) < FIGHT_CM then n = n + 1 end
    end
    return n
end

dispatch.every(100, function()
    if generation ~= state.generation then generation, fallen, queue = state.generation, {}, {} end
    local list = queue
    queue = {}
    local now = os.clock()
    for _, e in ipairs(list) do
        if e.generation == state.generation and now - e.at < 2 then
            if e.kind == "block" then
                log("block worked")
                if sounds_ok() then audio.play_ui("chime", 0.8, 1.6) end
                if blocks_said < BLOCK_TEACH then
                    blocks_said = blocks_said + 1
                    speech.say("Blocked.")
                end
                if blocks_said == 1 then
                    require("tips").once("fight_back", function()
                        local b = require("bindings")
                        return "To fight back, " .. b.spoken("LockOn", "Period") .. " locks on to an enemy and " ..
                               b.spoken("AM_Stupefy", "Slash") .. " casts at it."
                    end)
                end
            elseif e.kind == "hit" then
                hits = hits + 1
                if hits <= 3 or hits % 20 == 0 then
                    log(string.format("hit %s%s (%d so far)", tostring(e.data.damage), e.data.weak and ", weak spot" or "", hits))
                end
                if now - last_hit >= 0.08 and sounds_ok() then
                    last_hit = now
                    audio.play_ui("tick", 0.45, e.data.weak and 2.2 or 1.6)
                end
            elseif e.kind == "down" then
                if e.data then fallen[e.data] = true end
                local left = M.enemies_left()
                log("down " .. tostring(e.data) .. ", " .. left .. " left")
                speech.say(left > 0 and ("One down, " .. count_word(left):lower() .. " left.") or "Last one down.")
            elseif e.kind == "fight" then
                fallen = {}
                log("fight starts")
                -- Enemies may still be arriving: count them a moment later.
                dispatch.later(1500, function()
                    local n = M.enemies_left()
                    if n > 0 and world.in_game() then
                        speech.say("Fight: " .. count_word(n):lower() .. (n == 1 and " enemy." or " enemies."))
                    end
                end, "fight count")
            end
        end
    end
end, "combat")

return M
