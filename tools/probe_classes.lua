-- Read-only: the property names and types of some loaded classes, from the classes themselves
-- (no object's values are read: reading every value of an actor crashed the game, Oct 8).
-- Edit CLASSES, then: powershell -ExecutionPolicy Bypass -File tools\dev.ps1 -File tools\probe_classes.lua
local CLASSES = { "M_INT_01_CP4_C", "BP_Intro_VoidColumn_B_C", "BP_AncientMagicHotSpot_C", "BP_INT_EventRelay_C" }
local out = {}
for _, cn in ipairs(CLASSES) do
    local inst, count = nil, 0
    for _, o in ipairs(FindAllOf(cn) or {}) do
        count = count + 1
        if not inst and not o:GetFullName():find("Default__", 1, true) then inst = o end
    end
    local names = {}
    pcall(function()
        local cls = inst and inst:GetClass()
        local depth = 0
        while cls and cls:IsValid() and depth < 3 do
            local cname = cls:GetFName():ToString()
            if cname == "Actor" or cname == "Object" then break end
            cls:ForEachProperty(function(p)
                local t = ""
                pcall(function() t = p:GetClass():GetFName():ToString():gsub("Property$", "") end)
                names[#names + 1] = p:GetFName():ToString() .. ":" .. t
            end)
            cls = cls:GetSuperStruct()
            depth = depth + 1
        end
    end)
    out[#out + 1] = cn .. " x" .. count .. ": " .. table.concat(names, ", ")
end
return table.concat(out, "\n")
