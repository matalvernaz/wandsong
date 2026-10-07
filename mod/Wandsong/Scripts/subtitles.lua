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

-- Index the descriptions once: each entry { after = "line text", delay = s, text = "..." }.
for _, d in ipairs(DESCRIPTIONS) do d.after_words = d.after and select(1, words(d.after)) end
-- Deduplicate delivery of a line, not the description for the lifetime of the process.
-- Replaying a scene must be describable without restarting the game.

-- Short trigger lines ("Ah.", "Accio.") also need a line shortly before them to match (prev).
-- Several back, not one: the game interleaves lines the recording's transcript didn't have.
local before = {}   -- the last few spoken lines, newest last
local function after_prev(prev)
    for i = math.max(1, #before - 2), #before do
        if similarity(before[i], prev, "contain") >= 0.5 then return true end
    end
    return false
end
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
        if d.after and (not d.id or d.id:find("^Player")) then
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

local function cancel_descriptions()
    serial = serial + 1
    scheduled = {}
end

local recent = {}
local skip_requested = false
local line_ends = -1       -- when the last line was due to finish
-- A description held back by lines spoken over its moment is dropped once it is this late.
local MAX_LATE = 8
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
    local cut_short = now < line_ends - 0.5
    line_ends = now + (e.dur or 0)
    if cut_short then
        cancel_descriptions()
    else
        local keep = {}
        for _, item in ipairs(scheduled) do
            if item.due < line_ends + 0.3 then item.due = line_ends + 0.3 end
            if item.due - item.planned <= MAX_LATE then keep[#keep + 1] = item end
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
    before[#before + 1] = e.text
    if #before > 3 then table.remove(before, 1) end
    if not i then return end
    local d = DESCRIPTIONS[i]
    local items = d.items or { { delay = d.delay, text = d.text } }
    -- This line starts its own descriptions: ones still waiting from an earlier line that fall
    -- after its first would describe the same moments twice, out of order.
    local first
    for _, it in ipairs(items) do
        if it.text and it.text ~= "" then
            local due = now + math.max(0, (e.dur or 0) + (it.delay or 0.3))
            first = first and math.min(first, due) or due
        end
    end
    if first then
        local keep = {}
        for _, item in ipairs(scheduled) do if item.due < first then keep[#keep + 1] = item end end
        scheduled = keep
    end
    for _, it in ipairs(items) do
        if it.text and it.text ~= "" then
            local wait = (e.dur or 0) + (it.delay or 0.3)
            log(string.format("description %d (match %.2f) in %.1f s: %s", i, s, wait, it.text))
            local due = now + math.max(0, wait)
            scheduled[#scheduled + 1] = { due = due, planned = due, text = it.text,
                serial = serial, generation = generation, scene = scene }
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
        pending, recent, before = {}, {}, {}
    end
    if generation ~= state.generation or (scene ~= state.scene and not state.cinematic) or state.loading() then
        generation, scene = state.generation, state.scene
        cancel_descriptions()
        recent, before = {}, {}
        if state.loading() then pending = {}; return end
    elseif scene ~= state.scene then
        -- The subtitle can arrive just before the gate observes cinematic mode.
        -- Entering that scene must not discard its opening description.
        scene = state.scene
        for _, item in ipairs(scheduled) do item.scene = scene end
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
            if now >= item.due then speech.say(item.text, true) else keep[#keep + 1] = item end
        end
    end
    scheduled = keep
end, "subtitles", true)

keys.action{ id = "read_subtitles", name = "Read subtitles aloud, on or off", group = "Speech", default = "shift+f7",
             run = function()
                 read_aloud = not read_aloud
                 speech.say("Reading subtitles " .. (read_aloud and "on" or "off"))
             end }
keys.action{ id = "audio_description", name = "Audio description of cutscenes, on or off", group = "Speech",
             default = "shift+f6", run = function()
                 describe = not describe
                 cancel_descriptions()
                 speech.say("Audio description " .. (describe and "on" or "off") ..
                            (#DESCRIPTIONS == 0 and ", but no descriptions are installed yet" or ""))
             end }

log("loaded, " .. #DESCRIPTIONS .. " descriptions")
M.similarity = similarity
return M
