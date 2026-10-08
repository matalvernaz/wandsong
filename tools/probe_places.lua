-- The Places list as the mod would read it, read-only (nothing is pressed, nobody travels): the
-- unlocked Floo Flames and the map markers near you. The first names also go to the mod log
-- with their raw fields (BeaconLocName, BeaconName, location id), to check which field holds
-- the words the game's map shows. Run in the world:
--   powershell -ExecutionPolicy Bypass -File tools\dev.ps1 -File tools\probe_places.lua
local out = {}
for i, it in ipairs(require("places").items()) do
    if i > 25 then break end
    out[#out + 1] = it.text
end
return table.concat(out, "\n")
