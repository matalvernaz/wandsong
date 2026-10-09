# Wandsong: working notes for picking this up anywhere

Blind accessibility mod for Hogwarts Legacy (Steam, appid 990080), written for and with Matt,
who is blind and plays with NVDA. Repo: matalvernaz/wandsong. If private/NOTES.md exists (the
maintainer's private working notes and notebook, a separate private repo cloned there), read it
first. Then this file and docs/ROADMAP.md (the plan, based on a reference access mod for another
game, the design Matt chose).

Current handoff: the reliability update was implemented away from the game PC. Read
[docs/TESTING_ON_GAME_PC.md](docs/TESTING_ON_GAME_PC.md) before deploying or changing it.
Offline Windows/Linux tests pass; actual game verification remains outstanding. Do not
confuse earlier game observations with proof that this revision fixes the freezes or steps.

October 9 audit fixes: [docs/AUDIT_FIXES-2026-10-09.md](docs/AUDIT_FIXES-2026-10-09.md)
tracks both implementation batches (A01-A20, all fixed offline) and the game checks still
needed. Installer changes use `installer/src/file_transaction.h`: checked staging,
original-file ownership, a flushed rollback journal, loader disabled during replacement,
and verified recovery before cleanup.
Uninstall keeps unrecorded player settings/logs. Never remove backup or transaction files
by hand to bypass a recovery error. `tools/test_setup_failures.py` tests failure/retry only
in private temporary fake games; CI runs it alongside `tools/test_setup.ps1`.

## Goal and design rules (from Matt; non-negotiable)

- Exploration first, Swamp / A Hero's Call style. Guided play is opt-in only. "A game where
  I'm guided through only experiencing a tenth of it is just how I already live."
- Zero-key world: walking around should convey the world passively through sound (objective
  beacon, walls and openings, nearby things, enemies, stuck detection). Keys are only for
  optional detail. Push back on any feature that needs a key to be useful.
- Every game instruction is spoken in the mod's terms using the real current bindings (never
  "click"). All screen text must be re-readable piece by piece. Every button needs a keyboard
  route. Laptop users may have no mouse: the no-mouse preset covers that.
- One unified, accessible Controls menu for game and mod keys, everything remappable. Matt
  has no Right Ctrl. Avoid Insert, Caps Lock and the number pad (NVDA owns them).
- No mod sounds in cutscenes. Native screen-reader speech via Prism, easy first-time setup.

## Naming

- Don't name other accessibility mods, their projects or their authors anywhere in this
  repo (code, comments, docs, commit messages). Keep the ideas; say "other access mods"
  or "the reference mod". Audio games (Swamp, A Hero's Call) aren't mods and may be named.
- Code adapted from another access mod's author is used with their permission and credited,
  unnamed, in README.

## Machine setup

1. Hogwarts Legacy from Steam. Game folder: `...\steamapps\common\Hogwarts Legacy\Phoenix\Binaries\Win64`
   (exe HogwartsLegacy.exe, UE 4.27.2).
2. Tools: Visual Studio 2022 Build Tools (C++), CMake, GitHub CLI (`gh auth login`), Python 3,
   LLVM for crash symbols (`winget install LLVM.LLVM`).
3. Build everything and the release zip (fetches Prism v0.18.3 and UE4SS v3.0.1 into third_party/):
   ```
   powershell -ExecutionPolicy Bypass -File tools\build_release.ps1 -Version 0.4.0
   ```
   It writes dist\WandsongSetup-<version>.exe: one file, the setup (installer/src/main.cpp,
   a console program read by screen readers, SAPI voice when none runs) with UE4SS and the mod
   appended ("HWAPACK1" footer; dist\payload is what it carries). It finds Steam or Epic copies,
   says what's installed (Mods\Wandsong\version.txt; dev deploys write "dev <hash>"), and
   Enter installs or updates: files the old record lists in the mod folder but the new version
   lacks are removed, player files are never touched. --check changes nothing. Test it only
   against fake game folders: `powershell -File tools\test_setup.ps1`. Interactive setups
   (and --check) ask GitHub for the latest release; a newer one is downloaded, checked against
   its published .sha256 and run with --install. Publish with tools\publish_release.ps1.
4. UE4SS settings that matter (ue4ss/UE4SS-settings.ini is the template): EngineVersionOverride
   4 / 27, GuiConsoleEnabled = 0, bUseUObjectArrayCache = false, only Keybinds plus
   Wandsong enabled in mods.txt. Without these the game crashes early.
5. Dev loop: close the game normally, edit, test, build the input module and deploy:
   ```
   powershell -ExecutionPolicy Bypass -File tools\update_for_testing.ps1
   ```
   Start the game normally afterwards. `deploy.ps1 -Native` copies all prebuilt DLLs for a
   full native rebuild. The update helper only rebuilds the input DLL changed by this update.
   Add new modules to the list in
   native\tests\syntax_check.lua.
6. Crash forensics: `powershell -File tools\fetch_symbols.ps1` once, then after a crash:
   ```
   python tools\symbolize_crash.py symbols
   ```
7. Game class dump (gitignored sdk/): in the game press Ctrl+Shift+F12, then copy
   Win64\UE4SS_ObjectDump.txt and Win64\CXXHeaderDump into sdk\. Phoenix.hpp is the game's
   native code. Takes about 3 seconds.

If Steam insists the game is still running: shut Steam down, set
HKCU\Software\Valve\Steam RunningAppID to 0, start Steam again.

## Diagnostics (read these first after any problem)

In the game's Mods\Wandsong\ folder:
- Wandsong.log: every mod message, timestamped and flushed per line. Starts with the
  previous session's last trace lines, so after a crash the new log shows how it ended.
- trace.log: breadcrumbs written just before each task and risky step. The last line before a
  crash is what the mod was doing. Previous sessions: *.prev.log.
- Matt can press F8 to mark a moment ("PLAYER MARK" plus the last three utterances).
- Game crash reports: %LOCALAPPDATA%\Hogwarts Legacy\Saved\Crashes\ (decode with the symbolizer).
- Win64\UE4SS.log also has everything, including every spoken line ("[Wandsong] say ...").
- UE4SS writes its own dumps (Win64\crash_*.dmp) with a "Fatal Error!" dialog; the game's
  reporter writes Saved\Crashes. Symbolize UE4SS frames with llvm-symbolizer on
  symbols\UE4SS.dll. Windows' Application log (event 1000/1001) catches the rest.
- No keys needed to inspect the live game: `powershell -File tools\dev.ps1 -File <probe.lua>`
  hands the script to the mod (dev_request.lua), which runs it on the game thread within a
  second (never during loads) and writes dev_result.txt. Probes: tools\probe_statues.lua,
  tools\probe_spell_sampler.lua, tools\probe_lifetime.lua, tools\probe_gamecues.lua,
  tools\probe_target.lua, tools\probe_places.lua. Probes must follow the rules below (a probe that called
  IsValid on a closed screen crashed the game). Never register hooks from a probe.

## Architecture (mod/Wandsong/Scripts)

- main.lua: load order (diag first), mark key (F8), ready message.
- diag.lua: log and trace files; wraps print so every module's log lands in the file.
- dispatch.lua: the one game-thread dispatcher (run, later, every), throttled to 100 ms through
  persistent Blueprint ReceiveTick/Tick hooks. At most one ExecuteInGameThread fallback is
  pending when Blueprint ticks stop; nothing else calls ExecuteInGameThread. Tasks are
  labelled, timed, get tracebacks; per-task Lua allocation totals; stall watch ("game thread
  hasn't run the mod for 8 s" in trace.log); call_out(fn, out_table) frees the registry ref
  UE4SS leaks for an out parameter. The version-checked 3.0.1 fallback frees its exact leaked
  function reference. While state.loading(), only during_load tasks run; obsolete queued
  work and delayed world tasks are discarded across load generations. Likewise while the
  game, having ticked, hasn't for 0.3 s (dispatch.ticking() false; world.in_game() too).
- state.lua: loading generation (every load mark, menus' screen loads included), world
  counter (map loads and a new player object only: objects of an earlier world are never
  looked up), cinematic scene, pause state, modal tutorial, mod screen, recent cues.
  files.lua: runtime paths and isolated test settings. bindings.lua: startup snapshot of
  active game keys, separate from next-launch changes written to Input.ini; conflict() counts
  both and says which; same_key() compares UE4SS and Unreal key names by virtual key.
- speech.lua: Prism in-process (prism_bridge.dll), helper exe fallback; history, mute, copy.
- keys.lua: every key x 4 modifier sets registered once; actions declared by modules,
  rebindable, saved in keys.ini (only once the player changes one); key observers.
- menus.lua: ReadMenu hook (game's Menu Reader on at volume 0), widget-tree review cursor
  (property reads only, plus GetText), labels, clicks, tabs, edit fields, loading screens, mod
  screens (controls, sounds, guide). Text fixes: legend_order (action before key), REWRITES
  (mouse and sight instructions in the mod's terms), loading tips once. Modal tutorials set
  state.modal_since. Returns legend_order/rewrite/clean for native/tests/text_test.lua.
- controls.lua: unified Controls menu over the game's Input.ini; no-mouse preset; automatic
  screen-reader fix (game actions only on Caps Lock/Insert/numpad move; LockOn -> Period).
  Conflict checks include the base game key even with modifiers, plus movement axes.
- sounds.lua: sound legend. guide.lua: the in-world guide (help key in the world).
  tips.lua: one-time tips remembered in tips_seen.txt (welcome, first enemy, hop/climb/drop).
- world.lua: world things are snapshots from scan passes (one FindAllOf, every property read
  in that tick, readers added with world.on_scan); nothing looks a world actor up by path
  between passes, and a thing its pass stops returning is dropped at once. Passes alternate
  all characters (one NPC_Character query, sorted with IsA) and the next static class. With
  lifetime_enabled.txt (off by default): passes also hold what they find, watched by the
  deletion record (lifetime_bridge.dll), a 200 ms refresh re-reads the nearest 24 (record
  first, then IsValid, then position and readers), and the character pass slows to every 2.5
  to 3.6 s when no enemy or puzzle knight is about. world.lifetime_report() for its counts.
- world.lua (older notes): gameplay gate (UIManager state, modal tutorial via TutorialSystem
  .CurrentTutorialScreen, pawn, cutscene); rotating scan, one class per tick (people, enemies,
  creatures, chests, collectibles, doors, usable objects), kept to 40 m, with names
  (OverrideCharacterID, DefaultWorldID, GetCharacterID once per character, else the cleaned
  class name); 3D ambient sounds via audio_bridge.dll; crash fuse (world_active.flag); status
  and memory reports. API: in_game, enabled, ui_busy, not_ready_reason, entries, locate,
  nearest, position, pawn. Shift+F5 only mutes sounds; it does not close the gameplay gate.
  Films (Content\Movies\FMV: the Pensieve memories, seasons, credits) play with the player's
  InCinematic off: the gate also asks the cinematic Bink player (MP_PlayBinkMedia:IsPlaying,
  an asset) and counts a film as a scene, believed for 15 minutes at most. The Sorting Hat's
  house screen is a menu (ui_blocker "sorting") while state.sorting_path is in the viewport.
  Shift+F8 separately resumes crash-paused world features. Gate settling uses elapsed time.
- surroundings.lua: footsteps, landing, blocked bump; 16 wall rays (LineTraceSingle on the
  Kismet CDO, through dispatch.call_out) grouped into at most 4 wall loops; side openings;
  terrain(): knee, waist and head rays plus down rays give hop (jumpable), climb (ledge 1-3 m)
  and drop (two checks, both trace channels) cues, once per spot, with a lined-up tick.
  Grave accent = "what was that".
- path.lua: the route is the game's PathTS / GuidePathPoints; else the mission destination (a
  moving one is followed along its trail, footprint by footprint; a standing one is walked up
  to within 1.7 m); else the nearest person (autowalk only); else, for a fixed objective, the
  engine's navmesh path (NavigationSystemV1 FindPathToLocationSynchronously, behind the
  nav_active.flag fuse). The beacon pings 8 m along it. Autowalk (Shift+grave) turns the camera
  with relative mouse moves (input_bridge.mouse_move, sensitivity learned from
  ControlRotation), holds the actual forward key, holds the actual jump key for 650 ms when
  blocked, refuses during tutorials. Arrival and route/trail geometry include height; net
  ascent counts as progress but bouncing in place does not renew the jump budget. Fixed
  scanner targets query the navmesh and report failed/partial paths. Also walk_to and
  face_to (scanner), comma faces the nearest enemy, arrows turn 45/90/180, up arrow says facing,
  objective direction and the tracked quest task (MissionManager GetMissionLogDataBP).
- scanner.lua: Page Down/Up, Home (re-announce and turn to face), Shift+Page Down/Up
  categories (empty skipped; "Quest objective" is its own category), Shift+Home walk to it,
  Shift+F9 dump to scan_dump.txt. Reads world.entries(); positions fresh each read.
- gamesettings.lua: the game's own accessibility settings, switched with PhoenixGameSettings'
  setters and SaveSettings (as its Accessibility menu does). Audio cues (AudioVisualizer, the
  real switch, plus AccessibilityAudioCueOpacity) at every start unless switched off on the
  Controls screen (game_settings.txt cues=off); subtitles, minimap path line, target names and
  highlights, objective markers once per ONCE_VERSION (game_settings.txt once=N), said aloud;
  spell toggle, sprint/walk toggle, camera aiming only from the Controls screen. Logs all values
  at every start. There is no "track current target" setting (a cut option).
- gamecues.lua: the game's accessibility audio cues (its deaf-player visualizer). Hooks the
  UIAccessibilityManager Trigger* functions and MapSubSystem:TriggerAccessibility (only if they
  exist), logs ActivateAudioCues/DeactivateAudioCues, logs the HUD cue panel's shape
  (BP_HUD_Audio_C.CuePanel). Reactions: "Spotted!", beast aware, hit direction (spoken), loot
  (item sound). The game's own cue producers are mostly C++ (UAblPostAccessibilityAudioCueTask),
  which RegisterHook can't see: the hooks may stay quiet (tools/probe_gamecues.lua tells).
- target.lua: the game's own target. Hooks the HUD widget's SetCurrentTargetActor (path only);
  name from the HUD's NPCHealthMeter.TargetName; lock-on (controller TargetingMode 2) says name
  and shield, auto-target changes tick from the target; End adds it. Shield type per enemy from
  a world.on_scan reader (EnemyAIComponent.ProtegoDefenseLevel); type colours from
  Default__BP_ProtegoSpell_DW_C.DWShieldEffectData effect names; colour to spell kind is the
  players' rule (unverified). tools/probe_target.lua.
- places.lua: F11 in the world. Unlocked Floo Flames and map markers near you from MapSubSystem's
  per-category UBeaconInfo lists (property reads); Floo travel with FastTravelManager
  StartFastTravelUsingID(id, 1, 0) after its checks, two presses; other markers set the game's
  route (BP_PathNavigationManager_C SetBeaconPathTarget). Names through feedback.translate.
  tools/probe_places.lua reads the list without pressing anything.
- sorting.lua: the Sorting Hat's house screen (UI_BP_SortingHat_C) as a mod screen of the four
  houses in the game's words, starting on the hat's suggestion and naming the Wizarding World
  house; two presses (15 s) choose. The screen listens to Confirm, Back and Accept (F) only; a
  different house needs its crest clicked. HouseStateIndex: 0 opening view (never accepted
  there), 1 all crests, 2 picked; Back goes 0 to 1, 1 to 2, 2 to 1. The mod sends Back, runs
  the crest's own BndEvt__UI_BP_SortingHat_<crest>_..._OnHouseSelected, then Accept (75) only
  if NewHouse is the house chosen. tools/probe_sorting.lua and probe_sorting_calls.lua read it.
- feedback.lua: event-based HUD interaction prompts, health/potion values, half/critical
  health announcements and different block/dodge warning pitches. End reads gauges. Hooks
  record values/paths only; prompt properties are read fresh during settled gameplay.
  Events are derived from the public SDK and still need verification on this game build.
- spells.lua: spell lessons (USpellMiniGameBase). Announces the lesson (the symbol's arrows and
  the first checkpoint's key when known). Started with the game's own Space it's traced by ear:
  strokes named by the arrows a curve turns through, a moment early; held arrows/WASD within
  67.5 degrees of the path (here, just behind or just ahead) make the wand follow the stroke;
  each checkpoint's key named before its window, the chime meaning now; after a miss, what went
  wrong. The press key instead starts the tracing assistance, which steers along the current
  segment with relative mouse moves and presses each checkpoint's action through
  UMGInputManager. The symbol comes from OnPathSplineSet or is recorded as the spark runs.
  Measured dynamics and Matt's first attempt: the private notebook.
- statues.lua: the vault's knight-statue puzzles as an audio puzzle (Matt: equivalent audio
  puzzles, never walked around for the player). Each visible puzzle knight sounds a bell note;
  while the player's own light leads its reflection, a second note follows, pitched by how far
  the reflection is turned from the knight's facing (unison = lined up, said once from the
  light's bearing). Hint lines hum when stood on. Home on a knight in the scanner describes its
  facing and its reflection's. Knights are read by a world.on_scan reader inside the scan
  pass and never looked up afterwards. Logs puzzle events and snapshots.
- ai_walk.lua: when key-driven autowalk is stuck, an AI controller (spawned with the
  GameplayStatics deferred-spawn functions) possesses the character, MoveToLocation walks it
  on the navmesh, and the character is handed back in a fixed order on every way out. OFF
  unless ai_walk_enabled.txt exists in the mod folder; run tools/probe_ai_walk.lua (spawn,
  possess, hand back, destroy, without moving) once in game, supervised, before switching it on.
- subtitles.lua: one persistent BPAddSubtitleEvent hook, short duplicate-delivery window,
  replayable descriptions, cancellation on skip/new line/load/scene exit, pause-aware delays.
  Descriptions cut by a load carry to the next scene only without a menu just before the
  load, a menu after it or another load (the title card goes on; a loaded save doesn't).
  Films' lines come as standalone subtitles (BPAdd/UpdateStandaloneSubtitle), text only.
- native/: prism_bridge.c, click_bridge.cpp, audio_bridge.cpp (synthesized sounds, including
  hop, climb, ledge; stop_all stops one-shots already playing, playing() counts them),
  input_bridge.c (key, mouse_move, focused), lifetime_bridge.cpp (the
  deletion record: a delete listener registered through UE4SS.dll's exports; watch, alive,
  forget, clear, stats), static Lua 5.4.4 (UE4SS 3.0.1's version), luahost test runner. helper/ and installer/ are the fallback speech exe and setup.
- native/tests/: 49 checks including syntax, startup, controls, registry cleanup, dispatcher,
  navigation, scanner, subtitles, HUD feedback and the gameplay gate. Run `python tools/run_tests.py`
  from the repo root on Windows/Linux. Each test gets its own temporary runtime/config folder;
  the runner rejects dispatcher task errors as well as process failures. GitHub Actions also
  builds the Windows input DLL and parses both deployment scripts.

## Hard-won rules (each one cost a crash)

- Never keep UObjects between ticks, except through the deletion record: never use a held
  wrapper (not even IsValid) until lifetime.alive(address, serial) says it hasn't been deleted
  since it was found, and without the record running, never hold one. Otherwise keep the path
  (GetFullName minus class) and re-resolve with StaticFindObject each time. UE4SS 3.0.1's
  IsValid dereferences before checking, so IsValid on a stale wrapper crashes (the private notebook,
  "Holding objects between ticks").
- Don't call UFunctions (ProcessEvent) on world actors: read reflected properties instead
  (RootComponent.RelativeLocation, Controller.ControlRotation, pawn.InCinematic).
- Touch nothing during loads. Don't poll menu widgets during gameplay.
- Never touch objects inside NotifyOnNewObject callbacks (crashed at the main menu).
  RegisterLoadMapPreHook is broken in 3.0.1; RegisterLoadMapPostHook is used.
- Keep event hooks trivial: record scalar values or a path, do the work on the next dispatcher
  tick. The two dedicated dispatcher tick hooks are the intentional exception: they execute
  throttled queued work on the game thread, never use their event's actor/widget arguments,
  and reject nested ticks.
- FindAllOf costs about 25-30 ms: one class per tick at most. Students and ghosts inherit
  Enemy_Character (filter by class name).
- In Bash heredocs, backslash escapes get mangled; write files with the editor tool or Python.
- The game ignores Ctrl and Shift on its own bindings: a mod combo on a game key also fires
  the game's action (Ctrl+Shift+M opened the map), and holding Left Ctrl is Dodge, Left Shift
  Sprint. Base keys the game leaves free: F5-F8, comma, the mod's punctuation keys.
- Never read menu widgets while UIManager says GetInMenuTransition or
  IsAsyncScreenLoadInProgress (world.ui_busy): a bracket press as the pause menu opened crashed
  in a property read (Oct 6).
- StaticFindObject plus IsValid can hand back a widget the game has already destroyed (name
  cleared to None, memory freed): the focus poller called GatherMenuReaderStrings on the closed
  Field Guide 200 ms after the pause menu shut and crashed (Oct 6, 22:15, dump decoded in
  the private notebook). Every lookup by path must check GetFullName still ends in the path (resolve() in
  world.lua and menus.lua, the quest widgets, the HUD prompt), menu code must ask the UI
  manager fresh (world.gameplay()/ui_busy() do; never cache "a menu is up" across ticks), and
  widget reads wait 0.75 s after any UI state change.
- UE4SS 3.0.1 leaks a registry reference per out parameter of every UFunction called from Lua
  (it pins the out table forever). Wrap such calls in dispatch.call_out(fn, out_table), which
  frees exactly that slot. Never walk the registry: UE4SS's async thread writes to it.
- UE4SS 3.0.1 keeps a registry ref per ExecuteInGameThread callback, even when reusing the
  same function. Persistent Blueprint ticks now avoid steady submissions. The bounded
  fallback frees only its own exact callback reference, only on verified version 3.0.1;
  UE4SS owns the temporary thread reference. Do not replace this with a registry sweep.
  Missing Blueprint RegisterHook retries also allocate refs before failing: use named
  RegisterCustomEvent, or check the function exists before registering once. See the private notebook.
  Two Oct 6 freezes coincided with large registry counts, but their cause is still unproven.
  Keep comparing the driver/fallback/free/missed logs and long-session behavior in game.
- StaticFindObject(path) itself can crash on an object the game is destroying (UE4SS
  auto_construct_object -> IsChildOf, before any IsValid): the vault fight shattering knights,
  Oct 7, twice. Don't keep looking up by path things that are being destroyed (enemies dying,
  released puzzle knights); prefer what the world scan just read from FindAllOf.
- The dispatcher's fallback tick can run inside UEngine::LoadMap: UE4SS runs a pending
  ExecuteInGameThread callback at the next ProcessEvent, LoadMap's included. The world gate's
  player lookup there crashed the game three times (Oct 8, 05:49, 19:31, 19:55). World work
  must wait for dispatch.ticking(); a timed load guard can't beat an already queued callback.
- RegisterCustomEvent is keyed by name (first registration wins) and also fires for
  Blueprint-internal functions run by the script VM (script_hook), so BP functions like
  StandingArrived or OnIntroStarted can be hooked by name at startup.
- Scanner names call ABiped_Character:GetCharacterID once per character, fresh from FindAllOf
  (a deliberate exception to the no-calls-on-actors rule; watch for crashes in world scan).
- Menu widgets: read reflected properties (Visibility, RenderOpacity, Slots[i].Content,
  ActiveWidgetIndex, ToolTipText, CheckedState), not UFunctions. GetText is the one call kept
  (bound text). A ProcessEvent on a freed widget crashed in the pause menu on Oct 6. Key-driven
  walks leave "walk text <name>" breadcrumbs in trace.log.
- The game overwrites Controller:SetControlRotation. Turn the camera with relative mouse
  moves (input_bridge.mouse_move) and read ControlRotation back to learn the sensitivity.
- Run tests through tools/run_tests.py, which sets WANDSONG_TEST_DIR and LOCALAPPDATA
  to isolated temporary folders (an old controls test once rewrote the real Input.ini).
  controls.lua's automatic settings fixes run only when the UE4SS global exists: any test that
  loads menus.lua (text_test) used to apply them to the real Input.ini.

## Current status: reliability update awaiting game tests

Earlier game sessions confirmed menus/character creation, the Controls menu, tutorial text,
scanner use, guide following with mouse steering, turning and intro audio description.
The intro save still starts in the cave after the dragon crash; completing the broken steps
past the first fight is the next progression check.

Implemented and tested offline in this update:
- persistent game-thread dispatch with bounded, reference-cleaning fallback;
- generation-aware load cancellation and fresh menu-object resolution;
- height-aware route/arrival checks, actual scanner-target categories and navmesh routing;
- held jumps with forward movement, remapped controls and bounded blocked attempts;
- replayable audio description, skip/load/scene cancellation and pause-aware timing;
- world sound muting separated from navigation and crash recovery;
- base-key conflict checking and instructions based on active game bindings;
- interaction prompts, health/potion readings and block/dodge warning events;
- isolated tests, honest failure statuses, Windows/Linux CI and an update helper.

Not yet established in the game: whether this removes the two reported freezes, climbs the
actual broken steps, or receives the new HUD events. The route fallback and quest strings
also need in-game verification. Follow docs/TESTING_ON_GAME_PC.md and retain the marked logs.
Do not replace normal traversal with teleport and call that a climbing fix.

Next after those acceptance checks: scanner particulars/categories, readable map/journal,
more combat information and later-game descriptions. See docs/ROADMAP.md. No claim is made
that this update finishes every feature on that roadmap.

Key layout (all rebindable; F6 lists current keys): Page Down/Up scanner, Shift+Page Down/Up
category, Home re-announce and face, Shift+Home walk to it, Shift+grave autowalk to objective,
Shift+End teleport, End health/potions, comma face nearest enemy, arrows turn (menus: up/down
walk the list), up arrow facing + quest, grave "what was that", F5 beacon, Shift+F5 world
sounds, Shift+F8 resume after a crash, F6 guide, Shift+F6 audio description, F7 repeat,
Shift+F7 read subtitles, F8 mark, F9 mute, Shift+F9 scan dump, semicolon help,
brackets/backslash menus. No Ctrl defaults in the world (Ctrl = Dodge).
