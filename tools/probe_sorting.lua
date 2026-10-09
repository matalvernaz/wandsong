-- Read-only: the Sorting Hat's house picker (UI_BP_SortingHat_C, Oct 9: Matt couldn't choose a
-- different house). Its class's functions and properties (reflection), and the values of its
-- simple properties (bool, int, float, byte, enum) on the screen that's up. No calls but
-- IsInViewport, as the mod makes on screens.
--   powershell -ExecutionPolicy Bypass -File tools\dev.ps1 -File tools\probe_sorting.lua
local out = {}
local function add(s) out[#out + 1] = s end
local w
for _, o in ipairs(FindAllOf("UI_BP_SortingHat_C") or {}) do
    local name = ""
    pcall(function() name = o:GetFullName() end)
    if name ~= "" and not name:find("Default__", 1, true) then
        local up = false
        pcall(function() up = o:IsInViewport() == true end)
        add("instance " .. name .. " in viewport " .. tostring(up))
        if up then w = o end
    end
end
if not w then add("no Sorting Hat screen up"); return table.concat(out, "\n") end
local SIMPLE = { Bool = true, Int = true, Float = true, Byte = true, Enum = true }
local cls = w:GetClass()
local depth = 0
while cls and cls:IsValid() and depth < 4 do
    local cname = cls:GetFName():ToString()
    if cname == "UserWidget" or cname == "Widget" or cname == "Object" then break end
    local fns, props = {}, {}
    pcall(function() cls:ForEachFunction(function(f) fns[#fns + 1] = f:GetFName():ToString() end) end)
    pcall(function()
        cls:ForEachProperty(function(p)
            local t, n = "", p:GetFName():ToString()
            pcall(function() t = p:GetClass():GetFName():ToString():gsub("Property$", "") end)
            local v = ""
            if SIMPLE[t] then pcall(function() v = "=" .. tostring(w[n]) end) end
            props[#props + 1] = n .. ":" .. t .. v
        end)
    end)
    add(cname .. " functions: " .. table.concat(fns, ", "))
    add(cname .. " properties: " .. table.concat(props, ", "))
    cls = cls:GetSuperStruct()
    depth = depth + 1
end
return table.concat(out, "\n")
