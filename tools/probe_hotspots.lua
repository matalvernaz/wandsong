-- Ancient magic hotspots near you, read-only: whether each is active, whether the game counts
-- you inside its radii, and the radii themselves (cm). For a passive "in reach" cue: on Oct 8
-- F did nothing at the vault's gate hotspot from 2 m, and nothing tells a player when F works.
--   powershell -ExecutionPolicy Bypass -File tools\dev.ps1 -File tools\probe_hotspots.lua
local out = {}
local function get(o, name)
    local ok, v = pcall(function() return o[name] end)
    if ok and type(v) ~= "userdata" then return tostring(v) end
    return "?"
end
for _, o in ipairs(FindAllOf("AncientMagicHotSpot") or {}) do
    local full = "?"
    pcall(function() full = o:GetFullName() end)
    local x, y, z = "?", "?", "?"
    pcall(function()
        local l = o.RootComponent.RelativeLocation
        x, y, z = string.format("%.0f", l.X), string.format("%.0f", l.Y), string.format("%.0f", l.Z)
    end)
    out[#out + 1] = string.format("%s at %s %s %s: active %s, uses %s, inside hotspot %s inner %s outer %s collision %s; " ..
        "radius hotspot %s inner %s exit %s outer %s; discover ability %s",
        full:match("[^.:]+$") or full, x, y, z, get(o, "bHotSpotActive"), get(o, "NumberOfUses"),
        get(o, "bInsideHotSpotRadius"), get(o, "bInsideInnerRadius"), get(o, "bInsideOuterRadius"),
        get(o, "bInsideCollision"), get(o, "HotSpotRadius"), get(o, "InnerRadius"), get(o, "ExitInnerRadius"),
        get(o, "OuterRadius"), get(o, "bUseDiscoverAbility"))
end
local pawn = FindFirstOf("Biped_Player")
pcall(function()
    local l = pawn.RootComponent.RelativeLocation
    out[#out + 1] = string.format("player at %.0f %.0f %.0f", l.X, l.Y, l.Z)
end)
return #out > 0 and table.concat(out, "\n") or "no hotspots"
