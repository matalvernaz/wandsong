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
local function similarity(a, b)
    local sa, na = words(a)
    local sb, nb = words(b)
    if na == 0 or nb == 0 then return 0 end
    local common = 0
    for w in pairs(sa) do if sb[w] then common = common + 1 end end
    return common / math.max(na, nb)
end

-- Index the descriptions once: each entry { after = "line text", delay = s, text = "..." }.
for _, d in ipairs(DESCRIPTIONS) do d.after_words = d.after and select(1, words(d.after)) end
local used = {}   -- descriptions already spoken this session

-- Short trigger lines ("Ah.", "Accio.") also need the line before them to match (prev).
local last_text = ""
local function match(text)
    local best, best_s = nil, 0.6
    for i, d in ipairs(DESCRIPTIONS) do
        if d.after and not used[i] then
            local s = similarity(text, d.after)
            if s > best_s and (not d.prev or similarity(last_text, d.prev) >= 0.5) then best, best_s = i, s end
        end
    end
    return best, best_s
end

local pending = {}

local last_id, last_at = nil, -10
local function on_line(e)
    -- Both hooks can report the same line: once is enough.
    if e.id and e.id == last_id and os.clock() - last_at < 1 then return end
    last_id, last_at = e.id, os.clock()
    log(string.format("line %s [%s] %.1fs: %s", e.id or "?", e.voice or "?", e.dur or 0, e.text or ""))
    if not e.text or e.text == "" then return end
    if read_aloud then speech.say(e.text, true) end
    local prev_text = last_text
    last_text = e.text
    if not describe or #DESCRIPTIONS == 0 then return end
    last_text = prev_text
    local i, s = match(e.text)
    last_text = e.text
    if not i then return end
    used[i] = true
    local d = DESCRIPTIONS[i]
    local items = d.items or { { delay = d.delay, text = d.text } }
    for _, it in ipairs(items) do
        if it.text and it.text ~= "" then
            local wait = (e.dur or 0) + (it.delay or 0.3)
            log(string.format("description %d (match %.2f) in %.1f s: %s", i, s, wait, it.text))
            dispatch.later(math.floor(wait * 1000), function()
                if describe then speech.say(it.text, true) end
            end, "audio description", true)
        end
    end
end

local function hook_ok(fn, quiet)
    local ok, err = pcall(RegisterHook, fn, function(ctx, data, text)
        diag.trace("hook subtitle")
        local e = {}
        pcall(function() e.text = text:get():ToString() end)
        pcall(function()
            local d = data:get()
            e.id = d.lineID:ToString()
            e.dur = d.DurationSeconds
            e.voice = d.VoiceName:ToString()
        end)
        pending[#pending + 1] = e
    end)
    if ok or not quiet then log((ok and "hooked " or "could not hook ") .. fn .. (ok and "" or (": " .. tostring(err)))) end
    return ok
end
hook_ok("/Script/Phoenix.Subtitles:BPAddSubtitleEvent")
-- The game calls the Blueprint subtitle screen's own override of that event, which only exists
-- once the HUD has loaded: keep trying to hook it every 3 s until it takes.
local BP_EVENT = "/Game/UI/HUD/Subtitles/UI_BP_Subtitle.UI_BP_Subtitle_C:BPAddSubtitleEvent"
local tries = 0
dispatch.every(3000, function()
    tries = tries + 1
    if hook_ok(BP_EVENT, tries % 20 ~= 1) then return true end
end, "subtitle hook")

dispatch.every(100, function()
    if #pending == 0 then return end
    local batch = pending
    pending = {}
    for _, e in ipairs(batch) do on_line(e) end
end, "subtitles", true)

keys.action{ id = "read_subtitles", name = "Read subtitles aloud, on or off", group = "Speech", default = "shift+f7",
             run = function()
                 read_aloud = not read_aloud
                 speech.say("Reading subtitles " .. (read_aloud and "on" or "off"))
             end }
keys.action{ id = "audio_description", name = "Audio description of cutscenes, on or off", group = "Speech",
             default = "shift+f6", run = function()
                 describe = not describe
                 speech.say("Audio description " .. (describe and "on" or "off") ..
                            (#DESCRIPTIONS == 0 and ", but no descriptions are installed yet" or ""))
             end }

log("loaded, " .. #DESCRIPTIONS .. " descriptions")
M.similarity = similarity
return M
