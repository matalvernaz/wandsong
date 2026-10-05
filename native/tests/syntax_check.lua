local dir = "C:/claudeProjects/wandsong/mod/Wandsong/Scripts"
for _, f in ipairs({ "main", "diag", "dispatch", "speech", "keys", "menus", "controls", "scanner", "world", "creator_presets", "state", "sounds" }) do
    local fn, err = loadfile(dir .. "/" .. f .. ".lua")
    print((fn and "ok   " or "FAIL ") .. f .. (err and (": " .. err) or ""))
end
