-- Copy to the installed mod's dev_eval.lua, then press Ctrl+Shift+F11 DURING a lesson.
-- Read-only snapshot. NEVER register hooks from dev_eval: UE4SS retains the transient Lua
-- thread, which can be collected before the event runs (Oct 7, 06:46 crash).
-- spells.lua registers its event hooks at startup instead.
local result = {}
local function read(key, fn)
    local ok, value = pcall(fn)
    result[key] = ok and tostring(value) or ("error: " .. tostring(value))
end
for _, widget in ipairs(FindAllOf("SpellMiniGameBase") or {}) do
    local full = widget:GetFullName()
    if not full:find("Default__", 1, true) then
        result.screen = full
        read("waiting", function() return widget:GetIsWaitingForStart() end)
        read("active", function() return widget:GetIsMiniGameActive() end)
        read("name", function() return widget:GetMiniGameName():ToString() end)
        read("inputWindow", function() return widget:GetIsInInputWindow() end)
        read("checkpoint", function() return widget:GetCurrentCheckpointData().InputAction end)
        read("spark", function() return widget.PlayerSpark:GetFullName() end)
        read("progress", function() return widget.PlayerSpark:GetTotalDistanceAsPercent() end)
        read("direction", function()
            local d = widget.PlayerSpark:GetDirection()
            return d.X .. "," .. d.Y
        end)
        read("segment", function()
            local d = widget.PlayerSpark:GetCurrentPathSegment()
            return d.StartPoint.X .. "," .. d.StartPoint.Y .. " to " .. d.EndPoint.X .. "," .. d.EndPoint.Y
        end)
    end
end
return result
