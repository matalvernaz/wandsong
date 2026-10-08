-- Menus: reads the game's menus through the player's screen reader, and lets them review
-- and press anything on screen.
--
-- Every Phoenix menu widget implements GatherMenuReaderStrings(depth), which returns the
-- text the native reader would speak. The game calls ReadMenu(depth, ...) on a widget
-- whenever that widget wants to be read (focus moved, screen opened). We post-hook
-- ReadMenu, gather the strings ourselves and hand them to the speech module.

local speech = require("speech")
local dispatch = require("dispatch")
local diag = require("diag")
local state = require("state")
local keys = require("keys")

-- Spoken name of whatever key an action is bound to right now, e.g. key_name("press").
local function key_name(id) return keys.describe_combo(keys.combo_of(id)) end
local ok_presets, PRESET_DESCRIPTIONS = pcall(require, "creator_presets")
if not ok_presets then PRESET_DESCRIPTIONS = {} end

-- Native OnClicked broadcaster; optional (clicks fall back to Blueprint handlers).
local click_bridge
do
    local ok, mod = pcall(require, "click_bridge")
    if ok and type(mod) == "table" then
        local ready, why = mod.ready()
        if ready then click_bridge = mod end
        print("[Wandsong] click bridge: " .. tostring(why) .. "\n")
    else
        print("[Wandsong] click bridge unavailable: " .. tostring(mod) .. "\n")
    end
end

local TAG = "[Wandsong] "

local function log(s) print(TAG .. s .. "\n") end

local last_text, last_time = nil, 0
-- queue=true speaks after whatever is already talking instead of interrupting it.
local function speak(text, queue)
    -- The same widget is often asked to read twice in one frame; drop exact repeats.
    local now = os.clock()
    if text == last_text and now - last_time < 0.5 then return end
    last_text, last_time = text, now
    speech.say(text, queue)
end

local function to_text(v)
    if type(v) == "string" then return v end
    if type(v) == "userdata" then
        local ok, s = pcall(function() return v:ToString() end)
        if ok then return s end
        ok, s = pcall(function() return v:get():ToString() end)
        if ok then return s end
    end
    return nil
end

-- GatherMenuReaderStrings comes back from UE4SS as a plain Lua table.
local function gather(widget, depth)
    local ok, arr = pcall(function() return widget:GatherMenuReaderStrings(depth) end)
    if not ok then return nil, tostring(arr) end
    local parts = {}
    if type(arr) == "table" then
        for _, v in pairs(arr) do
            local s = to_text(v)
            if s and s ~= "" then parts[#parts + 1] = s end
        end
    else
        local s = to_text(arr)
        if s and s ~= "" then parts[1] = s end
    end
    return parts
end

-- Rich-text cleanup: button icons arrive as <img src="cbi_Keyboard_Space"/>.
local function clean(t)
    t = t:gsub('<img%s+src="cbi_Keyboard_([^"]+)"%s*/>', function(k)
        k = k:gsub("_", " ")
        -- "Slash" alone is easily heard as backslash, which is the mod's own press key.
        if k == "Slash" then return "forward slash" end
        return k
    end)
    -- Mouse prompts become the mod's own key: the "press" action clicks the reviewed item.
    t = t:gsub('<img%s+src="cbi_Mouse_LeftClick"%s*/>', function() return key_name("press") end)
    -- Other mouse buttons have no keyboard meaning for the player; the action they trigger
    -- is still reachable as a shortcut item in the review list.
    t = t:gsub('<img%s+src="cbi_Mouse_[^"]+"%s*/>%s*,?%s*', "")
    -- Spell icons (TUT_*) sit beside the spell's written name, and their own names can differ
    -- from it ("a Basic Cast TUT_Stupefy", "a Stupefy TUT_Stupefy counter-attack", Oct 8): they
    -- are dropped.
    t = t:gsub('<img%s+src="TUT_[^"]*"%s*/>', "")
    t = t:gsub('<img%s+src="([^"]+)"%s*/>', function(k)
        return (k:gsub("^cbi_", ""):gsub("_", " "))
    end)
    t = t:gsub("<[^>]->", "")          -- any other rich-text tag
    t = t:gsub("%s+", " ")
    return (t:gsub("^%s+", ""):gsub("%s+$", ""))
end

-- --- Making the game's text meaningful without sight ---------------------------------------

-- Button hints arrive key first ("backslash, Select, Esc, Back"); say them action first
-- ("Select: backslash. Back: escape").
local KEY_WORDS = {
    ["backslash"] = true, ["forward slash"] = true, ["slash"] = true, ["esc"] = true, ["escape"] = true,
    ["space"] = true, ["enter"] = true, ["tab"] = true, ["backspace"] = true, ["delete"] = true,
    ["shift"] = true, ["left shift"] = true, ["right shift"] = true, ["ctrl"] = true, ["left ctrl"] = true,
    ["left control"] = true, ["alt"] = true, ["up"] = true, ["down"] = true, ["left"] = true, ["right"] = true,
    ["page up"] = true, ["page down"] = true, ["home"] = true, ["end"] = true, ["left bracket"] = true,
    ["right bracket"] = true, ["semicolon"] = true, ["apostrophe"] = true, ["grave accent"] = true,
    ["minus"] = true, ["equals"] = true, ["comma"] = true, ["period"] = true,
}
local function is_key_word(t)
    local l = t:lower()
    return KEY_WORDS[l] or t:match("^%u$") or t:match("^%d$") or t:match("^F%d%d?$")
end
local function legend_order(parts)
    local out, i = {}, 1
    while i <= #parts do
        local a, b = parts[i], parts[i + 1]
        if b and is_key_word(a) and not is_key_word(b) then
            local k = a:lower() == "esc" and "escape" or a
            out[#out + 1] = b .. ": " .. k
            i = i + 2
        else
            out[#out + 1] = a
            i = i + 1
        end
    end
    return out
end

-- Instructions written for sight or the mouse, said in terms that work for the player.
local REWRITES = {
    { "Steady your wand with Mouse.-symbol's path%.$", function()
        if state.activity and state.activity.instructions then return state.activity.instructions() end
        return "Spell lesson. Press " .. require("bindings").spoken("UMGStartSpellMiniGame", "SpaceBar") ..
            " to trace it yourself by ear with the arrow keys, or " .. key_name("press") .. " for tracing assistance."
    end },
    { "Review your objectives to reveal the way forward%.?", function()
        -- The game waits for its own objectives key (AM_Navigation): until it's pressed, this
        -- tutorial comes back about every 40 seconds (Oct 8, the vault fight).
        return "Review your objectives: press " .. require("bindings").spoken("AM_Navigation", "V") ..
               ", the game's objectives key; the game waits for it. " .. key_name("where_am_i") ..
               " also says your quest, its current task and which way the objective is." end },
    { "^Mouse Look Around%.?$", function()
        return "Look around: " .. key_name("turn_left") .. " and " .. key_name("turn_right") ..
               " turn you, " .. key_name("where_am_i") .. " says which way you face." end },
    { "Use your camera Mouse to select an active target%.?", function()
        return "Turn toward an enemy to make it your target: " .. key_name("face_target") ..
               " turns you to the nearest one, and " .. require("bindings").spoken("LockOn", "Period") .. " locks on." end },
    { "The Minimap shows your surroundings.-middle%.", function()
        return "The minimap shows your surroundings to sighted players. With Wandsong, " ..
               key_name("where_am_i") .. " says your quest, its current task and which way the objective is." end },
    { "Continue: Space$", function()
        return "To continue, hold space for a moment." end },
    { "W A S D to Move%.?", function(t)
        return t .. " With Wandsong, " .. key_name("autowalk") .. " walks you to your objective or follows " ..
               "your guide, the arrow keys turn you, and " .. key_name("scan_next") .. " says what's around you." end },
    { "Space to Jump / Climb%.?", function(t)
        return t .. " A quick hop sound means something to jump over, and rising notes a ledge to climb." end },
    { "to perform a Basic Cast[^,]*", function(t)
        return t:gsub("[%.%s]+$", "") .. ". " .. key_name("face_target") .. " turns you to the nearest enemy first." end },
    { "A white outline indicates your active target.-precision%.", function(t)
        return t .. " With Wandsong: " .. key_name("face_target") ..
               " turns you to the nearest enemy, and " .. require("bindings").spoken("LockOn", "Period") .. " locks on to it." end },
}
local function rewrite(text)
    -- A spell's icon reads as its name, right before the name itself: "cast Revelio Revelio",
    -- "extinguish Lumos Lumos".
    text = text:gsub("(%f[%a]%u%a+) %1%f[%A]", "%1")
    -- The game's key names inside its texts, as words: "Press LeftShift to sprint." (Oct 8).
    local b = require("bindings")
    text = text:gsub("%f[%w](%u%l+%u%l+%u?%l*)%f[%W]", function(w)
        if b.KEY_NAMES[w] then return b.spoken_key(w) end
    end)
    for _, r in ipairs(REWRITES) do
        local a, b = text:find(r[1])
        if a then text = text:sub(1, a - 1) .. r[2](text:sub(a, b)) .. text:sub(b + 1) end
    end
    -- Rewritten parts end in a full stop, and the screen's parts are joined with commas:
    -- "which way the objective is., To continue" (Oct 8).
    text = text:gsub("([%.!?]),%s+", "%1 ")
    return text
end

-- Loading screens repeat the same tip several times per load: read each tip once.
local tips_heard = {}
local loading_said = -100

-- Depth 0 = whole screen (title + focused item + hint), 1 = focused item + hint.
-- The hooked depth argument arrives as garbage, so pick our own: full context the first
-- time a widget instance reads, the shorter item text after that.
local note_screen   -- defined in the screen review section below
local forget_screens -- likewise: drops every remembered screen (a map change frees them all)

-- Feed a menu action into the game's UMG input manager (press then release).
local function send_action_early(action)
    local mgr = FindFirstOf("UMGInputManager")
    if not (mgr and mgr:IsValid()) then return false end
    local ok = pcall(function() mgr:OnInputAction(action, 0) end)
    dispatch.later(50, function()
        local fresh = FindFirstOf("UMGInputManager")
        pcall(function() if fresh and fresh:IsValid() then fresh:OnInputAction(action, 1) end end)
    end)
    return ok
end
local label_for
local walk, top_of   -- defined below; used by the hook and by tab naming
local start_editing, editing
local seen = {}
local last_screen_time = -10
local capture_until, hover_details = -10, {}
local quiet_class, quiet_until = nil, -10
local current_screen, current_cls, last_item = nil, "?", ""   -- current_screen is a path

-- Game objects aren't kept between ticks: keep the path, look the object up again.
local function path_of(o)
    local full
    pcall(function() full = o:GetFullName() end)
    return full and full:match("^%S+%s+(.+)$") or nil
end
local function resolve(path)
    if not path then return nil end
    local o
    pcall(function() o = StaticFindObject(path) end)
    local ok, alive = pcall(function() return o and o:IsValid() end)
    if not (ok and alive) then return nil end
    -- A screen the game has just destroyed can still come back from the lookup, its name
    -- already cleared (the Field Guide, 200 ms after the pause menu closed, Oct 6 10:15 PM:
    -- calling a function on it crashed the game). Its full name no longer matches the path.
    local now_path = path_of(o)
    if now_path and now_path ~= path then diag.trace("stale object " .. path); return nil end
    return o
end
local pending_item = nil   -- focus text seen once, waiting to be confirmed stable
local loading_screen = nil -- path of a loading screen while one is up
local tutorial_text = nil -- copied strings only; gameplay tutorials must remain re-readable

local function active_tutorial_items()
    if not tutorial_text or state.loading() or tutorial_text.generation ~= state.generation then return nil end
    local current_path
    pcall(function()
        local system = FindFirstOf("TutorialSystem")
        if not system or not system:IsValid() then return end
        local current = system.CurrentTutorialScreen
        if current and current:IsValid() and current.Visibility ~= 1 and current.Visibility ~= 2 then
            current_path = path_of(current)
        end
    end)
    if current_path ~= tutorial_text.path then tutorial_text = nil; return nil end
    return tutorial_text.items, tutorial_text.path
end

-- Loading-screen widget classes.
local function is_loading_class(cls)
    return cls:find("LoadingScreen", 1, true) or cls == "UI_BP_PSO_FS_C"
end

-- Handles one ReadMenu call, on the dispatcher's next tick (never inside the hook itself).
local tips_reset_at = -100
local function on_read_menu(widget)
    local okv, alive = pcall(function() return widget:IsValid() end)
    if not (okv and alive) then return end
    local key, cls = "?", "?"
    pcall(function() key = widget:GetFullName() end)
    pcall(function() cls = widget:GetClass():GetFName():ToString() end)

    -- A modal tutorial pauses play: the world layer stands down so the review keys can read
    -- it and press its Continue (some must be held; the press key holds those).
    if cls:find("Tutorial_Modal", 1, true) then state.modal_since = os.clock() end
    -- Finishing a new character (name, witch or wizard) starts a new playthrough: the mod's
    -- first-time tips play again, as the game's own tutorials do (Matt, Oct 8).
    if cls:find("CharCreator_Finalize", 1, true) and os.clock() - tips_reset_at > 60 then
        tips_reset_at = os.clock()
        require("tips").reset()
        state.new_story_since = os.clock()   -- the next scene opens the story (subtitles.lua)
        log("new character: the first-time tips will play again")
    end
    -- "Quest failed" (Try Again, Exit to the Main Menu) and being defeated: real menus that the
    -- UI manager doesn't report as one. The world layer stands down while they're up.
    if cls:find("MissionFailScreen", 1, true) or cls:find("GameOver", 1, true) then state.fail_screen_since = os.clock() end

    -- Loading screens tell the world layer to keep its hands off until the load is over.
    if is_loading_class(cls) then
        state.mark_loading(6)
        loading_screen = path_of(widget)
        diag.event("loading", "loading screen: " .. cls)
    end

    local first = not seen[key]
    seen[key] = true
    local parts = gather(widget, first and 0 or 1)
    if (not parts or #parts == 0) and not first then parts = gather(widget, 0) end
    local cleaned = {}
    for _, p in ipairs(parts or {}) do
        local c = clean(p)
        if c ~= "" then cleaned[#cleaned + 1] = c end
    end
    local text = rewrite(table.concat(legend_order(cleaned), ", "))
    if cls:find("Tutorial_NonModal", 1, true) and text ~= "" then
        local items = {}
        for _, part in ipairs(legend_order(cleaned)) do items[#items + 1] = { text = rewrite(part) } end
        tutorial_text = { path = path_of(widget), items = items, generation = state.generation }
    end
    log("ReadMenu " .. cls .. (first and " [open] " or " ") .. "-> " .. text)
    if is_loading_class(cls) and text ~= "" then
        if tips_heard[text] then
            -- Heard before: just "Loading", and not again within the same load.
            text = os.clock() - loading_said > 20 and "Loading" or ""
            if text ~= "" then loading_said = os.clock() end
        else
            tips_heard[text] = true
        end
    end
    -- A whole screen interrupts; small widgets reading themselves right after a screen
    -- (often just whatever the parked mouse pointer is over) queue behind it.
    local is_screen = false
    pcall(function() is_screen = widget:IsInViewport() end)

    -- First launch: the Accessibility screen ignores everything until its Menu Reader
    -- toggle is pressed. Press it for the player and tell them where they are.
    if cls == "UI_BP_FirstFlowAccessibility_C" and text:find("Menu Reader, Off", 1, true) then
        log("first-launch accessibility screen: enabling menu reader for the player")
        dispatch.later(300, function() send_action_early(70) end)
        quiet_class, quiet_until = cls, os.clock() + 3
        speak("Welcome to Hogwarts Legacy, with Wandsong. This is the first-time Accessibility " ..
              "Options screen; I've switched the game's menu reader on for you so it unlocks. " ..
              "Use " .. key_name("review_prev") .. " and " .. key_name("review_next") ..
              " to look through the settings, " .. key_name("press") .. " to change one, " ..
              "and F to continue. " .. key_name("help") .. " for help at any time.")
        return
    end
    -- Right after the welcome, the unlocked screen re-reads itself: don't talk over it.
    if os.clock() < quiet_until then
        if cls == quiet_class or not is_screen then note_screen(widget); return end
    end
    if text ~= "" and not is_screen and os.clock() < capture_until then
        hover_details[#hover_details + 1] = text
        return
    end
    if text ~= "" then
        if is_screen then
            last_screen_time = os.clock()
            speak(text)
            -- If the screen shows much more prose than the game's reader gives us (a letter,
            -- a long notice), read that too, after the summary.
            local wpath = path_of(widget)
            dispatch.later(400, function()
                if state.loading() or require("world").gameplay() or require("world").ui_busy() then return end
                local widget = resolve(wpath)
                local ok_v, still = pcall(function() return widget and widget:IsInViewport() end)
                if not (ok_v and still) then return end
                local items = {}
                walk(widget, items, nil, 0)
                local prose, buttons = {}, 0
                for _, it in ipairs(items) do
                    if it.button then buttons = buttons + 1
                    elseif not it.action and #it.text > 1 and not text:find(it.text, 1, true) then
                        prose[#prose + 1] = it.text
                    end
                end
                local body = table.concat(prose, " ")
                if #body > 200 and buttons < 8 then speak(body, true) end
                -- The game's own announcement says little (e.g. the main menu only names its
                -- Settings shortcut): follow it with the buttons on screen.
                if #text < 60 and buttons > 0 and buttons <= 12 then
                    local labels = {}
                    for _, it in ipairs(items) do
                        if it.button and it.text ~= "unlabelled" then labels[#labels + 1] = it.text end
                    end
                    if #labels > 0 then speak(table.concat(labels, ", "), true) end
                end
            end)
        else
            speak(text, os.clock() - last_screen_time < 2.0)
        end
    end

    note_screen(widget)
    -- Only whole screens are polled for focus changes; small widgets (description panels,
    -- single buttons) would just repeat themselves.
    if is_screen then
        current_screen, current_cls = path_of(widget), cls
        last_item = clean(table.concat(gather(widget, 1) or {}, ", "))
    end
end

-- The hook itself only records the widget; all reading happens on the next dispatcher tick.
-- (Doing work inside UI hooks has crashed this game for other projects.)
RegisterHook("/Script/Phoenix.PhoenixUserWidget:ReadMenu", function(ctx)
    diag.trace("hook ReadMenu")
    local p = path_of(ctx:get())
    -- Raise the guard before queued world work can run. Do not inspect a widget tree here.
    if p and (p:find("LoadingScreen", 1, true) or p:find("UI_BP_PSO_FS", 1, true)) then
        state.mark_loading(6)
    end
    if p then dispatch.run(function()
        local widget = resolve(p)
        if widget then on_read_menu(widget) end
    end, "ReadMenu " .. (p:match("[^%.:]+$") or p),
        p:find("LoadingScreen", 1, true) ~= nil or p:find("UI_BP_PSO_FS", 1, true) ~= nil) end
end)

-- A finished map load also counts as loading for a few seconds (the new world settles).
-- Never RegisterLoadMapPreHook (UE4SS 3.0.1): its callback threw out of HookedLoadMap at the
-- game's first map load and crashed every start (Oct 8, 05:54 and 05:59; stack: HookedLoadMap,
-- LuaMod on_program_start lambda, Lua::call_function, std::runtime_error).
pcall(RegisterLoadMapPostHook, function()
    diag.trace("LoadMap finished")
    state.end_map_load()
    log("map loaded")
    -- Every screen read before the load belongs to the old map and may be freed: looking one
    -- up again (the help key, right after loading a save) crashed in StaticFindObject.
    dispatch.run(forget_screens, "forget screens", true)
end)

-- While a loading screen is still up, keep the "loading" flag raised; it lapses a few
-- seconds after the screen goes.
dispatch.every(1000, function()
    if not loading_screen then return end
    local w = resolve(loading_screen)
    local ok, up = pcall(function() return w and w:IsInViewport() end)
    if ok and up then state.mark_loading(4) else
        loading_screen = nil
        diag.event("loading", "loading screen gone")
    end
end, "loading screen watch", true)

-- Not every screen calls ReadMenu when focus moves, so also poll the most recently read
-- screen: its depth-1 strings are the focused item + hint, and change as focus moves.
dispatch.every(200, function()
    -- The previous screen is being torn down during a load: leave it alone.
    if state.loading() then current_screen = nil; return end
    -- In gameplay there's no menu to follow, and the last screen read (a tutorial prompt,
    -- a closed menu) may already be freed: polling it crashed the game while standing still.
    -- Menus opened from gameplay announce themselves through ReadMenu.
    if require("world").gameplay() then current_screen = nil; return end
    if require("world").ui_busy() then return end
    local w = resolve(current_screen)
    if not w then current_screen = nil; return end
    local item = clean(table.concat(gather(w, 1) or {}, ", "))
    if item == "" or item == last_item then pending_item = nil; return end
    -- Only announce a change that holds for two polls in a row: mid-transition reads
    -- mix the new page's title with the old page's sections.
    if item ~= pending_item then pending_item = item; return end
    pending_item = nil
    last_item = item
    -- Focus moved because the mod hovered something: the user already heard it.
    if os.clock() < capture_until then return end
    -- While typing in a text box, only the typed letters are spoken.
    if editing then return end
    log("focus " .. current_cls .. " -> " .. item)
    speak(item)
end)

-- The game only calls ReadMenu while its own Menu Reader is on, so turn it on with the
-- volume at zero: the game keeps announcing focus changes, silently, and NVDA speaks.
local function silence_native_reader()
    local ui = StaticFindObject("/Script/Phoenix.Default__UIManager")
    if ui and ui:IsValid() then
        local okV, rV = pcall(function() return ui:SetMenuReaderVolume(0.0) end)
        local okE, rE = pcall(function() return ui:SetMenuReaderEnabled(true) end)
        log("UIManager volume0 ok=" .. tostring(okV) .. " r=" .. tostring(rV) ..
            ", enable ok=" .. tostring(okE) .. " r=" .. tostring(rE))
    end
    local all = FindAllOf("PhoenixGameSettings")
    if not all then return false end
    for _, s in ipairs(all) do
        if not s:GetFullName():find("Default__") then
            pcall(function() s.MenuReaderVolume = 0.0 end)
            pcall(function() s.MenuReaderEnabled = true end)
            log("native reader on, volume 0 (" .. s:GetFullName() .. ")")
            return true
        end
    end
    return false
end

local tries = 0
dispatch.every(2000, function()
    tries = tries + 1
    return silence_native_reader() or tries >= 5
end)

-- ===== Screen review and clicking =========================================================
-- Walks the widget tree of the screen on top, collecting every visible piece of text and
-- every button in layout order. Keys (chosen to stay clear of NVDA and the game):
--   [ / ]              previous / next item        Shift+[ / Shift+]  previous / next button
--   \                  click the current item      '                  read the whole screen
--   Shift+'            copy screen text            ;                  help
-- Clicking fires the button's own blueprint click handler, so no mouse is involved.

local class_cache = {}
local function isa(w, path)
    local c = class_cache[path]
    if c == nil then
        c = StaticFindObject(path)
        if not (c and c:IsValid()) then c = false end
        class_cache[path] = c
    end
    if not c then return false end
    local ok, r = pcall(function() return w:IsA(c) end)
    return ok and r
end

local TEXTBLOCK  = "/Script/UMG.TextBlock"
local RICHTEXT   = "/Script/UMG.RichTextBlock"
local BUTTON     = "/Script/UMG.Button"
local CHECKBOX   = "/Script/UMG.CheckBox"
local SWITCHER   = "/Script/UMG.WidgetSwitcher"
local LEGENDITEM = "/Script/Phoenix.LegendItem"
local EDITABLE   = "/Script/UMG.EditableText"
local EDITBOX    = "/Script/UMG.EditableTextBox"
local USERWIDGET = "/Script/UMG.UserWidget"
local WIDGETTREE = "/Script/UMG.WidgetTree"

-- Widgets are read through their reflected properties wherever possible, not through game
-- functions: calling a function on a widget the game has just freed crashed the game in the
-- pause menu (Oct 6), while a property read is far more forgiving. Only text still comes
-- from GetText, since a text block's Text property can be stale when its text is bound.
-- ESlateVisibility: 0 Visible, 1 Collapsed, 2 Hidden, 3/4 hit-test invisible (still shown).
local function shown(w)
    local ok, vis = pcall(function() return w.Visibility end)
    if not ok or type(vis) ~= "number" or vis == 1 or vis == 2 then return false end
    local okO, op = pcall(function() return w.RenderOpacity end)
    if okO and type(op) == "number" and op < 0.05 then return false end
    return true
end

-- A panel's children, from its Slots array (each slot's Content), in order.
local function children_of(w)
    local out = {}
    pcall(function()
        w.Slots:ForEach(function(_, e)
            local slot = e:get()
            local c
            pcall(function() c = slot.Content end)
            if c then out[#out + 1] = c end
        end)
    end)
    return out
end

-- Breadcrumbs for walks started by a key press (not the pollers): if a game function call
-- ever crashes inside a walk again, the trace names the widget.
local walk_trace = false

-- The user widget that owns a widget (widget -> WidgetTree -> UserWidget).
local function owner_of(w)
    local tree, owner
    pcall(function() tree = w:GetOuter() end)
    if tree and tree:IsValid() and isa(tree, WIDGETTREE) then
        pcall(function() owner = tree:GetOuter() end)
    end
    if owner and owner:IsValid() then return owner end
    return nil
end

-- A button with no text inside it (icon tiles, swatches): ask the widgets around it.
local function cls_name(o)
    local n = "?"
    pcall(function() n = o:GetClass():GetFName():ToString() end)
    return n
end

local unlabelled_logged = {}

local function addr(o)
    local a
    pcall(function() a = o:GetAddress() end)
    return a
end

local function fname(o)
    local n = ""
    pcall(function() n = o:GetFName():ToString() end)
    return n
end

-- "Preset_9" -> "Preset 10", "SkinToneButton_0" -> "Skin Tone Button 1". Widget names
-- count from zero; people count from one.
local function humanize(n)
    n = n:gsub("_C$", "")
    local base, num = n:match("^(.-)_?(%d+)$")
    if base and base ~= "" then n = base .. " " .. (tonumber(num) + 1) end
    n = n:gsub("_", " "):gsub("(%l)(%u)", "%1 %2")
    return (n:gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", ""))
end

local function is_selected(o)
    local ok, v = pcall(function() return o.IsSelected end)
    return ok and v == true
end

-- Tab names learned from a screen's section heading while that tab is current,
-- keyed by screen class then tab index (1-based).
local learned_tabs = {}
local logged_title_keys = {}

-- "UI_CharacterCreator_Tab_Face" / "CC.Title.Complexion" -> "Face" / "Complexion"
local function title_from_key(k)
    k = tostring(k or "")
    local last = k:match("([^%._/:]+)$") or k
    last = last:gsub("^[Tt]itle", ""):gsub("^[Tt]ab", "")
    return humanize(last)
end

-- Tab buttons inside a category nav bar: name them from the bar's CategoryNames.
local function navbar_label(navbar, tile)
    local want, idx = addr(tile), nil
    pcall(function()
        navbar.CategoryButtons:ForEach(function(i, e)
            if not idx and addr(e:get()) == want then idx = i end
        end)
    end)
    if not idx then return nil end
    local name
    pcall(function()
        navbar.CategoryNames:ForEach(function(i, e)
            if i == idx then name = to_text(e:get()) end
        end)
    end)
    local named = name ~= nil and name ~= ""
    if not named then
        local screen = top_of(navbar)
        local scls = cls_name(screen)
        local learned = learned_tabs[scls] and learned_tabs[scls][idx]
        if learned then
            name, named = learned, true
        else
            local keys = {}
            pcall(function()
                screen.CustomizationPagesTitleKey:ForEach(function(i, e) keys[i] = to_text(e:get()) end)
            end)
            if not logged_title_keys[scls] and next(keys) then
                logged_title_keys[scls] = true
                local all = {}
                for i = 1, #keys do all[#all + 1] = tostring(keys[i]) end
                log("page title keys for " .. scls .. ": " .. table.concat(all, " | "))
            end
            local t = keys[idx] and title_from_key(keys[idx]) or ""
            if t ~= "" then name, named = t, true end
        end
    end
    if not named then name = "Tab " .. idx end
    local cur = -1
    pcall(function() cur = navbar.CurCategoryIndex end)
    if cur == idx - 1 then name = name .. ", current tab" end
    return name, named, idx
end

label_for = function(button)
    local tip = ""
    pcall(function() tip = clean(button.ToolTipText:ToString()) end)
    if tip ~= "" then return tip, {} end

    local o, chain = owner_of(button), {}
    local tile = o
    for _ = 1, 5 do
        if not o then break end
        local cn = cls_name(o)
        chain[#chain + 1] = cn
        if cn:find("CategoryNavBar", 1, true) then
            -- The bar's own arrow buttons.
            if o == owner_of(button) or addr(o) == addr(owner_of(button)) then
                local bn = fname(button)
                if bn:find("Left", 1, true) then return "Previous tab", { navarrow = "prev", navbar = o } end
                if bn:find("Right", 1, true) then return "Next tab", { navarrow = "next", navbar = o } end
            elseif tile then
                local t, named, idx = navbar_label(o, tile)
                if t then return t, { weak = not named, tab = true, tab_index = idx, tab_screen = cls_name(top_of(o)), navbar = o } end
            end
        end
        tile = o
        o = owner_of(o)
    end

    -- Picture tiles (face presets, swatches). Widgets made at runtime get names like
    -- UI_BP_Creator_Presets_C_2147455411, which mean nothing: number them among their
    -- siblings instead ("Preset 3 of 12"). Designer-named ones (Preset_9) read as named.
    local owner = owner_of(button)
    if owner then
        local n = fname(owner)
        local selected = is_selected(owner)
        if n:match("_C_%d%d%d%d%d+$") then
            local variant
            pcall(function() variant = owner.presetGender end)
            return nil, { weak = true, group = cls_name(owner), selected = selected, variant = variant }
        end
        if n:find("[Ss]lider") then return "Slider", { slider = true } end
        n = humanize(n)
        if n ~= "" and n ~= "None" then
            return n .. (selected and ", selected" or ""), {}
        end
    end

    local key = table.concat(chain, "<")
    if not unlabelled_logged[key] then
        unlabelled_logged[key] = true
        log("unlabelled button " .. fname(button) .. " owners: " .. key)
    end
    return "unlabelled", { weak = true }
end

-- "UI_BP_Creator_Presets_C" -> "Preset"
local function group_noun(cls)
    local n = cls:gsub("^UI_BP_", ""):gsub("_C$", ""):gsub("^Creator_", ""):gsub("^CharCreator_", "")
    n = humanize(n)
    if #n > 3 then n = n:gsub("s$", "") end
    return n ~= "" and n or "Option"
end

walk = function(w, items, label, depth)
    if not w or depth > 48 or not shown(w) then return end

    if isa(w, TEXTBLOCK) or isa(w, RICHTEXT) then
        local t = ""
        if walk_trace then diag.trace("walk text " .. fname(w)) end
        pcall(function() t = clean(w:GetText():ToString()) end)
        if t ~= "" then
            if label then label[#label + 1] = t
            else items[#items + 1] = { text = t } end
        end
        return
    end

    if isa(w, EDITABLE) or isa(w, EDITBOX) then
        if label then label.editable = w end
        return
    end

    if isa(w, LEGENDITEM) and not label then
        local disabled = false
        pcall(function() disabled = w.mDisabledState end)
        if disabled == true then return end
        local parts = {}
        local root
        pcall(function() root = w.WidgetTree.RootWidget end)
        if root then walk(root, {}, parts, depth + 1) end
        local action, hold = nil, 0
        pcall(function()
            local d = w.mLegendItemData
            action = d.CompletionButton
            if d.PressAndHold then hold = d.HoldDuration end
        end)
        if #parts > 0 or action then
            items[#items + 1] = { text = table.concat(legend_order(parts), ", "), action = action, hold = hold }
        end
        return
    end

    local is_button = (isa(w, BUTTON) or isa(w, CHECKBOX)) and not label
    local my_label = is_button and {} or label

    if isa(w, USERWIDGET) then
        local root
        pcall(function() root = w.WidgetTree.RootWidget end)
        if root then walk(root, items, my_label, depth + 1) end
    elseif isa(w, SWITCHER) then
        local idx = -1
        pcall(function() idx = w.ActiveWidgetIndex end)
        local active = children_of(w)[(tonumber(idx) or -1) + 1]
        if active then walk(active, items, my_label, depth + 1) end
    else
        for _, c in ipairs(children_of(w)) do walk(c, items, my_label, depth + 1) end
    end

    if is_button then
        local item = { button = w, checkbox = isa(w, CHECKBOX), editable = my_label.editable }
        if #my_label > 0 then
            item.text = table.concat(my_label, ", ")
            local owner = owner_of(w)
            if owner then
                local props = { "IsButtonSelected", "IsSelected", "currentlyActive", "bIsSelected" }
                -- Choice buttons (voice, difficulty, dormitory) mark the chosen one IsActive.
                -- Screens use a field with the same name, so only trust it on button widgets.
                if cls_name(owner):find("Button", 1, true) then props[#props + 1] = "IsActive" end
                for _, prop in ipairs(props) do
                    local ok, v = pcall(function() return owner[prop] end)
                    if ok and v == true then item.chosen = true; break end
                end
            end
        else
            local t, meta = label_for(w)
            item.text = t
            for k, v in pairs(meta) do item[k] = v end
        end
        items[#items + 1] = item
    end
end

-- Climb from any widget to the top-level screen that owns it.
top_of = function(w)
    local cur = w
    for _ = 1, 24 do
        local owner = owner_of(cur)
        if not owner or not isa(owner, USERWIDGET) then break end
        cur = owner
    end
    return cur
end

-- Recently read screens, most recent last, kept as object paths: a closed screen may be
-- freed by the game, and touching a freed object crashes inside UE4SS. Paths are resolved
-- again (StaticFindObject) whenever a screen is needed.
local screens = {}
note_screen = function(w)
    local top = top_of(w)
    -- Only real screens count; a nested widget announcing itself must not reset review.
    local ok, live = pcall(function() return top:IsInViewport() end)
    if not (ok and live) then return end
    local p = path_of(top)
    if not p then return end
    for i = #screens, 1, -1 do
        if screens[i] == p then table.remove(screens, i) end
    end
    screens[#screens + 1] = p
    if #screens > 12 then table.remove(screens, 1) end
end

-- The most recently read live screen, or, when we have none (e.g. right after a mod
-- reload), every top-level widget in the viewport.
local function current_tops()
    for i = #screens, 1, -1 do
        local s = resolve(screens[i])
        local ok, live = pcall(function() return s and s:IsInViewport() end)
        if ok and live then return { s }, s end
        table.remove(screens, i)
    end
    local all, tops = FindAllOf("UserWidget") or {}, {}
    for _, w in ipairs(all) do
        local ok, live = pcall(function() return w:IsInViewport() end)
        if ok and live then tops[#tops + 1] = w end
    end
    return tops, "viewport"
end

local review_items, review_index, review_top = {}, 0, nil
local review_title = "this screen"
local review_top_cls = nil   -- class of the screen on top at the last refresh

forget_screens = function()
    screens = {}
    current_screen = nil
    editing = nil
    review_items, review_index, review_top = {}, 0, nil
end

local logged_variants = {}
local function finish_labels(items)
    -- The heading above a tab bar names the current tab: remember it for later.
    for i, it in ipairs(items) do
        if it.tab and it.tab_index and it.text:find("current tab", 1, true) then
            for j = i - 1, 1, -1 do
                local h = items[j]
                if not h.button and not h.action and #h.text > 2 then
                    learned_tabs[it.tab_screen] = learned_tabs[it.tab_screen] or {}
                    if not learned_tabs[it.tab_screen][it.tab_index] then
                        learned_tabs[it.tab_screen][it.tab_index] = h.text
                        if it.weak then it.text = h.text .. ", current tab"; it.weak = false end
                    end
                    break
                end
            end
        end
    end
    -- Presets that come in variants (e.g. two body types) are numbered within each variant.
    local variants = {}
    for _, it in ipairs(items) do
        if it.group and it.variant ~= nil then
            variants[it.group] = variants[it.group] or {}
            variants[it.group][tostring(it.variant)] = true
        end
    end
    for g, vs in pairs(variants) do
        local list = {}
        for v in pairs(vs) do list[#list + 1] = v end
        if not logged_variants[g] then
            logged_variants[g] = true
            log("variants for " .. g .. ": " .. table.concat(list, ","))
        end
        if #list > 1 then
            for _, it in ipairs(items) do
                if it.group == g then it.group = g .. "#" .. tostring(it.variant) end
            end
        end
    end
    local heading
    for _, it in ipairs(items) do
        if not it.button and not it.action then heading = it.text; break end
    end
    -- Tiles are numbered within the section heading above them ("Face Shape 3 of 15",
    -- "Glasses 2 of 4"); sliders take their section's name too.
    local section = nil
    for _, it in ipairs(items) do
        if not it.button and not it.action and #it.text > 2 then section = it.text end
        it.section = section
        if it.group then it.group = it.group .. "|" .. tostring(section) end
        if it.slider then it.text = section and (section .. " slider") or "Slider" end
    end
    local totals, seen_n = {}, {}
    for _, it in ipairs(items) do
        if it.group then totals[it.group] = (totals[it.group] or 0) + 1 end
    end
    for _, it in ipairs(items) do
        if it.group then
            seen_n[it.group] = (seen_n[it.group] or 0) + 1
            local base, variant = it.group:gsub("|.*$", ""):match("^(.-)#(.*)$")
            base = base or it.group:gsub("|.*$", "")
            local desc = nil
            if base == "UI_BP_Creator_Presets_C" and heading == "Presets" and it.section == heading then
                desc = PRESET_DESCRIPTIONS[seen_n[it.group]]
            end
            local noun = (it.section and it.section ~= heading) and it.section or group_noun(base)
            it.text = noun .. " " .. seen_n[it.group] .. " of " .. totals[it.group] ..
                      (variant and (", style " .. (tonumber(variant) and tonumber(variant) + 1 or variant)) or "") ..
                      (desc and (": " .. desc) or "") ..
                      (it.selected and ", selected" or "")
        end
    end
    -- The tab bar draws its keys ("Q", "E") as lone letters beside the arrows.
    local i = 1
    while i <= #items do
        local it = items[i]
        if not it.button and not it.action and #it.text <= 2 then
            local prev, nxt = items[i - 1], items[i + 1]
            local arrow = (nxt and nxt.navarrow) and nxt or ((prev and prev.navarrow) and prev or nil)
            if arrow then
                arrow.text = arrow.text .. ", " .. it.text .. " key"
                table.remove(items, i)
                i = i - 1
            end
        end
        i = i + 1
    end
end

-- A screen made by the mod itself (e.g. the Controls menu) takes over the review keys while
-- it is open: { title = "...", items = function() return { {text=, button=, on_press=}, ... } end }
local virtual = nil

local refresh_busy = false
-- What a review key says when there's nothing to read: why, if the screen is mid-change.
local function nothing_to_read(msg)
    speak(refresh_busy and "The screen is changing. Try again in a moment." or msg)
end

local function refresh()
    if state.activity and not virtual then
        local provider = state.activity
        if review_top ~= provider then review_index = 0 end
        review_top, review_title, review_items = provider, provider.title, provider.items()
        return #review_items > 0
    end
    if virtual then
        local items = virtual.items()
        if review_top ~= virtual then review_index = 0 end
        review_top, review_items = virtual, items
        if review_index > #items then review_index = #items end
        return true
    end
    -- No widget walking while loading or in gameplay: old screens may be freed, and menus
    -- opened from gameplay close the world gate and announce themselves through ReadMenu.
    if state.loading() then review_items = {}; return false end
    if require("world").gameplay() then
        -- Read the copied tutorial text, never walk the HUD or a remembered widget tree.
        -- The tutorial system confirms that the same prompt is still displayed.
        local items, path = active_tutorial_items()
        if not items then review_items = {}; return false end
        if review_top ~= path then review_index = 0 end
        review_top, review_title, review_items = path, "Tutorial", items
        if review_index > #items then review_index = #items end
        return true
    end
    -- Nor while a screen is opening or closing: its widgets are being torn down.
    if require("world").ui_busy() then
        review_items = {}
        refresh_busy = true
        return false
    end
    refresh_busy = false
    local tops, top = current_tops()
    if #tops == 0 then review_items = {}; return false end
    local items = {}
    walk_trace = true
    diag.trace("walk screen " .. fname(top))
    for _, t in ipairs(tops) do walk(t, items, nil, 0) end
    walk_trace = false
    finish_labels(items)
    local top_key = type(top) == "userdata" and path_of(top) or top
    if top_key ~= review_top then
        -- Keep the user's place if the same item is still there under the new screen set.
        local prev = review_items[review_index]
        review_index = 0
        if prev then
            for i, it in ipairs(items) do
                if it.text == prev.text then review_index = i; break end
            end
        end
    end
    review_title = type(top) == "userdata" and humanize(cls_name(top):gsub("^UI_BP_", ""):gsub("_C$", "")) or "this screen"
    review_top_cls = type(top) == "userdata" and cls_name(top) or nil
    review_top, review_items = top_key, items
    if review_index > #items then review_index = #items end
    return true
end

-- A review key pressed with nothing picked: in the world that's no menu at all.
local function nothing_selected()
    if require("world").gameplay() then
        speak("No menu is open. " .. key_name("press") .. " presses menu buttons.")
    else
        speak("Nothing selected. Use " .. key_name("review_prev") .. " and " .. key_name("review_next") .. " to pick an item first.")
    end
end

local function describe(item)
    if item.checkbox then
        local on = false
        pcall(function() on = item.button.CheckedState == 1 end)
        return item.text .. ", checkbox, " .. (on and "checked" or "not checked")
    end
    if item.action then
        return item.text .. ", shortcut" .. (item.hold > 0 and ", hold" or "")
    end
    if item.editable then
        local v = ""
        pcall(function() v = item.editable:GetText():ToString() end)
        return item.text .. ", edit field, " .. (v ~= "" and v or "empty")
    end
    if item.button and item.chosen then return item.text .. ", selected, button" end
    return item.button and (item.text .. ", button") or item.text
end

local function hover(item)
    if not item.button or item.checkbox then return end
    local owner = owner_of(item.button)
    if not owner then return end
    local bname = fname(item.button)
    local fn
    pcall(function()
        owner:GetClass():ForEachFunction(function(f)
            local n = f:GetFName():ToString()
            if not fn and n:find("BndEvt__" .. bname .. "_K2Node_ComponentBoundEvent_", 1, true)
               and n:find("OnButtonHoverEvent", 1, true) then
                local idx = tonumber(n:match("ComponentBoundEvent_(%d+)_")) or 99
                if idx == 0 or not fn then fn = n end
            end
        end)
    end)
    if fn then pcall(function() owner[fn](owner) end) end
end

-- Give the game's keyboard focus to the item, so the game's own keys (Space, F...) act on what
-- was just read. A call on a widget of the screen that's open right now, after refresh has
-- checked the screen isn't changing.
local function focus(item)
    if not item.button then return end
    local ok, err = pcall(function() item.button:SetKeyboardFocus() end)
    if not ok then diag.trace("focus failed: " .. tostring(err)) end
end

local function select_item(i, edge, with_position, pos, total)
    editing = nil   -- moving the review cursor ends typing echo
    review_index = i
    local item = review_items[i]
    hover_details = {}
    capture_until = os.clock() + 0.8
    hover(item)
    if with_position then focus(item) end
    speak(describe(item) .. (edge and (", " .. edge) or "") ..
          (with_position and string.format(", %d of %d", pos or i, total or #review_items) or ""))
    if item.weak then
        dispatch.later(300, function()
            if review_items[review_index] ~= item then return end
            for _, t in ipairs(hover_details) do
                if t ~= "" and not t:find(item.text, 1, true) then speak(t, true); return end
            end
        end)
    end
end

-- Description / hover text for the current item: what the game showed when we hovered it,
-- else the button's tooltip, else whatever its widget tells the native reader at depth 2.
local function read_details()
    if not refresh() then nothing_to_read("No menu is open."); return end
    local item = review_items[review_index]
    if not item then speak("Nothing selected"); return end
    local seen_t, out = {}, {}
    for _, t in ipairs(hover_details) do
        if t ~= item.text and not seen_t[t] then seen_t[t] = true; out[#out + 1] = t end
    end
    if #out == 0 and item.button then
        local tip = ""
        pcall(function() tip = clean(item.button.ToolTipText:ToString()) end)
        if tip ~= "" then out[1] = tip end
    end
    if #out == 0 and item.button then
        local owner = owner_of(item.button)
        local parts = owner and gather(owner, 2)
        if parts and #parts > 0 then out[1] = clean(table.concat(parts, ", ")) end
    end
    speak(#out > 0 and table.concat(out, ". ") or "No description for this item")
end

local function step(delta, buttons_only, with_position)
    if not refresh() or #review_items == 0 then nothing_to_read("Nothing to read on this screen"); return end
    local i = review_index
    repeat
        i = i + delta
    until i < 1 or i > #review_items or not buttons_only or review_items[i].button or review_items[i].action
    if i < 1 or i > #review_items then
        if review_index >= 1 then select_item(review_index, delta < 0 and "top" or "bottom", with_position)
        else speak(buttons_only and "No buttons" or "Nothing to read") end
        return
    end
    select_item(i, nil, with_position)
end
-- The up and down arrows walk the screen's own list in menus (as in other access mods): its
-- buttons, checkboxes and fields, counted among themselves. Text, descriptions and shortcuts
-- stay on the review keys: counting them too gave the main menu "2 of 18", then "4 of 12", as
-- its details panel changed under each item (Matt, Oct 8). In the world the same keys turn
-- you, so path.lua hands them here whenever you're not in the world.
local function list_member(it)
    return (it.button ~= nil or it.checkbox or it.editable ~= nil) and not it.action
end
--- Where up/down (delta) go from review item `index`: the review index, its place in the list,
--- the list's length and "top"/"bottom" at an end; nil for a screen with no list.
local function list_target(items, index, delta)
    local list = {}
    for idx, it in ipairs(items) do if list_member(it) then list[#list + 1] = idx end end
    if #list == 0 then return nil end
    local here, target
    for k, idx in ipairs(list) do if idx == index then here = k end end
    if here then
        target = here + delta
    elseif delta > 0 then
        target = #list + 1
        for k, idx in ipairs(list) do if idx > index then target = k; break end end
    else
        target = 0
        for k = #list, 1, -1 do if list[k] < index then target = k; break end end
    end
    if target >= 1 and target <= #list then return list[target], target, #list, nil end
    local edge = delta < 0 and "top" or "bottom"
    local k = here or (delta < 0 and 1 or #list)
    return list[k], k, #list, edge
end
state.menu_step = function(delta)
    if not refresh() or #review_items == 0 then nothing_to_read("Nothing to read on this screen"); return end
    local i, pos, total, edge = list_target(review_items, review_index, delta)
    if not i then step(delta, false, true); return end   -- a screen of text: walk the text
    select_item(i, edge, true, pos, total)
end

-- Find the blueprint handler a widget class bound to a button's OnClicked. Its name looks
-- like BndEvt__<Button>_K2Node_ComponentBoundEvent_N_OnButtonClickedEvent__DelegateSignature.
local function bound_event(owner, button, kind)
    local bname = ""
    pcall(function() bname = button:GetFName():ToString() end)
    local found, fallback = nil, nil
    local cls
    pcall(function() cls = owner:GetClass() end)
    while cls and cls:IsValid() and not found do
        pcall(function()
            cls:ForEachFunction(function(fn)
                local n = fn:GetFName():ToString()
                if n:find(kind, 1, true) then
                    if n:find("BndEvt__" .. bname .. "_", 1, true) then found = n
                    elseif not fallback then fallback = n end
                end
            end)
        end)
        local super
        pcall(function() super = cls:GetSuperStruct() end)
        cls = super
    end
    return found or fallback
end

local function click_handler(owner, button) return bound_event(owner, button, "OnButtonClickedEvent") end

-- EUMGInputAction values used directly by the mod.
local ACTION_BACK = 1
local IE_PRESSED, IE_RELEASED = 0, 1

-- Feed a menu action into the game's UMG input manager, exactly as if its key was pressed.
local function send_action(action, hold)
    if state.loading() or require("world").gameplay() or require("world").ui_busy() then return false end
    local mgr = FindFirstOf("UMGInputManager")
    if not (mgr and mgr:IsValid()) then log("no UMGInputManager"); return false end
    local ok, err = pcall(function() mgr:OnInputAction(action, IE_PRESSED) end)
    if not ok then log("OnInputAction failed: " .. tostring(err)); return false end
    local function release()
        local fresh = FindFirstOf("UMGInputManager")
        pcall(function() if fresh and fresh:IsValid() then fresh:OnInputAction(action, IE_RELEASED) end end)
    end
    if hold and hold > 0 then
        dispatch.later(math.floor(hold * 1000) + 150, release)
    else
        dispatch.later(50, release)
    end
    log("sent action " .. tostring(action) .. (hold and hold > 0 and " (hold)" or ""))
    return true
end

-- Typing echo for edit fields: poll the field and speak what changed, like a screen reader.
local edit_text, edit_name, edit_unfocused, edit_seen_focus = "", "", 0, false
start_editing = function(item)
    editing, edit_name, edit_unfocused, edit_seen_focus = path_of(item.editable), item.text, 0, false
    edit_text = ""
    pcall(function() edit_text = item.editable:GetText():ToString() end)
    speak("Editing " .. item.text .. ". Type, then press Enter when you're done.")
end
dispatch.every(150, function()
    if not editing then return end
    if state.loading() or require("world").gameplay() then editing = nil; return end
    if require("world").ui_busy() then return end
    local w = resolve(editing)
    if not w then editing = nil; return end
    local v
    local ok = pcall(function() v = w:GetText():ToString() end)
    if not ok or v == nil then editing = nil; return end
    -- Enter (or clicking elsewhere) takes keyboard focus away: typing is finished.
    -- Only trust "not focused" once the box has been seen focused, in case this widget
    -- never reports keyboard focus at all.
    local okf, focused = pcall(function() return w:HasKeyboardFocus() end)
    if okf and focused == true then edit_seen_focus = true end
    if okf and focused == false and edit_seen_focus then
        edit_unfocused = edit_unfocused + 1
        if edit_unfocused >= 3 then
            editing = nil
            speak(edit_name .. ": " .. (v ~= "" and v or "empty"))
            return
        end
    else
        edit_unfocused = 0
    end
    if v == edit_text then return end
    if #v > #edit_text and v:sub(1, #edit_text) == edit_text then
        speak(v:sub(#edit_text + 1))                       -- typed characters
    elseif #v < #edit_text and edit_text:sub(1, #v) == v then
        speak(edit_text:sub(#v + 1))                       -- deleted characters
    else
        speak(v ~= "" and v or "empty")
    end
    edit_text = v
end)

local ACTION_TAB_LEFT, ACTION_TAB_RIGHT = 57, 58
local function switch_tab(item)
    local steps, action = 1, item.navarrow == "prev" and ACTION_TAB_LEFT or ACTION_TAB_RIGHT
    if item.tab then
        local cur
        pcall(function() cur = item.navbar.CurCategoryIndex end)
        if type(cur) ~= "number" then return false end
        local delta = (item.tab_index - 1) - cur
        if delta == 0 then speak(item.text); return true end
        steps, action = math.abs(delta), delta < 0 and ACTION_TAB_LEFT or ACTION_TAB_RIGHT
    end
    for i = 0, steps - 1 do
        dispatch.later(i * 250, function() send_action(action) end)
    end
    return true
end

local function click_current()
    local item = review_items[review_index]
    if not item then nothing_selected(); return end
    if item.on_press then item.on_press(); return end
    if item.action then
        if not send_action(item.action, item.hold) then speak("Could not use " .. item.text) end
        return
    end
    if not item.button then speak("That is text, not a button"); return end
    if (item.tab or item.navarrow) and item.navbar then
        if switch_tab(item) then return end
    end
    if item.checkbox then
        local ok = pcall(function() item.button:SetIsChecked(not item.button:IsChecked()) end)
        speak(ok and describe(item) or "Could not change that checkbox")
        return
    end
    if item.editable then start_editing(item) end
    local owner = owner_of(item.button)
    local fn = owner and click_handler(owner, item.button)
    if not fn then
        -- No Blueprint handler named after this button: fire the button's own OnClicked
        -- listeners natively (click_bridge, adapted from another access mod).
        if click_bridge then
            local okb, ok2, msg, n = pcall(click_bridge.broadcast_on_clicked, item.button:GetAddress())
            log("click " .. item.text .. " via OnClicked broadcast: " .. tostring(okb and ok2) ..
                " " .. tostring(msg) .. " (" .. tostring(n) .. " listeners)")
            if okb and ok2 then return end
        end
        log("no click handler for " .. item.text)
        speak("Sorry, I can't click " .. item.text .. " yet")
        return
    end
    local ok, err = pcall(function() owner[fn](owner) end)
    log("click " .. item.text .. " via " .. fn .. " ok=" .. tostring(ok) .. (ok and "" or (" " .. tostring(err))))
    if not ok then speak("Clicking " .. item.text .. " failed") end
end

-- Sliders and choice lists: hover the item so the game treats it as focused, then send the
-- game's own left/right navigation, then read back the new value.
local ACTION_LEFT, ACTION_RIGHT = 4, 5
local function adjust(delta)
    if not refresh() then nothing_to_read("No menu is open."); return end
    local item = review_items[review_index]
    if not item then nothing_selected(); return end
    local steps = math.abs(delta)
    local STEP_MS = 120   -- each nudge is a press and release; the game needs them apart
    -- The game re-reads the item as it changes; we announce the result ourselves.
    capture_until = os.clock() + 0.6 + steps * STEP_MS / 1000
    hover(item)
    local action = delta < 0 and ACTION_LEFT or ACTION_RIGHT
    if not send_action(action) then speak("Can't adjust that"); return end
    -- Big steps: repeat the nudge (sliders move 1% per step).
    for i = 1, steps - 1 do
        dispatch.later(i * STEP_MS, function() send_action(action) end)
    end
    local before = item.text
    dispatch.later(250 + steps * STEP_MS, function()
        if not refresh() then return end
        local now = review_items[review_index]
        if now and now.text ~= before then speak(describe(now))
        elseif now then speak(describe(now) .. ", unchanged") end
    end)
end

local function full_help()
    local groups, order = {}, {}
    for _, a in ipairs(keys.actions()) do
        if not a.id:find("^dev_") then
            if not groups[a.group] then groups[a.group] = {}; order[#order + 1] = a.group end
            table.insert(groups[a.group], keys.describe_combo(a.combo) .. ": " .. a.name)
        end
    end
    local t = {}
    for _, g in ipairs(order) do t[#t + 1] = g .. ". " .. table.concat(groups[g], ". ") end
    return "Wandsong keys. " .. table.concat(t, ". ") .. ". Change any key from the Controls menu."
end

-- Mod actions are declared with keys.action (rebindable; keys.lua runs them on the game thread).
local function act(id, name, default, run)
    keys.action{ id = id, name = name, group = "Menus and screens", default = default, run = run }
end

local function read_all()
    if not refresh() or #review_items == 0 then nothing_to_read("Nothing to read on this screen"); return end
    local t = {}
    for _, it in ipairs(review_items) do t[#t + 1] = describe(it) end
    speak(table.concat(t, ". "))
end

local function copy_all()
    if not refresh() or #review_items == 0 then nothing_to_read("Nothing to copy"); return end
    local t = {}
    for _, it in ipairs(review_items) do t[#t + 1] = it.text end
    speech.copy(table.concat(t, "\n"))
    speak("Screen text copied")
end

act("review_prev", "Previous item on screen", "[", function() step(-1, false) end)
act("review_next", "Next item on screen", "]", function() step(1, false) end)
act("review_prev_button", "Previous button or shortcut", "shift+[", function() step(-1, true) end)
act("review_next_button", "Next button or shortcut", "shift+]", function() step(1, true) end)
act("review_first", "First item on screen", "ctrl+[", function()
    if not refresh() or #review_items == 0 then nothing_to_read("Nothing to read on this screen"); return end
    select_item(1, "top")
end)
act("review_last", "Last item on screen", "ctrl+]", function()
    if not refresh() or #review_items == 0 then nothing_to_read("Nothing to read on this screen"); return end
    select_item(#review_items, "bottom")
end)
-- Never act on a stale selection: if the screen changed since the item was picked, say so
-- instead of pressing whatever now sits at that position.
local function press_current()
    if state.activity and not virtual and state.activity.press then state.activity.press(); return end
    local before, prev = review_top, review_items[review_index]
    if not refresh() then nothing_to_read("No menu is open."); return end
    local item = review_items[review_index]
    if review_top ~= before and not (item and prev and item.text == prev.text) then
        review_index = 0
        local first = review_items[1] and describe(review_items[1]) or "nothing readable yet"
        speak("The screen has changed, so I didn't press anything. It starts with: " .. first ..
              ". Use " .. key_name("review_prev") .. " and " .. key_name("review_next") .. " to look around.")
        return
    end
    click_current()
end

act("press", "Press, toggle or use the current item", "\\", press_current)
-- Enter presses too (Matt, Oct 8), except where the game takes Enter itself: finishing a typed
-- name, and its pop-ups and option panels, which confirm the focused button on Enter
-- (UMGOptionPanelConfirm), so pressing there as well would press twice.
act("press_enter", "Press the current item with Enter", "enter", function()
    if editing or require("world").gameplay() then return end
    if not refresh() then return end
    if review_top_cls and (review_top_cls:find("Popup", 1, true) or review_top_cls:find("OptionPanel", 1, true)) then return end
    press_current()
end)
act("back", "Go back", "shift+\\", function()
    if virtual then
        speak("Closed " .. virtual.title .. ".")
        virtual = nil
        review_index = 0
        return
    end
    if not send_action(ACTION_BACK) then speak("Could not go back") end
end)

-- Open a screen made by the mod (Controls, the sound legend) over whatever is showing.
local function open_screen(provider, what)
    virtual = provider
    review_index = 0
    refresh()
    speak(provider.title .. ", " .. #review_items .. " entries. " .. key_name("review_next") ..
          " to go through them, " .. key_name("press") .. " to " .. what .. ", " .. key_name("back") .. " to close.")
end
state.open_screen = open_screen
-- Close a mod screen without a key press (Places, before a journey starts).
state.close_screen = function()
    virtual = nil
    review_index = 0
end

local controls = require("controls")
local sounds = require("sounds")
act("controls", "Open the Controls menu (game and mod keys)", "ctrl+'", function()
    open_screen(controls, "change one")
end)
act("sounds", "Learn Wandsong's sounds", "ctrl+shift+'", function()
    open_screen(sounds, "hear it")
end)
act("decrease", "Decrease a slider or choice", "-", function() adjust(-1) end)
act("increase", "Increase a slider or choice", "=", function() adjust(1) end)
act("decrease_big", "Decrease a slider a lot", "shift+-", function() adjust(-10) end)
act("increase_big", "Increase a slider a lot", "shift+=", function() adjust(10) end)
act("read_all", "Read the whole screen", "'", read_all)
act("copy_all", "Copy the screen text to the clipboard", "shift+'", copy_all)
local last_help = -10
local function screen_name()
    return virtual and virtual.title or review_title
end

local function contextual_help()
    if os.clock() - last_help < 1.5 then last_help = -10; speak(full_help()); return end
    last_help = os.clock()
    if not refresh() or #review_items == 0 then
        if require("world").gameplay() then
            -- In the world the help key opens the guide to how the mod works.
            open_screen(require("guide"), "use it")
            return
        end
        speak("Nothing readable on screen right now. Press " .. key_name("help") .. " twice for all keys.")
        return
    end
    local buttons, shortcuts = 0, {}
    for _, it in ipairs(review_items) do
        if it.action then shortcuts[#shortcuts + 1] = it.text
        elseif it.button then buttons = buttons + 1 end
    end
    local t = { screen_name() .. ". " .. #review_items .. " items, " .. buttons .. " buttons." }
    if #shortcuts > 0 then t[#t + 1] = "Shortcuts: " .. table.concat(shortcuts, "; ") .. "." end
    local item = review_items[review_index]
    if item then
        t[#t + 1] = "Current: " .. describe(item) .. "."
        if item.action then t[#t + 1] = key_name("press") .. " uses this shortcut."
        elseif item.checkbox then t[#t + 1] = key_name("press") .. " toggles it."
        elseif item.button then t[#t + 1] = key_name("press") .. " presses it. " .. key_name("details") .. " for its description."
        else t[#t + 1] = "This is text." end
    else
        t[#t + 1] = key_name("review_prev") .. " and " .. key_name("review_next") .. " move through the screen."
    end
    t[#t + 1] = key_name("back") .. " goes back. Press " .. key_name("help") .. " twice for all keys."
    speak(table.concat(t, " "))
end

local repeat_depth, last_repeat = 0, -10
local function repeat_last()
    -- Press again quickly to go further back through what was said.
    if os.clock() - last_repeat < 1.5 then repeat_depth = repeat_depth + 1 else repeat_depth = 1 end
    last_repeat = os.clock()
    local t = speech.recent(repeat_depth + 1)   -- +1: skip whatever is being said right now
    if not t then repeat_depth = 0; t = speech.recent(2) end
    if t then speech.say(t) end
end

-- Developer aid (Ctrl+Shift+;): log the current item's widget chain with its true/false and
-- number fields, to find where a game keeps state like "selected". Reads only simple types.
local function dump_current()
    if not refresh() then speak("Nothing to dump"); return end
    local item = review_items[review_index]
    if not (item and item.button) then speak("Nothing to dump"); return end
    local o, depth = item.button, 0
    while o and depth < 4 do
        local line = {}
        pcall(function()
            local cls = o:GetClass()
            while cls and cls:IsValid() do
                cls:ForEachProperty(function(p)
                    local t = ""
                    pcall(function() t = p:GetClass():GetFName():ToString() end)
                    if t == "BoolProperty" or t == "IntProperty" or t == "ByteProperty" or t == "EnumProperty" then
                        local n = p:GetFName():ToString()
                        local ok, v = pcall(function() return o[n] end)
                        if ok and (type(v) == "boolean" or type(v) == "number") then
                            line[#line + 1] = n .. "=" .. tostring(v)
                        end
                    end
                end)
                cls = cls:GetSuperStruct()
            end
        end)
        log("dump " .. item.text .. " [" .. depth .. "] " .. cls_name(o) .. " " .. fname(o) .. ": " .. table.concat(line, " "))
        o = owner_of(o)
        depth = depth + 1
    end
    speak("Dumped to the log")
end

act("help", "Help for this screen; twice for all keys", ";", contextual_help)
act("dev_dump", "Developer: log the current item's fields", "ctrl+shift+;", dump_current)
-- Writes every class, property and function in the game to files beside the game's exe
-- (UE4SS_ObjectDump.txt and the CXXHeaderDump folder), for working out how to read things.
-- The game freezes for a minute or so while it runs.
act("dev_sdk", "Developer: dump all game classes and functions to files", "ctrl+shift+f12", function()
    speech.say("Dumping the game's classes. The game will freeze for a minute or two.")
    dispatch.later(1500, function()
        local t0 = os.clock()
        local ok1, e1 = pcall(DumpAllObjects)
        log("DumpAllObjects ok=" .. tostring(ok1) .. (ok1 and "" or (" " .. tostring(e1))))
        local ok2, e2 = pcall(GenerateSDK)
        log("GenerateSDK ok=" .. tostring(ok2) .. (ok2 and "" or (" " .. tostring(e2))))
        log(string.format("class dump took %.0f s", os.clock() - t0))
        speech.say((ok1 and ok2) and "Class dump finished." or "Class dump failed; it's in the log.")
    end, "class dump")
end)
-- F keys, not Ctrl: the game ignores modifiers and Left Ctrl is its Dodge. F1-F4 are the
-- game's spell sets; F5-F9 are free.
act("repeat", "Repeat what was said; again to go further back", "f7", repeat_last)
act("mute", "Turn Wandsong speech and sounds off or on", "f9", function() speech.toggle_mute() end)
act("guide", "The Wandsong guide and every key", "f6", function() open_screen(require("guide"), "use it") end)
act("details", "Description of the current item", "shift+;", read_details)


log("menus loaded")

-- For the offline text test.
return { legend_order = legend_order, rewrite = rewrite, clean = clean, list_target = list_target }
