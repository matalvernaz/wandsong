-- The game's target as the mod sees it, read-only: the target's path and words, the targeting
-- mode (0 none, 1 auto target, 2 lock on) and the shield colours read from the dark wizards'
-- Protego spell (loaded once dark wizards are about). Run in a fight, locked on:
--   powershell -ExecutionPolicy Bypass -File tools\dev.ps1 -File tools\probe_target.lua
return require("target").report()
