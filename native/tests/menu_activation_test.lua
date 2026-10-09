-- A04: activating one button can never invoke a different button's Blueprint handler.
local t = dofile("native/tests/testlib.lua")
for k, v in pairs({ OEM_FOUR=219, OEM_SIX=221, OEM_FIVE=220, OEM_ONE=186, OEM_SEVEN=222,
                    OEM_MINUS=189, OEM_PLUS=187, RETURN=13, F11=122, F12=123 }) do Key[k] = v end
FindAllOf = function() return {} end
FindFirstOf = function() return nil end
StaticFindObject = function(path) return { IsValid=function() return true end, path=path } end
RegisterLoadMapPostHook = function() end
package.loaded.world = { gameplay=function() return false end, ui_busy=function() return false end }
local said, broadcasts, delegate_ready = {}, {}, true
require("speech").say = function(s) said[#said+1] = s end
package.loaded.click_bridge = {
    ready=function() return true, "test delegate" end,
    broadcast_on_clicked=function(address)
        broadcasts[#broadcasts+1] = address
        return delegate_ready, "test delegate", delegate_ready and 1 or 0
    end,
}
require("menus")
local function up(fn, wanted, replacement)
    for i=1,100 do
        local name, value = debug.getupvalue(fn, i)
        if not name then break end
        if name == wanted then
            if replacement ~= nil then debug.setupvalue(fn, i, replacement) end
            return value
        end
    end
    error("missing upvalue: " .. wanted)
end
-- The selection normally comes from the live widget walk. Supply only that boundary here;
-- exercise the real owner lookup, binding resolver and native-delegate fallback together.
local click = up(t.action("press"), "click_current")
local function fname(name) return { ToString=function() return name end } end
local function handler(name)
    return "BndEvt__" .. name .. "_K2Node_ComponentBoundEvent_0_OnButtonClickedEvent__DelegateSignature"
end
local function class(functions, parent)
    return {
        IsValid=function() return true end, GetSuperStruct=function() return parent end,
        ForEachFunction=function(_, visit)
            for _, name in ipairs(functions) do visit({GetFName=function() return fname(name) end}) end
        end,
    }
end
local deleted, continued = 0, 0
local owner = { IsValid=function() return true end }
owner[handler("DeleteSave")] = function() deleted=deleted+1 end
owner[handler("ContinueButton")] = function() continued=continued+1 end
local tree = { IsValid=function() return true end,
    IsA=function(_, cls) return cls.path == "/Script/UMG.WidgetTree" end, GetOuter=function() return owner end }
local function select(name)
    local button = { GetFName=function() return fname(name) end,
        GetAddress=function() return "address:" .. name end, GetOuter=function() return tree end }
    up(click, "review_items", {{ text=name, button=button }})
    up(click, "review_index", 1)
end

owner.GetClass = function() return class({handler("DeleteSave")}) end
select("ContinueButton"); click()
assert(deleted == 0 and continued == 0, "an unmatched Continue button never calls DeleteSave")
assert(broadcasts[#broadcasts] == "address:ContinueButton", "fallback broadcasts only the selected button's delegate")

delegate_ready = false
t.now=t.now+1
click()
assert(deleted == 0 and continued == 0, "a missing delegate invokes no unrelated action")
assert(said[#said]:find("ContinueButton", 1, true), "unavailable activation names the selected button")

owner.GetClass = function() return class({handler("DeleteSave"), handler("ContinueButton")}) end
local before = #broadcasts
click()
assert(continued == 1 and deleted == 0 and #broadcasts == before, "an exact binding activates once without a second broadcast")
select("DeleteSave"); click()
assert(deleted == 1, "another button still activates its own binding when deliberately selected")

owner.GetClass = function() return class({handler("DeleteSave")}, class({handler("ContinueButton")})) end
select("ContinueButton"); click()
assert(continued == 2 and deleted == 1, "the exact binding can be inherited")

owner.GetClass = function() return class({handler("ContinueButton_Other"), handler("DeleteSave")}) end
click()
assert(continued == 2 and deleted == 1, "a shared button-name prefix is not the selected button")
select(""); click()
assert(continued == 2 and deleted == 1, "an unnamed button cannot resolve an arbitrary handler")
print("menu activation test passed")
