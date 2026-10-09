-- Subtitles and audio description.
--
-- The game's subtitle widget (Subtitles) is handed every spoken line through
-- BPAddSubtitleEvent(FAudioDialogueLineData, ResolvedSubtitle): the line's id, its length
-- in seconds, the voice, and the finished text. The hook only records them; the work happens
-- on the next dispatcher tick.
--
--   * Every line is logged (id, voice, length, text): that's also how lines get catalogued.
--   * Read subtitles aloud (off by default, as in other access mods): each line is queued for
--     speech, never interrupting.
--   * Audio description (on by default): descriptions.lua holds short descriptions of what's
--     on screen, grouped by the line they follow (matched loosely by text, since they were
--     written from a recording): { after = "line", items = { { delay = s, text = "..." }, ... } }.
--     When that line finishes, each item is spoken at its delay, in the silence that follows.

local dispatch = require("dispatch")
local speech = require("speech")
local keys = require("keys")
local diag = require("diag")
local state = require("state")

local M = {}

local function log(s) print("[Wandsong subtitles] " .. s .. "\n") end

local read_aloud = false
local describe = true

local ok_d, DESCRIPTIONS = pcall(require, "descriptions")
if not ok_d or type(DESCRIPTIONS) ~= "table" then DESCRIPTIONS = {} end

-- Loose text matching: lower case, letters and digits only, as a set of words.
local function words(t)
    local set, n = {}, 0
    for w in t:lower():gsub("[^%w%s]", " "):gmatch("%S+") do
        if not set[w] then set[w] = true; n = n + 1 end
    end
    return set, n
end
-- How much of the shorter text is in the longer one: the game's lines and the recording's
-- transcript don't split speech the same way ("Take this. It's Wiggenweld Potion. That
-- stuff'll right you in a second." against "That stuff will write you in a second.").
local function similarity(a, b, strict)
    local sa, na = words(a)
    local sb, nb = words(b)
    if na == 0 or nb == 0 then return 0 end
    local common = 0
    for w in pairs(sa) do if sb[w] then common = common + 1 end end
    local lo, hi = math.min(na, nb), math.max(na, nb)
    if strict == "contain" then return common / lo end
    -- Short lines would be "contained" in almost anything ("It can't be." in a long Ranrok line
    -- fired his description in the wrong scene): compare them whole. Long ones may be contained,
    -- but must still share a fair part of the longer line.
    if strict or lo < 6 or common / hi < 0.3 then return common / hi end
    return common / lo
end

-- The game's line without its markup and speaker name:
-- "<Name_Text>Professor Fig:</> Are you all right?" -> "Are you all right?"
local function plain(t)
    t = t:gsub("^%s*<Name_Text>.-</>%s*", ""):gsub("<[^>]*>", "")
    return t
end

-- Corrections to the generated descriptions, kept here so rebuilding descriptions.lua with
-- tools/ad doesn't lose them. Held lines (hold = true) are said in play before a scene, and
-- their descriptions wait for that scene, timed from its start.
local CORRECTIONS = {
    -- The vault's first knight puzzle: "It does follow the light." comes while you work it out,
    -- and the knights wake in the scene that starts once it's solved (Oct 7: Matt heard them
    -- described while he was still working the puzzle out). The fight that follows is timed from
    -- Fig's "Look out!", proven in game; the Protego prompt there waits for you.
    { after = "It does follow the light.", hold = true, keep = 3, add = {
        { id = "EleazarFig_13089", after = "Look out!", items = {
            { delay = 0.9, text = "Professor Fig raises his wand as a knight advances." },
            { delay = 9.3, text = "Fig's spells shatter one knight and hurl another back." },
        } },
    } },
    -- Walking to the vault door ("Lead the way."): its scene starts when you touch the symbol.
    { id = "EleazarFig_13170", hold = true },
    -- Walking through the Portkey cave: the clifftop scene starts as you come out of it.
    { id = "EleazarFig_12942", hold = true },
    -- Said as the vault's last fight begins; its descriptions are the cutscene after the fight
    -- (the recording's silence came minutes later). Held, they wait for that scene to start
    -- instead of describing a stone basin over the fight (Oct 8).
    { after = "I'm going to have to fight my way out of here.", hold = true },
    -- "Why would someone have built this here?" came a scene and 90 s after the ruins were
    -- described as "crumbling ruins crown a sea stack": Matt didn't know what "this" was (Oct 8).
    -- Plain words first, and the ruins again as you reach them.
    { after = "We're close now. It's just ahead.",
      replace = { [1] = "Ahead, the ruins of a castle stand on a tall rock in the sea, joined to the cliffs by a stone causeway." },
      add = {
        { id = "EleazarFig_13024", after = "Almost there!", items = {
            { delay = 1.0, text = "Stone steps climb the rock into the ruins: a roofless hall of broken walls and tall empty arches, open to the sky." },
        } },
    } },
}
for _, c in ipairs(CORRECTIONS) do
    for i, d in ipairs(DESCRIPTIONS) do
        -- By the game's line ID when given (a common line like "Lead the way." is said
        -- elsewhere too), else by the line's text.
        local same = c.id and d.id == c.id or (not c.id and d.after == c.after)
        if same and type(d.items) == "table" then
            if c.hold then d.hold = true end
            for k, text in pairs(c.replace or {}) do
                if d.items[k] then d.items[k].text = text end
            end
            if c.keep then
                while #d.items > c.keep do table.remove(d.items) end
            end
            for j, extra in ipairs(c.add or {}) do table.insert(DESCRIPTIONS, i + j, extra) end
            break
        end
    end
end
M.descriptions = DESCRIPTIONS   -- for the tests: the catalogue with its corrections applied

-- A held description waits this long at most for its scene (a load still ends it). Oct 9: the
-- vault's basin, held from "I'm going to have to fight my way out of here", came 22 minutes later
-- for Matt (the fight, the dark maze, the stuck gate), and 15 minutes had dropped its opening.
local HOLD_MAX = 3600

-- The story's first moments come before anyone speaks, so no line can key them. They play when
-- the first scene starts after a new character is finished (menus.lua sets state.new_story_since
-- on the finalize screen). From the recording: the Start Your Journey banner bursts into golden
-- sparks, a fade, then you stand in the street. (Matt's Oct 8 "doesn't mention the character
-- apparating in" was George Osric, later in the scene: the second description pass has him.)
local OPENING = {
    { delay = 0.5, text = "Golden sparks swirl around you. Now you stand on a foggy, cobbled London street at night." },
    { delay = 5.0, text = "A carriage waits behind you, an owl on its luggage. Professor Fig, grey-haired, in a green robe, stands by it." },
}

-- The mod's own hints, spoken after the game's hint lines (not descriptions of the frames).
local HINTS = {
    -- The vault's second knight puzzle: your character asks where to stand (Oct 9).
    { id = "PlayerMale_33204", after = "Where do I need to be to get all of them to stand at once?", items = {
        { delay = 0.4, text = "Find where all three knights' hums sound together." },
    } },
}
for _, d in ipairs(HINTS) do DESCRIPTIONS[#DESCRIPTIONS + 1] = d end

-- Index the descriptions once: each entry { after = "line text", delay = s, text = "..." }.
for _, d in ipairs(DESCRIPTIONS) do d.after_words = d.after and select(1, words(d.after)) end
-- Deduplicate delivery of a line, not the description for the lifetime of the process.
-- Replaying a scene must be describable without restarting the game.

-- Short trigger lines ("Ah.", "Accio.") also need a line shortly before them to match (prev).
-- Several back, not one: the game interleaves lines the recording's transcript didn't have.
local before = {}   -- the last few spoken lines, newest last
local function after_prev(prev)
    -- A short line before ("Revelio.") must be that line, not a word inside a longer one
    -- ("Hmm. Revelio, perhaps." fired a much later scene's description in the vault, Oct 7).
    local _, n = words(prev)
    for i = math.max(1, #before - 2), #before do
        if similarity(before[i], prev, n >= 4 and "contain" or true) >= 0.5 then return true end
    end
    return false
end
-- Descriptions run in story order, so a text match far from the last description that
-- played belongs to another scene with similar words. Entries keyed by line ID are exempt.
local NEAR_ENTRIES = 40
local last_match = nil
-- The player's own lines carry the chosen voice in their ID (PlayerFemale_32116): compare them
-- without it, so a description keyed in one playthrough fires for either voice.
local function same_line(a, b)
    if a == b then return true end
    local pa, pb = a:match("^Player%a*(_.*)$"), b:match("^Player%a*(_.*)$")
    return pa ~= nil and pa == pb
end
local function match(text, id)
    -- Keyed to the game's own line ID (tools/ad/build_keyed.py): exact, nothing else can fire it.
    if id then
        for i, d in ipairs(DESCRIPTIONS) do
            if d.id and same_line(d.id, id) then return i, 1 end
        end
    end
    local best, best_s = nil, 0.7
    for i, d in ipairs(DESCRIPTIONS) do
        -- Player lines may also differ by voice number: they keep the text match as a fallback.
        if d.after and (not d.id or d.id:find("^Player"))
           and (not last_match or math.abs(i - last_match) <= NEAR_ENTRIES) then
            local s = similarity(text, d.after)
            if s > best_s and (not d.prev or after_prev(d.prev)) then best, best_s = i, s end
        end
    end
    return best, best_s
end

local pending = {}
local scheduled = {}
local generation, scene = state.generation, state.scene
local serial = 0
local last_tick = os.clock()

-- keep_held: dialogue cut short now doesn't concern a description held for a scene to come.
local function cancel_descriptions(keep_held)
    serial = serial + 1
    local keep = {}
    if keep_held then
        for _, item in ipairs(scheduled) do
            if item.held then item.serial = serial; keep[#keep + 1] = item end
        end
    end
    scheduled = keep
end

local recent = {}
local skip_requested = false
local line_ends = -1       -- when the last line was due to finish
--- True once no game line has been playing for `seconds` (for things that shouldn't talk over
--- the dialogue).
function M.quiet_for(seconds) return os.clock() - line_ends >= (seconds or 0) end
-- A description held back by lines spoken over its moment is dropped once it is this late.
local MAX_LATE = 15
-- Consecutive cutscenes leave cinematic mode for a moment between them (the walk to the
-- Gringotts cart and the ride, Oct 7): only an exit that lasts this long ends the scene.
local SCENE_EXIT_GRACE = 2.0
local exit_since = nil
-- A load in the middle of a scene (Oct 8: the title card, then Hogwarts at night) ended every
-- description still to come. Now what a scene still had to describe within CARRY_MAX waits
-- for the scene after the load, in order and as far apart as planned; if no scene starts
-- within CARRY_WAIT of the load, they're dropped. Any other load (fast travel, a reload after
-- defeat) still ends them.
local CARRY_MAX, CARRY_WAIT = 40, 15
local carried = nil              -- { items = { { text, gap } }, since = when the load ended }
local cinematic_at = -100        -- when a scene was last seen playing
local binding = require("bindings")
local skip_vk = binding.virtual_key(binding.key("UMGSkipCinematicOrConversation", "Delete"))
keys.observe(function(_, key)
    -- Key observers run outside the game thread. Copy only a flag here.
    if skip_vk and Key[key] == skip_vk then skip_requested = true end
end)
local function on_line(e)
    if e.generation ~= state.generation or state.loading() then return end
    -- Both hooks can report the same line: once is enough.
    local now = os.clock()
    local key = tostring(e.id or "") .. "\0" .. tostring(e.text)
    if recent[key] and now < recent[key] then return end
    recent[key] = now + math.max(1, e.dur or 0)
    for k, until_t in pairs(recent) do if until_t < now then recent[k] = nil end end
    -- A line that starts while the last one should still be playing cut it short (a skip): the
    -- silence its descriptions were written for never comes. A line spoken in a silence (an
    -- interjection the recording's transcript missed, "Hang on!") only holds back descriptions
    -- that would talk over it; later ones keep their moment (Oct 6: "Nor do I." dropped two).
    -- Sound-only lines ("(snoring)", 13 s in the Gringotts lobby) are neither: descriptions
    -- play over them, and they say nothing about skipping.
    local sound_only = plain(e.text or ""):match("^%s*%(.*%)%s*$") ~= nil
    local cut_short = not sound_only and now < line_ends - 0.5
    if not sound_only then line_ends = now + (e.dur or 0) end
    if sound_only then
        -- nothing to hold back
    elseif cut_short then
        cancel_descriptions(true)
    else
        local keep = {}
        for _, item in ipairs(scheduled) do
            if item.held then keep[#keep + 1] = item
            else
                if item.due < line_ends + 0.3 then item.due = line_ends + 0.3 end
                if item.due - item.planned <= MAX_LATE then keep[#keep + 1] = item end
            end
        end
        scheduled = keep
    end
    log(string.format("line %s [%s] %.1fs: %s", e.id or "?", e.voice or "?", e.dur or 0, e.text or ""))
    if not e.text or e.text == "" then return end
    -- Read aloud, but not sound-only lines like "(effort sound)" or "(pained cry)".
    if read_aloud and not plain(e.text):match("^%s*%(.*%)%s*$") then speech.say((e.text:gsub("<[^>]*>", "")), true) end
    -- The speaker's on-screen name names them in the scanner ("Professor Fig", not "Student").
    local shown = e.text:match("^%s*<Name_Text>(.-):?</>")
    if shown and e.speaker and e.voice ~= "Player" then
        pcall(function() require("world").name_actor(e.speaker, (shown:gsub(":%s*$", ""))) end)
    end
    e.text = plain(e.text)
    -- Sound-only lines ("(snoring)") are neither triggers nor the line before one.
    if e.text:match("^%s*%(.*%)%s*$") then return end
    local i, s
    if describe and #DESCRIPTIONS > 0 then i, s = match(e.text, e.id) end
    if i then last_match = i end
    before[#before + 1] = e.text
    if #before > 3 then table.remove(before, 1) end
    if not i then return end
    local d = DESCRIPTIONS[i]
    local items = d.items or { { delay = d.delay, text = d.text } }
    -- Held for the scene to come: timed from that scene's start, not from this line.
    local held = d.hold and not state.cinematic or nil
    local function wait_for(it) return (held and 0 or (e.dur or 0)) + (it.delay or 0.3) end
    -- This line starts its own descriptions: ones still waiting from an earlier line that fall
    -- after its first would describe the same moments twice, out of order.
    local first
    for _, it in ipairs(items) do
        if it.text and it.text ~= "" then
            local due = now + math.max(0, wait_for(it))
            first = first and math.min(first, due) or due
        end
    end
    if first then
        local keep = {}
        for _, item in ipairs(scheduled) do if item.held or item.due < first then keep[#keep + 1] = item end end
        scheduled = keep
    end
    for _, it in ipairs(items) do
        if it.text and it.text ~= "" then
            local wait = wait_for(it)
            log(string.format("description %d (match %.2f) in %.1f s%s: %s", i, s, wait,
                held and " of the next scene" or "", it.text))
            local due = now + math.max(0, wait)
            scheduled[#scheduled + 1] = { due = due, planned = due, at = now, text = it.text,
                serial = serial, generation = generation, scene = scene, held = held }
        end
    end
end

local function capture(ctx, data, text)
        diag.trace("hook subtitle")
        local e = { generation = state.generation }
        pcall(function() e.text = text:get():ToString() end)
        pcall(function()
            local d = data:get()
            e.id = d.lineID:ToString()
            e.dur = d.DurationSeconds
            e.voice = d.VoiceName:ToString()
        end)
        -- Who is speaking, as a path only (nothing is kept): the scanner names them by it.
        pcall(function()
            local a = data:get().SpeakingActor:Get()
            local full = a:GetFullName()
            e.speaker = full:match("^%S+%s+(.+)$")
        end)
        if #pending < 64 then pending[#pending + 1] = e end
end
local function hook_ok(fn, quiet)
    local ok, err = pcall(RegisterHook, fn, capture)
    if ok or not quiet then log((ok and "hooked " or "could not hook ") .. fn .. (ok and "" or (": " .. tostring(err)))) end
    return ok
end
-- A named Blueprint event follows every loaded override, including after a reload.
-- RegisterHook in 3.0.1 allocates registry references even when the function is absent.
local custom = type(RegisterCustomEvent) == "function" and pcall(RegisterCustomEvent, "BPAddSubtitleEvent", capture)
if custom then log("hooked Blueprint subtitle events")
else
    hook_ok("/Script/Phoenix.Subtitles:BPAddSubtitleEvent")
    local BP_EVENT = "/Game/UI/HUD/Subtitles/UI_BP_Subtitle.UI_BP_Subtitle_C:BPAddSubtitleEvent"
    dispatch.every(3000, function()
        local ok, fn = pcall(StaticFindObject, BP_EVENT)
        if ok and fn and fn:IsValid() then hook_ok(BP_EVENT); return true end
    end, "subtitle hook")
end

dispatch.every(100, function()
    local now = os.clock()
    local elapsed = now - last_tick
    last_tick = now
    if skip_requested then
        skip_requested = false
        cancel_descriptions()
        pending, recent, before, carried = {}, {}, {}, nil
    end
    if state.cinematic and not state.loading() then cinematic_at = now end
    if generation ~= state.generation or state.loading() then
        if state.loading() and not carried and describe and now - cinematic_at < 5 then
            local items = {}
            for _, item in ipairs(scheduled) do
                if item.serial == serial and not item.held and item.due - now <= CARRY_MAX then items[#items + 1] = item end
            end
            table.sort(items, function(a, b) return a.due < b.due end)
            if #items > 0 then
                carried = { items = {} }
                for i, it in ipairs(items) do carried.items[i] = { text = it.text, gap = it.due - items[1].due } end
                log("descriptions carried over a load in a scene: " .. #items)
            end
        end
        generation, scene, exit_since = state.generation, state.scene, nil
        last_match = nil   -- a load can land anywhere in the story
        cancel_descriptions()
        recent, before = {}, {}
        if state.loading() then pending = {}; return end
    elseif scene ~= state.scene and not state.cinematic then
        -- Left a scene: if no scene follows within the grace, the descriptions end with it.
        exit_since = exit_since or now
        if now - exit_since >= SCENE_EXIT_GRACE then
            -- Only what the scene queued ends with it; a line spoken since keeps its own.
            local keep = {}
            for _, item in ipairs(scheduled) do
                if item.held or item.at >= exit_since then item.scene = state.scene; keep[#keep + 1] = item end
            end
            scheduled = keep
            scene, exit_since = state.scene, nil
            recent, before = {}, {}
        end
    elseif scene ~= state.scene then
        -- The subtitle can arrive just before the gate observes cinematic mode, and one scene
        -- can follow another after a moment out of cinematic mode: keep the descriptions.
        scene, exit_since = state.scene, nil
        for _, item in ipairs(scheduled) do item.scene = scene end
    else
        exit_since = nil
    end
    if state.new_story_since and describe then
        if os.clock() - state.new_story_since > 600 then
            state.new_story_since = nil
        elseif state.cinematic then
            state.new_story_since = nil
            for _, it in ipairs(OPENING) do
                log(string.format("description opening in %.1f s: %s", it.delay, it.text))
                local due = now + it.delay
                scheduled[#scheduled + 1] = { due = due, planned = due, at = now, text = it.text,
                    serial = serial, generation = generation, scene = scene }
            end
        end
    end
    if carried and not describe then carried = nil end
    if carried then
        carried.since = carried.since or now
        -- A moment first for the world gate to see whether the new map opens in a scene.
        if state.cinematic and now - carried.since >= 1 then
            for _, it in ipairs(carried.items) do
                local due = now + 0.5 + it.gap
                scheduled[#scheduled + 1] = { due = due, planned = due, at = now, text = it.text,
                    serial = serial, generation = generation, scene = scene }
            end
            log("descriptions carried over the load: the next scene has them")
            carried = nil
        elseif now - carried.since > CARRY_WAIT then
            log("descriptions carried over the load dropped: no scene followed it")
            carried = nil
        end
    end
    if state.paused then
        for _, item in ipairs(scheduled) do item.due = item.due + elapsed; item.planned = item.planned + elapsed end
        line_ends = line_ends + elapsed
        return
    end
    local batch = pending
    pending = {}
    for _, e in ipairs(batch) do on_line(e) end
    local keep = {}
    for _, item in ipairs(scheduled) do
        if item.serial == serial and item.generation == generation and item.scene == scene and describe then
            if item.held and state.cinematic then item.held = nil end
            if item.held then
                -- Waiting for its scene: the countdown starts when the scene does.
                item.due, item.planned = item.due + elapsed, item.planned + elapsed
                if now - item.at <= HOLD_MAX then keep[#keep + 1] = item end
            elseif now >= item.due then speech.say(item.text, true)
            else keep[#keep + 1] = item end
        end
    end
    scheduled = keep
end, "subtitles", true)

keys.action{ id = "read_subtitles", name = "Read subtitles aloud, on or off", group = "Speech", default = "shift+f7",
             any_time = true, run = function()
                 read_aloud = not read_aloud
                 speech.say("Reading subtitles " .. (read_aloud and "on" or "off"))
             end }
keys.action{ id = "audio_description", name = "Audio description of cutscenes, on or off", group = "Speech",
             default = "shift+f6", any_time = true, run = function()
                 describe = not describe
                 cancel_descriptions()
                 speech.say("Audio description " .. (describe and "on" or "off") ..
                            (#DESCRIPTIONS == 0 and ", but no descriptions are installed yet" or ""))
             end }

log("loaded, " .. #DESCRIPTIONS .. " descriptions")
M.similarity = similarity
return M
