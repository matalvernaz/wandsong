-- Spell lessons (USpellMiniGameBase): trace the spell's symbol to learn it.
--
-- The game: a spark runs along the symbol's straight segments. Moving the mouse the way the
-- current segment goes keeps it at speed; without that it coasts and slows. At checkpoints an
-- input window opens, and pressing its key (Space, F, or a mouse button) gives a burst. Three
-- seconds in, a chasing spark sets off behind; if it catches up the trace fails and waits to be
-- started again. (Measured Oct 7: see NOTEBOOK.)
--
-- Played by ear (the default, once the player starts it with the game's own key):
--   * the arrow to hold is named a moment before each stroke: "up", "right", or two at once
--     ("down right": either or both will do). A curve is named by the arrows it turns through,
--     so Revelio is "up, right, down, left, down right". (Oct 8: every short segment of its
--     curve was named, 20 words in 7 seconds, and Matt couldn't follow it.)
--   * held arrow keys or W A S D move the wand (the mouse) along the symbol while they point
--     within 67.5 degrees of it, there or just behind or ahead (reaction time, anticipation);
--     a soft tick means on course, a low buzz off course, and a bell pitched and panned the way
--     to go repeats while off course or not steering;
--   * each checkpoint's key is named before its window opens ("space next"), the chime means
--     press it now, a sparkle that it counted. No direction word cuts a key's name off (Oct 8:
--     "space" was cut off 0.1 s in, and both checkpoints were missed);
--   * a rising alarm while the chasing spark is close; after a miss, what went wrong.
-- Or the press key before starting: the tracing assistance does it all (Matt: "a thing that
-- does it for me is nice, but ideally an adapted form").
--
-- The symbol's segments come from the game (OnPathSplineSet, not yet seen in game) or else
-- are recorded as the spark runs, so a retry knows the way as far as it has been.
--
-- Hooks are installed only at startup: UE4SS 3.0.1 retains their registering Lua thread, which
-- is unsafe when registered from a transient dev task. Hooks keep paths/scalars; all widget
-- calls use a fresh lookup on the game thread.
local dispatch, state = require("dispatch"), require("state")
local speech, keys, diag = require("speech"), require("keys"), require("diag")
local bindings = require("bindings")
local ok_input, input = pcall(require, "input_bridge")
local audio
do
    local ok, mod = pcall(require, "audio_bridge")
    if ok and type(mod) == "table" and mod.init() then audio = mod end
end
local M = {}
local lesson, pending = nil, {}
local game_paths = {}    -- each lesson screen's symbol as the game gave it (OnPathSplineSet)
local generation = state.generation
local function log(s) print("[Wandsong spells] " .. s .. "\n") end
local function path_of(o)
    local ok, full = pcall(function() return o:GetFullName() end)
    return ok and full:match("^%S+%s+(.+)$") or nil
end
local function focused()
    local ok, yes = pcall(function() return ok_input and input.focused() end)
    return ok and yes == true
end
local function screen()
    if not lesson or state.loading() or lesson.generation ~= state.generation then return nil end
    local o
    pcall(function()
        local found = StaticFindObject(lesson.path)
        if found and path_of(found) == lesson.path and found:IsValid()
           and found.Visibility ~= 1 and found.Visibility ~= 2 then o = found end
    end)
    return o
end
local function set_mode(mode)
    if lesson then lesson.mode = mode end
    -- While the wand is steered with the arrows, they mustn't also walk the review list.
    state.steering = mode == "adapted" or nil
end
local function clear()
    lesson = nil
    if state.activity == M then state.activity = nil end
    state.spell_lesson, state.steering = nil, nil
end
local function action(code)
    if not focused() or not screen() then return false end
    local ok = pcall(function()
        local mgr = FindFirstOf("UMGInputManager")
        assert(mgr and mgr:IsValid(), "input manager unavailable")
        mgr:OnInputAction(code, 0)
        mgr:OnInputAction(code, 1)
    end)
    return ok
end
local function press_key() return keys.describe_combo(keys.combo_of("press")) end
local function start_key() return bindings.spoken("UMGStartSpellMiniGame", "SpaceBar") end
local function sounds_ok()
    local w = require("world")
    return audio and not speech.is_muted() and (not w.sounds_enabled or w.sounds_enabled())
end

-- The key a checkpoint asks for (EUMGInputAction 77-80 = UMGSpellMinigameOption1-4).
local OPTIONS = { [77] = { "UMGSpellMinigameOption1", "SpaceBar" }, [78] = { "UMGSpellMinigameOption2", "F" },
                  [79] = { "UMGSpellMinigameOption3" }, [80] = { "UMGSpellMinigameOption4" } }
local function option_key(code)
    local o = OPTIONS[code]
    if not o then return nil end
    -- Options 3 and 4 are mouse buttons in the game: the press key stands in for them.
    if not o[2] then return press_key(), true end
    local k = bindings.key(o[1], o[2])
    if not k or not bindings.virtual_key(k) then return press_key(), true end
    return bindings.spoken(o[1], o[2]), false
end

-- Directions on screen (y grows downward) in eight sectors, as words: the stroke "goes up right".
local WORDS = { "right", "up right", "up", "up left", "left", "down left", "down", "down right" }
local function sector(x, y)
    local a = math.deg(math.atan(-y, x))
    return math.floor(((a % 360) + 22.5) / 45) % 8 + 1
end
local function direction_word(x, y) return WORDS[sector(x, y)] end
M.direction_word = direction_word

-- The symbol is a list of segments { x1, y1, x2, y2 } in the game's path coordinates.
local function measure(s)
    local dx, dy = s[3] - s[1], s[4] - s[2]
    return math.sqrt(dx * dx + dy * dy), dx, dy
end

local MIN_RUN_PX = 60    -- a turn shorter than this belongs to the stroke before it

--- The arrows a symbol is traced with, in order: { at = distance along it, word = "right" }.
--- Segments going the same of eight ways make a run. A diagonal run straight after a run along
--- one of its arrows is a curve turning, named by its other arrow, which already works there
--- ("up", "up right", "right" is "up, right"); a diagonal stroke of its own keeps both.
--- complete: segs is the whole symbol (else the last run may still grow).
local function strokes(segs, complete)
    local runs, at = {}, 0
    for _, s in ipairs(segs) do
        local len, dx, dy = measure(s)
        if len > 0 then
            local k, last = sector(dx, dy), runs[#runs]
            if last and last.k == k then last.len = last.len + len
            else runs[#runs + 1] = { k = k, at = at, len = len } end
            at = at + len
        end
    end
    local merged = {}
    for i, r in ipairs(runs) do
        local prev = merged[#merged]
        if prev and (prev.k == r.k or (r.len < MIN_RUN_PX and (i < #runs or not complete))) then
            prev.len = prev.len + r.len
        else
            merged[#merged + 1] = { k = r.k, at = r.at, len = r.len }
        end
    end
    local out, last = {}, nil
    for _, r in ipairs(merged) do
        local word = WORDS[r.k]
        local a, b = word:match("^(%a+) (%a+)$")
        if a and last == a then word = b elseif a and last == b then word = a end
        if word ~= last then out[#out + 1] = { at = r.at, word = word }; last = word end
    end
    return out
end
M.strokes = strokes

local ACCEPT = math.cos(math.rad(67.5))   -- an arrow covers its own way and the diagonals beside it
local BACK_PX, AHEAD_PX = 160, 110         -- the path just behind and just ahead counts too

--- Whether a held direction (a unit vector on screen) is on course at distance d along segs.
local function accepts(segs, d, hx, hy)
    local at = 0
    for _, s in ipairs(segs) do
        if at > d + AHEAD_PX then break end
        local len, dx, dy = measure(s)
        if len > 0 and at + len >= d - BACK_PX and (hx * dx + hy * dy) / len >= ACCEPT then return true end
        at = at + len
    end
    return false
end
M.accepts = accepts

local function same(a, b)
    return math.abs(a[1] - b[1]) + math.abs(a[2] - b[2]) + math.abs(a[3] - b[3]) + math.abs(a[4] - b[4]) < 4
end
--- Distance along segs of a point (pos, or the start) on segment cur; nil if cur isn't in segs.
local function along(segs, cur, pos)
    local at = 0
    for _, s in ipairs(segs) do
        local len, dx, dy = measure(s)
        if same(s, cur) then
            local t = 0
            if pos and len > 0 then
                t = math.max(0, math.min(len, ((pos[1] - s[1]) * dx + (pos[2] - s[2]) * dy) / len))
            end
            return at + t
        end
        at = at + len
    end
end
M.along = along

-- The recorded segments in order; one the spark passed between two looks is bridged.
local function recorded(trail)
    local n = 0
    for i in pairs(trail) do if i > n then n = i end end
    local out, prev = {}, nil
    for i = 1, n do
        local s = trail[i]
        if s then
            if prev and math.abs(prev[3] - s[1]) + math.abs(prev[4] - s[2]) > 2 then
                out[#out + 1] = { prev[3], prev[4], s[1], s[2] }
            end
            out[#out + 1] = s
            prev = s
        end
    end
    return out
end

-- The symbol as its arrows, when the whole of it is known.
local function shape()
    if not lesson or not lesson.full then return nil end
    local words = {}
    for _, st in ipairs(strokes(lesson.full, true)) do words[#words + 1] = st.word end
    return #words > 0 and table.concat(words, ", ") or nil
end

local function first_checkpoint(w)
    pcall(function()
        local cp = w:GetCurrentCheckpointData()
        local key = type(cp.InputAction) == "number" and option_key(cp.InputAction)
        if key then lesson.first_key, lesson.first_early = key, cp.PathSplineIndex == 0 end
    end)
end

local function intro()
    local parts = { (lesson and lesson.name or "Spell") .. " lesson." }
    local arrows = shape()
    if arrows then parts[#parts + 1] = "Arrows: " .. arrows .. "." end
    local first = ""
    if lesson and lesson.first_key then
        first = "; the first is " .. lesson.first_key .. (lesson.first_early and ", right after the start" or "")
    end
    parts[#parts + 1] = "Press " .. start_key() .. " to start, hold each arrow as it's named, and at each " ..
        "chime press the key named just before it" .. first .. "."
    parts[#parts + 1] = "Or press " .. press_key() .. " to have it traced for you."
    return table.concat(parts, " ")
end
M.instructions = intro

local function details()
    return "How tracing works: a spark runs along the symbol, and a few seconds in a second spark " ..
        "chases it; keep yours ahead. The arrow keys or W A S D steer the wand. Each new way is " ..
        "named a moment before it comes: up, down, left, right, or two at once like down right, " ..
        "where either arrow or both will do. Switch when you hear it; the old way still counts " ..
        "for a moment. A soft tick means on course, a low buzz off course, and a bell from the " ..
        "left or the right, higher for up and lower for down, points the way while you're off " ..
        "course or not steering. With no arrow held the spark slows. Before each checkpoint its " ..
        "key is named, like " .. (option_key(77) or "space") .. " next; press it the moment the " ..
        "chime rings. A sparkle means it counted and the spark speeds up. A rising alarm means " ..
        "the chasing spark is close."
end

--- The game's own tracing tutorial (menus.lua): said as this lesson's introduction, once.
function M.tutorial()
    if not lesson then return "" end
    if lesson.intro_said then return "" end
    local w = screen()
    if w then first_checkpoint(w) end
    lesson.intro_said, lesson.intro_at = os.clock(), nil
    return intro()
end

-- A bell placed left or right of the listener and pitched up or down: the way to go.
local function direction_cue(x, y)
    if not sounds_ok() then return end
    local px, py, pz, yaw = require("world").position()
    local f, r = math.rad(yaw or 0), math.rad((yaw or 0) + 90)
    local sx = px + math.cos(f) * 150 + math.cos(r) * x * 300
    local sy = py + math.sin(f) * 150 + math.sin(r) * x * 300
    audio.play("note", sx, sy, pz + 60, 0.6, 2 ^ (-y * 0.6))
end

-- Held steering keys as a screen direction (x right, y down), or nil.
local STEER = { { 0x25, -1, 0 }, { 0x41, -1, 0 }, { 0x27, 1, 0 }, { 0x44, 1, 0 },
                { 0x26, 0, -1 }, { 0x57, 0, -1 }, { 0x28, 0, 1 }, { 0x53, 0, 1 } }
local function held()
    if not (ok_input and input.down) then return nil end
    local hx, hy = 0, 0
    for _, s in ipairs(STEER) do
        local ok, down = pcall(input.down, s[1])
        if ok and down then hx, hy = hx + s[2], hy + s[3] end
    end
    hx, hy = math.max(-1, math.min(1, hx)), math.max(-1, math.min(1, hy))
    if hx == 0 and hy == 0 then return nil end
    local len = math.sqrt(hx * hx + hy * hy)
    return hx / len, hy / len
end

local STEER_PX = 80              -- mouse movement per 100 ms while steering (the assistance's)
local LEAD_PX = 100              -- a stroke is named this far before it starts
local PRE_PX = 300               -- a checkpoint's key is named this far before its window opens
local PROTECT_S = 0.9            -- no direction word cuts a key's name off within this
local FEEDBACK_EVERY = 0.45
local HINT_EVERY = 0.9           -- the way-to-go bell while off course or not steering
local IDLE_HINT_S = 0.6          -- not steering this long brings the bell
local ALARM_GAP = 0.15           -- the chasing spark within this share of the path: alarm
local INTRO_WAIT = 0.4           -- the symbol's path may arrive just after the lesson opens

local function segment_of(spark)
    local s = spark:GetCurrentPathSegment()
    return { s.StartPoint.X, s.StartPoint.Y, s.EndPoint.X, s.EndPoint.Y }
end
local function record(spark, cur)
    local index
    pcall(function() index = spark:GetCurrentPathSegmentIndex() end)
    if type(index) == "number" and index >= 0 and index < 500 then lesson.trail[math.floor(index) + 1] = cur end
end

-- The path the spark is measured on (the game's while it holds the spark's segment, else the
-- recorded one), whether it's the whole symbol, the distance along it and the spark's position.
local function locate(spark, cur)
    local pos
    pcall(function() local p = spark:GetPosition(); pos = { p.X, p.Y } end)
    if pos and (type(pos[1]) ~= "number" or type(pos[2]) ~= "number") then pos = nil end
    if lesson.full then
        local d = along(lesson.full, cur, pos)
        if d then return lesson.full, true, d, pos end
        log("the game's path doesn't hold the spark's segment; using the recorded one")
        lesson.full = nil
    end
    local segs = recorded(lesson.trail)
    return segs, false, along(segs, cur, pos), pos
end

local function hint(sx, sy, now)
    if now < (lesson.next_hint or 0) then return end
    lesson.next_hint = now + HINT_EVERY
    direction_cue(sx, sy)
end

-- Tracing by ear, once per tick while the spark runs.
local function adapted_tick(w)
    local now = os.clock()
    local spark = w.PlayerSpark
    if not spark or not spark:IsValid() or spark.IsRunning ~= true then return end
    local cur = segment_of(spark)
    local length, dx, dy = measure(cur)
    if length <= 0 then return end
    local sx, sy = dx / length, dy / length
    record(spark, cur)
    local segs, complete, d, pos = locate(spark, cur)
    local a = lesson.attempt

    -- The arrow to hold, named a moment before each stroke.
    local word
    if d then
        for _, st in ipairs(strokes(segs, complete)) do
            if st.at > lesson.said_at and d >= st.at - LEAD_PX then
                lesson.said_at = st.at
                if st.word ~= lesson.word then lesson.word, word = st.word, st.word end
            end
        end
    elseif direction_word(sx, sy) ~= lesson.word then
        lesson.word = direction_word(sx, sy)
        word = lesson.word
    end

    -- The next checkpoint: its key is named before its window opens; the chime says now.
    local key_text, cp, code, cid
    pcall(function() cp = w:GetCurrentCheckpointData(); code = cp.InputAction end)
    if cp then
        cid = tostring(cp.PathSplineIndex) .. ":" .. tostring(code)
        pcall(function() cid = cid .. ":" .. cp.InputWindow.X .. ":" .. cp.InputWindow.Y end)
    end
    local key = type(code) == "number" and option_key(code) or nil
    local in_window = w:GetIsInInputWindow()
    if key and not in_window and lesson.named ~= cid and pos then
        local lx, ly, before
        pcall(function() lx, ly, before = cp.Location.X, cp.Location.Y, cp.InputWindow.X end)
        if type(lx) == "number" and type(ly) == "number" then
            local gap = math.sqrt((lx - pos[1]) ^ 2 + (ly - pos[2]) ^ 2) - (type(before) == "number" and before or 150)
            if gap <= PRE_PX then
                lesson.named, key_text = cid, key .. " next"
                log("checkpoint " .. cid .. " named " .. math.floor(gap) .. " before its window")
            end
        end
    end
    lesson.window_code = nil
    if in_window then
        if type(code) == "number" then lesson.window_code = code end
        if key and lesson.announced ~= cid then
            lesson.announced = cid
            if sounds_ok() then audio.play_ui("chime", 0.7, 1.3) end
            -- Not named in time (the game's checkpoint position unknown): named with the chime.
            if lesson.named ~= cid then lesson.named, key_text = cid, key end
            log("checkpoint window " .. cid)
        end
    end

    if key_text then
        speech.alert(word and (word .. ". " .. key_text) or key_text)
        lesson.protect_until = now + PROTECT_S
    elseif word then
        if now < (lesson.protect_until or 0) then speech.say(word, true) else speech.alert(word) end
    end
    if word then log("stroke " .. word .. (d and (" at " .. math.floor(d)) or "")) end

    local hx, hy = held()
    if hx then
        local on
        if d then on = accepts(segs, d, hx, hy) else on = hx * sx + hy * sy >= ACCEPT end
        -- On course, the wand follows the stroke itself; off course, it goes the held way.
        local mx, my = hx, hy
        if on then mx, my = sx, sy end
        input.mouse_move(math.floor(mx * STEER_PX + 0.5), math.floor(my * STEER_PX + 0.5))
        if on then a.on = a.on + 1 else a.off = a.off + 1 end
        lesson.idle_since = nil
        if now >= (lesson.next_feedback or 0) and sounds_ok() then
            lesson.next_feedback = now + FEEDBACK_EVERY
            if on then audio.play_ui("tick", 0.3, 1.3) else audio.play_ui("step_blocked", 0.5) end
        end
        if not on then hint(sx, sy, now) end
    else
        a.idle = a.idle + 1
        lesson.idle_since = lesson.idle_since or now
        if now - lesson.idle_since >= IDLE_HINT_S then hint(sx, sy, now) end
    end

    local mine, bad
    pcall(function() mine = spark:GetTotalDistanceAsPercent() end)
    pcall(function() bad = w.BadSpark:GetTotalDistanceAsPercent() end)
    if type(mine) == "number" then a.pct = mine end
    if type(mine) == "number" and type(bad) == "number" and bad > 0.001 and mine - bad < ALARM_GAP
       and now >= (lesson.next_alarm or 0) and sounds_ok() then
        lesson.next_alarm = now + 0.5
        audio.play_ui("warn", 0.6, 1 + (ALARM_GAP - math.max(0, mine - bad)) * 4)
    end
end

-- After a miss: what happened, the likeliest fix, and how to go again.
local function missed_text()
    local parts = { "The trace was missed." }
    local a = lesson.attempt
    if a then
        local where = type(a.pct) == "number" and math.floor(a.pct * 100 + 0.5)
        parts[1] = "The trace was missed: the chasing spark caught up" ..
            (where and (", " .. where .. " percent of the way") or "") ..
            (lesson.word and (", at the " .. lesson.word .. " stroke") or "") .. "."
        if a.hits + a.misses > 0 then
            parts[#parts + 1] = "Chimes answered: " .. a.hits .. " of " .. (a.hits + a.misses) .. "."
        end
        local ticks = a.on + a.off + a.idle
        if ticks > 0 and a.idle / ticks > 0.3 then
            parts[#parts + 1] = "No arrow held " .. math.floor(a.idle / ticks * 100 + 0.5) ..
                " percent of the time; without one the spark slows."
        elseif ticks > 0 and a.off / ticks > 0.25 then
            parts[#parts + 1] = "Off course " .. math.floor(a.off / ticks * 100 + 0.5) ..
                " percent of the time: switch as soon as the next arrow is named."
        end
    end
    parts[#parts + 1] = "Press " .. start_key() .. " to try again, or " .. press_key() .. " for tracing assistance."
    return table.concat(parts, " ")
end

function M.press()
    local w = screen()
    if not w or not focused() then return end
    if lesson.assisted then
        lesson.assisted = false
        set_mode(nil)
        speech.say("Spell tracing assistance stopped.")
        return
    end
    -- Tracing by ear: a mouse-button checkpoint is open, and this key stands in for it.
    if lesson.mode == "adapted" and lesson.window_code and lesson.window_code >= 79 then
        if action(lesson.window_code) then log("checkpoint by press key " .. lesson.window_code) end
        return
    end
    local ok, waiting = pcall(function() return w:GetIsWaitingForStart() end)
    lesson.assisted, lesson.since, lesson.progress = true, os.clock(), -1
    lesson.checkpoint, lesson.attempt = nil, nil
    set_mode("assist")
    if ok and waiting and not action(76) then
        lesson.assisted = false
        set_mode(nil)
        speech.say("Could not start the spell lesson. Try again.")
        return
    end
    speech.say("Tracing " .. lesson.name .. ". Press " .. press_key() .. " to stop assistance.")
end
function M.items()
    if not lesson then return {} end
    return { { text = intro() }, { text = details() },
        { text = lesson.assisted and "Stop tracing assistance" or "Start tracing assistance", button = true, on_press = M.press } }
end
M.title = "Spell lesson"

-- The symbol's segments from the game's OnPathSplineSet(Spline), copied while the call lasts.
local function read_path(parameter)
    local segs = {}
    local spline = parameter:get()
    spline.PathSegments:ForEach(function(_, e)
        if #segs >= 200 then return end
        local s = e:get()
        local x1, y1, x2, y2 = s.StartPoint.X, s.StartPoint.Y, s.EndPoint.X, s.EndPoint.Y
        if type(x1) == "number" and type(y1) == "number" and type(x2) == "number" and type(y2) == "number" then
            segs[#segs + 1] = { x1, y1, x2, y2 }
        end
    end)
    return segs
end

local EVENTS = { "OnMinigameFullyLoaded", "OnPathSplineSet", "OnStartPressed", "OnEnterInputWindow",
    "OnInputSuccess", "OnInputFailure", "OnMinigameSuccess", "OnMinigameFailure", "OnExitPressed" }
for _, event in ipairs(EVENTS) do
    if type(RegisterCustomEvent) == "function" then
        local ok, err = pcall(RegisterCustomEvent, event, function(ctx, parameter)
            local p = path_of(ctx:get())
            if not p or not p:lower():find("spell", 1, true) then return end
            if event == "OnMinigameFullyLoaded" then state.spell_lesson = p end
            local n, segs
            if event == "OnEnterInputWindow" or event == "OnInputSuccess" or event == "OnInputFailure" then
                pcall(function() n = parameter:get() end)
            elseif event == "OnPathSplineSet" then
                local okp, got = pcall(read_path, parameter)
                if okp and type(got) == "table" and #got > 0 then segs = got end
                log("path from the game: " .. (segs and (#segs .. " segments") or ("unreadable " .. tostring(got))))
            end
            if #pending < 32 then pending[#pending + 1] = {
                event = event, path = p, number = type(n) == "number" and n or nil, segs = segs,
                generation = state.generation } end
        end)
        if not ok then log("hook failed " .. event .. ": " .. tostring(err)) end
    end
end

-- Tracing assistance, once per tick: follow the stroke and press each checkpoint.
local function assist_tick(w)
    local spark = w.PlayerSpark
    if not spark or not spark:IsValid() or spark.IsRunning ~= true then return end
    local segment = spark:GetCurrentPathSegment()
    local dx, dy = segment.EndPoint.X - segment.StartPoint.X, segment.EndPoint.Y - segment.StartPoint.Y
    local length = math.sqrt(dx * dx + dy * dy)
    if length > 0 then
        input.mouse_move(math.floor(dx / length * STEER_PX + 0.5), math.floor(dy / length * STEER_PX + 0.5))
        pcall(record, spark, { segment.StartPoint.X, segment.StartPoint.Y, segment.EndPoint.X, segment.EndPoint.Y })
    end
    if w:GetIsInInputWindow() then
        local checkpoint = w:GetCurrentCheckpointData()
        local code = checkpoint.InputAction
        local id = tostring(checkpoint.PathSplineIndex) .. ":" .. tostring(code)
        pcall(function() id = id .. ":" .. checkpoint.InputWindow.X .. ":" .. checkpoint.InputWindow.Y end)
        if type(code) == "number" and code >= 77 and code <= 80 and lesson.checkpoint ~= id then
            if action(code) then lesson.checkpoint = id; log("checkpoint " .. id) end
        end
    end
    local progress = spark:GetTotalDistanceAsPercent()
    if type(progress) == "number" then
        local quarter = math.floor(progress * 4)
        if quarter > lesson.progress then lesson.progress = quarter; log("progress " .. tostring(progress)) end
    end
end

dispatch.every(100, function()
    if generation ~= state.generation then
        generation = state.generation
        local keep = {}
        for _, e in ipairs(pending) do if e.generation == generation then keep[#keep + 1] = e end end
        pending = keep
        game_paths = {}
        clear()
    end
    if state.loading() then
        -- The new screen may finish loading before the UI settling guard expires. Keep
        -- its same-generation event until then, without touching any widgets during load.
        if lesson then clear() end
        return
    end
    local events = pending
    pending = {}
    for _, e in ipairs(events) do
        if e.generation == state.generation then
            log(e.event .. " " .. e.path .. (e.number and (" " .. e.number) or ""))
            if e.event == "OnPathSplineSet" then
                if e.segs then
                    game_paths[e.path] = e.segs
                    if lesson and lesson.path == e.path then lesson.full = e.segs end
                end
            elseif e.event == "OnMinigameFullyLoaded" then
                lesson = { path = e.path, generation = generation, name = "Spell", assisted = false,
                           trail = {}, full = game_paths[e.path] }
                local w = screen()
                if w then
                    pcall(function() lesson.name = w:GetMiniGameName():ToString() end)
                    state.spell_lesson, state.activity = e.path, M
                    lesson.intro_at = os.clock() + INTRO_WAIT
                else clear() end
            elseif lesson and e.path == lesson.path then
                if e.event == "OnMinigameSuccess" then
                    speech.say(lesson.name .. " learned.")
                    clear()
                elseif e.event == "OnExitPressed" then clear()
                elseif e.event == "OnStartPressed" and not lesson.assisted then
                    -- Started with the game's own key: trace it by ear.
                    set_mode("adapted")
                    lesson.said_at, lesson.word, lesson.announced, lesson.named = -1, nil, nil, nil
                    lesson.next_alarm, lesson.next_hint, lesson.next_feedback = 0, 0, 0
                    lesson.idle_since, lesson.protect_until = nil, nil
                    lesson.attempt = { on = 0, off = 0, idle = 0, hits = 0, misses = 0 }
                    if not (ok_input and input.down) then
                        speech.say("Steering the wand needs the updated input module. Press " .. press_key() ..
                            " for tracing assistance instead.")
                    end
                elseif e.event == "OnInputSuccess" and lesson.mode == "adapted" and lesson.attempt then
                    lesson.attempt.hits = lesson.attempt.hits + 1
                    if sounds_ok() then audio.play_ui("item", 0.5, 1.2) end
                elseif e.event == "OnInputFailure" and lesson.mode == "adapted" and lesson.attempt then
                    lesson.attempt.misses = lesson.attempt.misses + 1
                elseif e.event == "OnMinigameFailure" then
                    local text = missed_text()
                    lesson.assisted = false
                    set_mode(nil)
                    speech.say(text)
                end
            end
        end
    end
    if not lesson then return end
    local w = screen()
    if not w then clear(); return end
    if lesson.intro_at and (os.clock() >= lesson.intro_at or lesson.full) then
        lesson.intro_at = nil
        if not lesson.intro_said then
            lesson.intro_said = os.clock()
            first_checkpoint(w)
            speech.say(intro())
        end
    end
    if lesson.mode == "adapted" then
        if not focused() then return end
        local ok, err = pcall(adapted_tick, w)
        if not ok then
            set_mode(nil)
            log("tracing by ear stopped: " .. tostring(err))
            speech.say("Tracing by ear stopped. Press " .. press_key() .. " for tracing assistance.")
        end
        return
    end
    if not lesson.assisted then return end
    if not focused() or state.paused then
        lesson.assisted = false
        set_mode(nil)
        speech.say("Spell tracing assistance stopped.")
        return
    end
    if os.clock() - lesson.since > 60 then
        lesson.assisted = false
        set_mode(nil)
        speech.say("The spell trace has stopped progressing. Press " .. press_key() .. " to try again.")
        return
    end
    local ok, err = pcall(assist_tick, w)
    if not ok then
        lesson.assisted = false
        set_mode(nil)
        log("assistance stopped: " .. tostring(err))
        speech.say("Spell tracing assistance could not continue. Press " .. press_key() .. " to retry.")
    end
end, "spell lesson", true)
return M
