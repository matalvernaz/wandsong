-- Scripts folder, found from this file's own path (native/tests/ -> mod/Wandsong/Scripts).
local here = (debug.getinfo(1, "S").source:gsub("^@", ""):gsub("\\", "/"):match("^(.*)/[^/]+$")) or "."
local dir = here .. "/../../mod/Wandsong/Scripts"
local failed = false
for _, f in ipairs({ "main", "diag", "dispatch", "speech", "keys", "menus", "controls", "scanner", "world", "surroundings", "path", "gamecues", "creator_presets", "state", "sounds", "tips", "guide", "subtitles", "descriptions", "files", "bindings", "feedback", "spells", "statues", "ai_walk", "combat", "hotspots", "markers", "target", "places", "gamesettings" }) do
    local fn, err = loadfile(dir .. "/" .. f .. ".lua")
    print((fn and "ok   " or "FAIL ") .. f .. (err and (": " .. err) or ""))
    if not fn then failed = true end
end
if failed then error("Lua syntax check failed") end
