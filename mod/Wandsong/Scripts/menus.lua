-- Menus: reads the game's menus through the player's screen reader, and lets them review
-- and press anything on screen.
--
-- Every Phoenix menu widget implements GatherMenuReaderStrings(depth), which returns the
-- text the native reader would speak. The game calls ReadMenu(depth, ...) on a widget
-- whenever that widget wants to be read (focus moved, screen opened). We post-hook
-- ReadMenu, gather the strings ourselves and hand them to the speech module.

local speech = require("speech")

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
        return (k:gsub("_", " "))
    end)
    -- Mouse prompts become the mod's own key: Backslash clicks the reviewed item.
    t = t:gsub('<img%s+src="cbi_Mouse_LeftClick"%s*/>', "Backslash")
    t = t:gsub('<img%s+src="cbi_Mouse_([^"]+)"%s*/>', function(k)
        return "mouse " .. (k:gsub("_", " "))
    end)
    t = t:gsub('<img%s+src="([^"]+)"%s*/>', function(k)
        return (k:gsub("^cbi_", ""):gsub("_", " "))
    end)
    t = t:gsub("<[^>]->", "")          -- any other rich-text tag
    t = t:gsub("%s+", " ")
    return (t:gsub("^%s+", ""):gsub("%s+$", ""))
end

-- Depth 0 = whole screen (title + focused item + hint), 1 = focused item + hint.
-- The hooked depth argument arrives as garbage, so pick our own: full context the first
-- time a widget instance reads, the shorter item text after that.
local note_screen   -- defined in the screen review section below

-- Feed a menu action into the game's UMG input manager (press then release).
local function send_action_early(action)
    local mgr = FindFirstOf("UMGInputManager")
    if not (mgr and mgr:IsValid()) then return false end
    local ok = pcall(function() mgr:OnInputAction(action, 0) end)
    ExecuteWithDelay(50, function()
        ExecuteInGameThread(function() pcall(function() mgr:OnInputAction(action, 1) end) end)
    end)
    return ok
end
local label_for
local seen = {}
local last_screen_time = -10
local capture_until, hover_details = -10, {}
local quiet_class, quiet_until = nil, -10
local current_screen, current_cls, last_item = nil, "?", ""

RegisterHook("/Script/Phoenix.PhoenixUserWidget:ReadMenu", function(ctx)
    local widget = ctx:get()
    local key, cls = "?", "?"
    pcall(function() key = widget:GetFullName() end)
    pcall(function() cls = widget:GetClass():GetFName():ToString() end)

    local first = not seen[key]
    seen[key] = true
    local parts = gather(widget, first and 0 or 1)
    if (not parts or #parts == 0) and not first then parts = gather(widget, 0) end
    local text = clean(table.concat(parts or {}, ", "))
    log("ReadMenu " .. cls .. (first and " [open] " or " ") .. "-> " .. text)
    -- A whole screen interrupts; small widgets reading themselves right after a screen
    -- (often just whatever the parked mouse pointer is over) queue behind it.
    local is_screen = false
    pcall(function() is_screen = widget:IsInViewport() end)

    -- First launch: the Accessibility screen ignores everything until its Menu Reader
    -- toggle is pressed. Press it for the player and tell them where they are.
    if cls == "UI_BP_FirstFlowAccessibility_C" and text:find("Menu Reader, Off", 1, true) then
        log("first-launch accessibility screen: enabling menu reader for the player")
        ExecuteWithDelay(300, function()
            ExecuteInGameThread(function() send_action_early(70) end)
        end)
        quiet_class, quiet_until = cls, os.clock() + 3
        speak("Welcome to Hogwarts Legacy, with Wandsong. This is the first-time Accessibility " ..
              "Options screen; I've switched the game's menu reader on for you so it unlocks. " ..
              "Use the bracket keys to look through the settings, backslash to change one, " ..
              "and F to continue. Semicolon for help at any time.")
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
        else
            speak(text, os.clock() - last_screen_time < 2.0)
        end
    end

    note_screen(widget)
    -- Only whole screens are polled for focus changes; small widgets (description panels,
    -- single buttons) would just repeat themselves.
    if is_screen then
        current_screen, current_cls = widget, cls
        last_item = clean(table.concat(gather(widget, 1) or {}, ", "))
    end
end)

-- Not every screen calls ReadMenu when focus moves, so also poll the most recently read
-- screen: its depth-1 strings are the focused item + hint, and change as focus moves.
LoopAsync(200, function()
    ExecuteInGameThread(function()
        local w = current_screen
        if not w then return end
        local okV, valid = pcall(function() return w:IsValid() end)
        if not okV or not valid then current_screen = nil; return end
        local item = clean(table.concat(gather(w, 1) or {}, ", "))
        if item ~= "" and item ~= last_item then
            last_item = item
            -- Focus moved because the mod hovered something: the user already heard it.
            if os.clock() < capture_until then return end
            log("focus " .. current_cls .. " -> " .. item)
            speak(item)
        end
    end)
    return false
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
LoopAsync(2000, function()
    tries = tries + 1
    local done = false
    ExecuteInGameThread(function() done = silence_native_reader() end)
    return done or tries >= 5
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
local USERWIDGET = "/Script/UMG.UserWidget"
local WIDGETTREE = "/Script/UMG.WidgetTree"

local function shown(w)
    local ok, vis = pcall(function() return w:IsValid() and w:IsVisible() end)
    if not ok or not vis then return false end
    local okO, op = pcall(function() return w:GetRenderOpacity() end)
    if okO and type(op) == "number" and op < 0.05 then return false end
    return true
end

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
    if not name or name == "" then name = "Tab " .. idx end
    local cur = -1
    pcall(function() cur = navbar.CurCategoryIndex end)
    if cur == idx - 1 then name = name .. ", current tab" end
    return name
end

label_for = function(button)
    local tip = ""
    pcall(function() tip = clean(button:GetToolTipText():ToString()) end)
    if tip ~= "" then return tip end

    local o, chain = owner_of(button), {}
    local tile = o
    for _ = 1, 5 do
        if not o then break end
        local cn = cls_name(o)
        chain[#chain + 1] = cn
        if cn:find("CategoryNavBar", 1, true) and tile then
            local t = navbar_label(o, tile)
            if t then return t end
        end
        tile = o
        o = owner_of(o)
    end

    -- Picture tiles (face presets, swatches): use the widget's own name and state.
    local owner = owner_of(button)
    if owner then
        local n = humanize(fname(owner))
        if n ~= "" and n ~= "None" then
            return n .. (is_selected(owner) and ", selected" or "")
        end
    end

    local key = table.concat(chain, "<")
    if not unlabelled_logged[key] then
        unlabelled_logged[key] = true
        log("unlabelled button " .. fname(button) .. " owners: " .. key)
    end
    return "unlabelled"
end

local function walk(w, items, label, depth)
    if not w or depth > 48 or not shown(w) then return end

    if isa(w, TEXTBLOCK) or isa(w, RICHTEXT) then
        local t = ""
        pcall(function() t = clean(w:GetText():ToString()) end)
        if t ~= "" then
            if label then label[#label + 1] = t
            else items[#items + 1] = { text = t } end
        end
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
            items[#items + 1] = { text = table.concat(parts, ", "), action = action, hold = hold }
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
        local active
        pcall(function() active = w:GetActiveWidget() end)
        if active then walk(active, items, my_label, depth + 1) end
    else
        local n = 0
        pcall(function() n = w:GetChildrenCount() end)
        for i = 0, (n or 0) - 1 do
            local c
            pcall(function() c = w:GetChildAt(i) end)
            if c then walk(c, items, my_label, depth + 1) end
        end
    end

    if is_button then
        local t = #my_label > 0 and table.concat(my_label, ", ") or label_for(w)
        items[#items + 1] = { text = t, button = w,
                              checkbox = isa(w, CHECKBOX) }
    end
end

-- Climb from any widget to the top-level screen that owns it.
local function top_of(w)
    local cur = w
    for _ = 1, 24 do
        local owner = owner_of(cur)
        if not owner or not isa(owner, USERWIDGET) then break end
        cur = owner
    end
    return cur
end

local screens = {}   -- most recent last
note_screen = function(w)
    local top = top_of(w)
    -- Only real screens count; a nested widget announcing itself must not reset review.
    local ok, live = pcall(function() return top:IsInViewport() end)
    if not (ok and live) then return end
    local a = addr(top)
    for i = #screens, 1, -1 do
        if addr(screens[i]) == a then table.remove(screens, i) end
    end
    screens[#screens + 1] = top
    if #screens > 12 then table.remove(screens, 1) end
end

-- The most recently read live screen, or, when we have none (e.g. right after a mod
-- reload), every top-level widget in the viewport.
local function current_tops()
    for i = #screens, 1, -1 do
        local s = screens[i]
        local ok, live = pcall(function() return s:IsValid() and s:IsInViewport() end)
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

local function refresh()
    local tops, top = current_tops()
    if #tops == 0 then review_items = {}; return false end
    local items = {}
    for _, t in ipairs(tops) do walk(t, items, nil, 0) end
    if addr(top) ~= addr(review_top) then
        -- Keep the user's place if the same item is still there under the new screen set.
        local prev = review_items[review_index]
        review_index = 0
        if prev then
            for i, it in ipairs(items) do
                if it.text == prev.text then review_index = i; break end
            end
        end
    end
    review_top, review_items = top, items
    if review_index > #items then review_index = #items end
    return true
end

local function describe(item)
    if item.checkbox then
        local on = false
        pcall(function() on = item.button:IsChecked() end)
        return item.text .. ", checkbox, " .. (on and "checked" or "not checked")
    end
    if item.action then
        return item.text .. ", shortcut" .. (item.hold > 0 and ", hold" or "")
    end
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

local function select_item(i, edge)
    review_index = i
    local item = review_items[i]
    hover_details = {}
    capture_until = os.clock() + 0.8
    hover(item)
    speak(describe(item) .. (edge and (", " .. edge) or ""))
end

-- Description / hover text for the current item: what the game showed when we hovered it,
-- else the button's tooltip, else whatever its widget tells the native reader at depth 2.
local function read_details()
    local item = review_items[review_index]
    if not item then speak("Nothing selected"); return end
    local seen_t, out = {}, {}
    for _, t in ipairs(hover_details) do
        if t ~= item.text and not seen_t[t] then seen_t[t] = true; out[#out + 1] = t end
    end
    if #out == 0 and item.button then
        local tip = ""
        pcall(function() tip = clean(item.button:GetToolTipText():ToString()) end)
        if tip ~= "" then out[1] = tip end
    end
    if #out == 0 and item.button then
        local owner = owner_of(item.button)
        local parts = owner and gather(owner, 2)
        if parts and #parts > 0 then out[1] = clean(table.concat(parts, ", ")) end
    end
    speak(#out > 0 and table.concat(out, ". ") or "No description for this item")
end

local function step(delta, buttons_only)
    if not refresh() or #review_items == 0 then speak("Nothing to read on this screen"); return end
    local i = review_index
    repeat
        i = i + delta
    until i < 1 or i > #review_items or not buttons_only or review_items[i].button or review_items[i].action
    if i < 1 or i > #review_items then
        if review_index >= 1 then select_item(review_index, delta < 0 and "top" or "bottom")
        else speak(buttons_only and "No buttons" or "Nothing to read") end
        return
    end
    select_item(i)
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
    local mgr = FindFirstOf("UMGInputManager")
    if not (mgr and mgr:IsValid()) then log("no UMGInputManager"); return false end
    local ok, err = pcall(function() mgr:OnInputAction(action, IE_PRESSED) end)
    if not ok then log("OnInputAction failed: " .. tostring(err)); return false end
    local function release()
        ExecuteInGameThread(function()
            pcall(function() mgr:OnInputAction(action, IE_RELEASED) end)
        end)
    end
    if hold and hold > 0 then
        ExecuteWithDelay(math.floor(hold * 1000) + 150, release)
    else
        ExecuteWithDelay(50, release)
    end
    log("sent action " .. tostring(action) .. (hold and hold > 0 and " (hold)" or ""))
    return true
end

local function click_current()
    local item = review_items[review_index]
    if not item then speak("Nothing selected. Use the bracket keys to pick an item first."); return end
    if item.action then
        if not send_action(item.action, item.hold) then speak("Could not use " .. item.text) end
        return
    end
    if not item.button then speak("That is text, not a button"); return end
    if item.checkbox then
        local ok = pcall(function() item.button:SetIsChecked(not item.button:IsChecked()) end)
        speak(ok and describe(item) or "Could not change that checkbox")
        return
    end
    local owner = owner_of(item.button)
    local fn = owner and click_handler(owner, item.button)
    if not fn then
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
    refresh()
    local item = review_items[review_index]
    if not item then speak("Nothing selected. Use the bracket keys to pick an item first."); return end
    local steps = math.abs(delta)
    local STEP_MS = 120   -- each nudge is a press and release; the game needs them apart
    -- The game re-reads the item as it changes; we announce the result ourselves.
    capture_until = os.clock() + 0.6 + steps * STEP_MS / 1000
    hover(item)
    local action = delta < 0 and ACTION_LEFT or ACTION_RIGHT
    if not send_action(action) then speak("Can't adjust that"); return end
    -- Big steps: repeat the nudge (sliders move 1% per step).
    for i = 1, steps - 1 do
        ExecuteWithDelay(i * STEP_MS, function() ExecuteInGameThread(function() send_action(action) end) end)
    end
    local before = item.text
    ExecuteWithDelay(250 + steps * STEP_MS, function()
        ExecuteInGameThread(function()
            refresh()
            local now = review_items[review_index]
            if now and now.text ~= before then speak(describe(now))
            else speak(describe(item) .. ", unchanged") end
        end)
    end)
end

local HELP = "Wandsong keys. Left and right bracket: previous and next item on screen. " ..
             "Shift with left and right bracket: previous and next button or shortcut. Backslash: press the current item. " ..
             "Shift backslash: go back. Control with left and right bracket: first and last item. " ..
             "Minus and equals: decrease and increase a slider or choice; add shift for bigger steps. " ..
             "Apostrophe: read the whole screen. Shift apostrophe: copy the screen text to the clipboard. " ..
             "F9: scan your surroundings, when in the world. Semicolon: help for this screen, twice for this list. " ..
             "Shift semicolon: description of the current item. Control semicolon: repeat what was last said, " ..
             "press again to go further back. Control backslash: turn Wandsong speech off or on."

local function on_key(fn) return function() ExecuteInGameThread(fn) end end
local function bind(key, mods, fn)
    local ok, err
    if mods then ok, err = pcall(RegisterKeyBind, key, mods, on_key(fn))
    else ok, err = pcall(RegisterKeyBind, key, on_key(fn)) end
    if not ok then log("bind failed: " .. tostring(err)) end
end

local function read_all()
    if not refresh() or #review_items == 0 then speak("Nothing to read on this screen"); return end
    local t = {}
    for _, it in ipairs(review_items) do t[#t + 1] = describe(it) end
    speak(table.concat(t, ". "))
end

local function copy_all()
    if not refresh() or #review_items == 0 then speak("Nothing to copy"); return end
    local t = {}
    for _, it in ipairs(review_items) do t[#t + 1] = it.text end
    speech.copy(table.concat(t, "\n"))
    speak("Screen text copied")
end

bind(Key.OEM_FOUR,  nil, function() step(-1, false) end)                  -- [
bind(Key.OEM_SIX,   nil, function() step(1, false) end)                   -- ]
bind(Key.OEM_FOUR,  { ModifierKey.SHIFT }, function() step(-1, true) end) -- {
bind(Key.OEM_SIX,   { ModifierKey.SHIFT }, function() step(1, true) end)  -- }
bind(Key.OEM_FOUR,  { ModifierKey.CONTROL }, function()                  -- Ctrl+[
    if not refresh() or #review_items == 0 then speak("Nothing to read on this screen"); return end
    select_item(1, "top")
end)
bind(Key.OEM_SIX,   { ModifierKey.CONTROL }, function()                  -- Ctrl+]
    if not refresh() or #review_items == 0 then speak("Nothing to read on this screen"); return end
    select_item(#review_items, "bottom")
end)
bind(Key.OEM_FIVE,  nil, function() refresh(); click_current() end)                                   -- \
bind(Key.OEM_FIVE,  { ModifierKey.SHIFT }, function()                     -- |
    if not send_action(ACTION_BACK) then speak("Could not go back") end
end)
bind(Key.OEM_MINUS, nil, function() adjust(-1) end)                       -- -
bind(Key.OEM_PLUS,  nil, function() adjust(1) end)                        -- =
bind(Key.OEM_MINUS, { ModifierKey.SHIFT }, function() adjust(-10) end)    -- _
bind(Key.OEM_PLUS,  { ModifierKey.SHIFT }, function() adjust(10) end)     -- +
bind(Key.OEM_SEVEN, nil, read_all)                                        -- '
bind(Key.OEM_SEVEN, { ModifierKey.SHIFT }, copy_all)                      -- "
local last_help = -10
local function screen_name()
    local top = review_top
    if type(top) ~= "userdata" then return "this screen" end
    local n = cls_name(top):gsub("^UI_BP_", ""):gsub("_C$", "")
    return humanize(n)
end

local function contextual_help()
    if os.clock() - last_help < 1.5 then last_help = -10; speak(HELP); return end
    last_help = os.clock()
    if not refresh() or #review_items == 0 then
        speak("Nothing readable on screen right now. Press semicolon twice for all keys.")
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
        if item.action then t[#t + 1] = "Backslash uses this shortcut."
        elseif item.checkbox then t[#t + 1] = "Backslash toggles it."
        elseif item.button then t[#t + 1] = "Backslash presses it. Shift semicolon for its description."
        else t[#t + 1] = "This is text." end
    else
        t[#t + 1] = "Use the bracket keys to move through the screen."
    end
    t[#t + 1] = "Shift backslash goes back. Press semicolon twice for all keys."
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

bind(Key.OEM_ONE,   nil, contextual_help)                                 -- ;
bind(Key.OEM_ONE,   { ModifierKey.CONTROL }, repeat_last)                 -- Ctrl+;
bind(Key.OEM_FIVE,  { ModifierKey.CONTROL }, function() speech.toggle_mute() end)  -- Ctrl+\
bind(Key.OEM_ONE,   { ModifierKey.SHIFT }, read_details)                  -- :


log("menus loaded")
