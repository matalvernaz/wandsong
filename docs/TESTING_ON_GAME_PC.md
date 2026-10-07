# Reliability update: install and test on the game PC

This update fixes issues found in the source review: growing dispatcher callback references,
false arrivals on another floor, scanner targets bypassing pathfinding, short jump presses,
descriptions that never replay or continue after a skip/load, sound muting disabling navigation,
modifier-key conflicts, and stale menu references. It also adds HUD interaction prompts,
low-health speech, attack warning tones, and End to read health and healing potions.

Offline tests simulate the game APIs. They cannot prove that the reported freezes are gone,
that Fig's broken steps are traversable, or that the HUD events fire in this game build.
Those are the first things to verify here. Do not mark them working based on tests alone.

## Update the existing installation

Close Hogwarts Legacy normally first. Do not hot-reload UE4SS or force-kill the game to update.
The PC needs its existing Visual Studio C++ Build Tools, CMake and Python 3.

In PowerShell, from the Wandsong source checkout on branch `main`:

```powershell
git status --short
git pull --ff-only
powershell -ExecutionPolicy Bypass -File tools\update_for_testing.ps1
```

If there are local source edits, preserve them before pulling. Do not reset or clean them away.
If `git pull` fails, resolve that before running the update. The update script runs every test
with temporary settings, builds `input_bridge.dll`, then copies the scripts and that DLL to
the existing installation. It refuses to deploy while the game runs or after a failed check.
It does not overwrite saved mod keys or player settings. The input DLL change is needed for
movement/jump remapped to extended keys, such as arrows or right control.

For a game installed outside Steam's libraries, pass its actual folder:

```powershell
powershell -ExecutionPolicy Bypass -File tools\update_for_testing.ps1 -Win64 'D:\Games\Hogwarts Legacy\Phoenix\Binaries\Win64'
```

Use the installation's real path, not that example unchanged. This updates an installed mod;
it is not a first-time installer. The other native modules and UE4SS stay at their installed
versions. Start the game normally after the script reports the deployed Git revision.

## First game checks

1. Load the intro save and wait for the gameplay chime. If the mod says world features were
   paused after a crash, Shift+F8 resumes them. Shift+F5 now controls sounds only.
2. Walk around, then press Shift+F5. World sounds should stop, while Page Down/Up still scan,
   Home still faces the selected thing, and the turning/autowalk keys still work. Turn sounds
   back on. F9 should mute all mod speech and sounds.
3. Select a stationary chest or door and press Shift+Home. Walking should follow a navmesh
   route where available. A failed query should say "no path found"; a partial path should
   report how far short it stops. Someone or something upstairs must not count as arrived
   just because it is nearby horizontally.
4. At the broken steps after the first fight, try Shift+grave to follow Fig. Forward and jump
   should overlap, with jump held for about two-thirds of a second. It should stop after
   bounded attempts if still blocked. Press F8 there if it fails, and keep the logs. Test
   ordinary climbing before trying the existing optional Shift+End teleport.
5. Start an autowalk and open a menu, load a save, or alt-tab. Synthetic movement should stop.
   Do not use remote sendkeys tools without Matt's permission.
6. Replay a described intro scene in the same running session. Descriptions should play again.
   Skip a scene, load a save, and pause/resume: old descriptions must not continue over the
   next scene or the load. Reading subtitles aloud remains optional on Shift+F7.
7. Approach something the game labels "Examine", "Open", etc. The mod should read the action
   and the currently assigned interaction key. Standing there should not repeat it endlessly;
   leaving and returning should read it again.
8. In combat, a high warning tone means block; the lower version means an unblockable attack,
   dodge. Health warnings are at half and one-fifth health. End reads the last health and
   potion count reported by the HUD. "Hasn't been reported" means no HUD event was received,
   not full health. Check that the numbers agree with gameplay before relying on them.
9. Exercise pause menus, character-name editing, slider adjustments and repeated save loads.
   In Controls, trying to bind a mod action to Control+M or Shift+W must reject it when M/W
   belongs to the game. A game key change takes effect after restarting; the instructions and
   autowalk keep using the currently active bindings until then.

Keep a longer session running as well, with several menu and load transitions. Completing the
intro without teleporting and without freezes is the main acceptance target, not a quick
launch followed by a claim that everything is fixed.

## Logs to inspect after testing

In `Phoenix\Binaries\Win64\Mods\Wandsong\`, keep `Wandsong.log`, `trace.log` and
their `.prev.log` files. Also keep `Phoenix\Binaries\Win64\UE4SS.log` and any new report in
`%LOCALAPPDATA%\Hogwarts Legacy\Saved\Crashes\`. Copy them before several restarts rotate them.
F8 adds a `PLAYER MARK` with recent speech.

- `dispatcher: Blueprint tick` should appear once gameplay/widgets are ticking. While this
  driver runs, `fallback posts` should stop continually rising. Fallback is expected at startup
  or on a screen with no ticking Blueprint. On UE4SS 3.0.1, completed fallback callbacks should
  be counted as freed, with `missed 0`. Log growth and registry counts are evidence to compare;
  they do not by themselves prove the freeze was caused by this leak.
- `task failed`, `tick failed`, `hook failed`, or `game thread hasn't run the mod for 8 s` needs
  investigation. A successful hook registration alone does not mean the game called it.
- `nav query`, `walking`, `autowalk blocked`, `stuck at` and `autowalk stopped` explain traversal.
  The stuck line records an obstacle profile and heights of nearby route points.
- `[Wandsong feedback] prompt` / `Incoming attack` / `Unblockable attack` confirm actual
  HUD events reached the new feedback layer. Health announcements are also in the speech log.
- `[Wandsong subtitles] line` and `description` show which line triggered a description.

If HUD events never arrive, inspect the current game's dumped Blueprint classes and event
names. The initial bindings come from the public Roadou/HogwartsLegacy-SDK headers, not from
a live dump of this PC. Do not substitute repeated unsafe actor calls to make the checks pass.
