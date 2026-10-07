-- The first check of the AI walk, before switching it on: spawns an AI controller, lets it
-- take the player's character, hands the character straight back and destroys the controller,
-- without moving anything. Run in gameplay, standing still, with nobody else at the keyboard:
--   powershell -ExecutionPolicy Bypass -File tools\dev.ps1 -File tools\probe_ai_walk.lua
-- All three "ok" (and the player able to move afterwards) means the AI walk may be switched on
-- by creating ai_walk_enabled.txt in the mod folder. Details in the mod log ("ai walk").
return require("ai_walk").probe()
