-- Read-only: is a movie playing (the Pensieve memory in the vault showed as gameplay, its
-- subtitles never reached BPAddSubtitleEvent, Oct 9)? Property reads only: Bink players and
-- their URLs, the game's media widgets, Bink scene actions, the subtitle widget's standalone
-- flag and the player's cinematic flag.
--   powershell -ExecutionPolicy Bypass -File tools\dev.ps1 -File tools\probe_movie.lua
local out = {}
local function add(s) out[#out + 1] = s end
local function live(o)
    local name = ""
    pcall(function() name = o:GetFullName() end)
    return name ~= "" and not name:find("Default__", 1, true), name
end
local function str(v)
    local s
    pcall(function() s = v:ToString() end)
    return s or tostring(v)
end
for _, cls in ipairs({ "BinkMediaPlayer", "UI_BP_MediaWidget_C", "BP_SceneAction_PlayBink_C", "UI_BP_Subtitle_C" }) do
    local n = 0
    pcall(function()
        for _, o in ipairs(FindAllOf(cls) or {}) do
            local ok, name = live(o)
            if ok and n < 8 then
                n = n + 1
                local parts = { cls, name }
                pcall(function() parts[#parts + 1] = "URL=" .. str(o.URL) end)
                pcall(function() parts[#parts + 1] = "BinkURL=" .. str(o.BinkURL) end)
                pcall(function() parts[#parts + 1] = "VideoShown=" .. tostring(o.VideoShown) end)
                pcall(function() parts[#parts + 1] = "PlayRequested=" .. tostring(o.PlayRequested) end)
                pcall(function() parts[#parts + 1] = "Visibility=" .. tostring(o.Visibility) end)
                pcall(function() parts[#parts + 1] = "bStandaloneSubtitle=" .. tostring(o.bStandaloneSubtitle) end)
                pcall(function() parts[#parts + 1] = "StartTime=" .. tostring(o.StartTime) end)
                add(table.concat(parts, " | "))
            end
        end
    end)
    if n == 0 then add(cls .. ": none live") end
end
-- The cinematic scene actions' own player (an asset, as long-lived as the game): one call.
pcall(function()
    local mp = StaticFindObject("/Game/Cinematics/SceneActions/PlayBinkMedia/MP_PlayBinkMedia.MP_PlayBinkMedia")
    if mp and mp:IsValid() then
        add("MP_PlayBinkMedia IsPlaying=" .. tostring(mp:IsPlaying()) .. " URL=" .. str(mp.URL))
    else
        add("MP_PlayBinkMedia not loaded")
    end
end)
pcall(function()
    for _, p in ipairs(FindAllOf("Biped_Player") or {}) do
        local ok, name = live(p)
        if ok then add("player " .. name .. " InCinematic=" .. tostring(p.InCinematic) .. " bHidden=" .. tostring(p.bHidden)) end
    end
end)
return table.concat(out, "\n")
