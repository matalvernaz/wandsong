-- The deletion record in the game. It runs only with lifetime_enabled.txt in the mod folder
-- (created before the game starts). Run in gameplay, any time:
--   powershell -ExecutionPolicy Bypass -File tools\dev.ps1 -File tools\probe_lifetime.lua
-- "deletions the engine reported" above 0 (it grows with each garbage collection, about once a
-- minute) means the engine calls the listener; "holding" above 0 means the world keeps the
-- objects its passes found; "dropped as deleted" counts objects the record caught before
-- anything touched them. The same line is in the mod log every 10 seconds.
return require("world").lifetime_report()
