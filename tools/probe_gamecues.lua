-- The game's own audio cues this session, read-only: whether the HUD switched them on (it calls
-- ActivateAudioCues when it's built with the setting on), which cue sources fired and how
-- often, and what the HUD's cue panel showed last. Run in gameplay, after a few minutes of play
-- (sneaking past someone, a fight, picking something up):
--   powershell -ExecutionPolicy Bypass -File tools\dev.ps1 -File tools\probe_gamecues.lua
-- "never activated" after a load means the setting didn't take; events all zero while the
-- panel shows icons means the game raises its cues from C++, where the hooks can't see them.
return require("gamecues").report()
