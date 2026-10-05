-- Shared state between modules: things one module notices that another must respect.
local M = {}

-- Set while the game is loading (a loading screen is up) and for a short while after.
-- Nothing may touch world objects (actors, the player) during a load: they're being torn
-- down and rebuilt, and touching one mid-teardown crashes inside UE4SS.
M.loading_until = -1

function M.loading() return os.clock() < M.loading_until end

function M.mark_loading(seconds) M.loading_until = math.max(M.loading_until, os.clock() + (seconds or 10)) end

return M
