# Roadmap: into the world (2026-10-02)

Built from the lessons of other access mods. Goal:
free exploration first (Swamp / A Hero's Call style); being guided or walked is always opt-in.

## 0. Stability first (before real time in the world)

1. One game-thread dispatcher: a single LoopAsync drains a task queue inside one
   ExecuteInGameThread call. Key binds and delays only queue work. (A lesson from another access mod: each
   ExecuteInGameThread call allocates a lua_State racily.)
2. Keep the ReadMenu hook trivial: record widget, class and time; gather and speak on the
   next dispatcher tick. (Read-only UI hooks have crashed this game.)
3. Gameplay gate: UIManager IsInPreGameplayState / IsAsyncScreenLoadInProgress /
   GetInMenuTransition / InPauseMode plus a valid BP_Biped_Player_C pawn, stable for 5 polls.
   World features stay off while it's closed. Cutscene check too.
4. World change: when the UWorld (or pawn) address changes, drop every cached object.
5. Crash fuse: write the risky feature's name to a file before a risky call and clear it
   after; a feature left in the file at boot is disabled and announced. Breadcrumbs in the log.
6. No full object sweeps, no NotifyOnNewObject, no load-map hooks, no UE4SS calls in
   coroutines, no hot reload while playing.

## Milestones

- M1 Text layer: tutorials, prompts, objectives, notifications, speaker names. Polling with
  two-poll stability and change-only announcements. Subtitles default to "speaker on change"
  (dialogue is voiced), with off and full-text modes.
- M2 Scanner v2: categories, background refresh one class per tick (~3 s, 50 m), fresh
  positions per key press, distance to interaction point or bounds centre, students and ghosts
  as people, floors ("above"/"below"), stable ids. Keys: PageUp/PageDown item,
  Ctrl+PageUp/PageDown category, Home repeat, End beacon.
- M3 3D beacon: XAudio2 native module (own thread; Lua pushes positions ~10/s). Tick rate for
  distance, pan, lower pitch behind, arrival chime.
- M4 Walls and orientation: navmesh probes (vector ProjectPointToNavigation) in 8 directions
  at 1, 3, 6 m, played as panned tones (comma). LineTrace only behind the fuse, one ray, after
  50 safe calls. Facing as compass words (period).
- M5 Guidance, then autowalk: navmesh path followed by the beacon waypoint by waypoint;
  opt-in AIController autowalk (Shift+End) with the proven restore order, any key cancels.
- M6 Combat: enemy beacons within 20 m, lock-on target spoken, incoming-attack warnings
  (probe UIAccessibilityManager and the warning indicator).
- M7 Map and fast travel: review cursor on the map, then a list of discovered Floo points.

## Keys to avoid in the world

NVDA: Insert, Caps Lock, numpad. Game: WASD, F, R, Q, E, Tab, M, J, N, L, I, T, H, O, U, Y,
P, F10, Escape, 1-4, Space, Shift, Ctrl; C, X, V, G, Z, B, K until verified free. Menus keep
[ ] \ - = ' ;.

## Risks

Struct out-param reflection calls (LineTrace, K2_ variants); cutscenes with a valid pawn;
voiced dialogue colliding with speech (queue the text layer, interrupt only for player
actions); FindAllOf cost in dense areas like Hogsmeade; game updates renaming classes (watch
the unclassified-class log).
