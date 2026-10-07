-- Runtime files live with the mod; offline tests redirect all of them to a sandbox.
local M = {}
local source = debug.getinfo(1, "S").source:gsub("^@", ""):gsub("\\", "/")
M.scripts = source:match("^(.*)/[^/]+$") or "."
M.mod = M.scripts:match("^(.*)/[^/]+$") or "."
M.test_dir = os.getenv("WANDSONG_TEST_DIR")
function M.runtime(name, in_scripts)
    return (M.test_dir or (in_scripts and M.scripts or M.mod)) .. "/" .. name
end
function M.input()
    if M.test_dir then return M.test_dir .. "/Input.ini" end
    return (os.getenv("LOCALAPPDATA") or "") .. "/Hogwarts Legacy/Saved/Config/WindowsNoEditor/Input.ini"
end
return M
