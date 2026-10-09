-- Read-only: the parameters of the Sorting Hat screen's functions (reflection on the class
-- only), and the house widgets' classes, names and simple fields. For building the house
-- menu (Oct 9). No calls but IsInViewport.
--   powershell -ExecutionPolicy Bypass -File tools\dev.ps1 -File tools\probe_sorting_calls.lua
local out = {}
local function add(s) out[#out + 1] = s end
local w
for _, o in ipairs(FindAllOf("UI_BP_SortingHat_C") or {}) do
    local name = ""
    pcall(function() name = o:GetFullName() end)
    local up = false
    if name ~= "" and not name:find("Default__", 1, true) then pcall(function() up = o:IsInViewport() == true end) end
    if up then w = o end
end
if not w then return "no Sorting Hat screen up" end
local WANT = { HouseSelected = true, ShowHouseSelectedGraphics = true, SetSceneRigHouseSelection = true,
    ReturnToHouseSelection = true, BlueprintOnUMGInputAction = true, DetermineSuggestedHouse = true }
pcall(function()
    w:GetClass():ForEachFunction(function(f)
        local n = f:GetFName():ToString()
        if WANT[n] or n:find("OnHouseSelected", 1, true) or n:find("OnHouseHovered", 1, true) then
            local params = {}
            pcall(function()
                f:ForEachProperty(function(p)
                    local t = ""
                    pcall(function() t = p:GetClass():GetFName():ToString():gsub("Property$", "") end)
                    params[#params + 1] = p:GetFName():ToString() .. ":" .. t
                end)
            end)
            add(n .. "(" .. table.concat(params, ", ") .. ")")
        end
    end)
end)
local SIMPLE = { Bool = true, Int = true, Float = true, Byte = true, Enum = true }
for _, h in ipairs({ "Gryffindor", "Hufflepuff", "Ravenclaw", "Slytherin", "SelectedHouseButton" }) do
    pcall(function()
        local hw = w[h]
        local parts = { h }
        pcall(function() parts[#parts + 1] = hw:GetFullName() end)
        pcall(function() parts[#parts + 1] = "Visibility=" .. tostring(hw.Visibility) end)
        pcall(function()
            hw:GetClass():ForEachProperty(function(p)
                local t, n = "", p:GetFName():ToString()
                pcall(function() t = p:GetClass():GetFName():ToString():gsub("Property$", "") end)
                if SIMPLE[t] then pcall(function() parts[#parts + 1] = n .. "=" .. tostring(hw[n]) end)
                else parts[#parts + 1] = n .. ":" .. t end
            end)
        end)
        add(table.concat(parts, " | "))
    end)
end
pcall(function() add("WWHouse=" .. w.WWHouse:ToString()) end)
for _, t in ipairs({ "HouseName", "houseDescription", "houseInfoTitle", "houseInfoText" }) do
    pcall(function() add(t .. "=" .. w[t]:GetText():ToString()) end)
end
return table.concat(out, "\n")
