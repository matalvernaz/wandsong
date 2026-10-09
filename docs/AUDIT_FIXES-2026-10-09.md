# October 9 audit fixes

Baseline: `3d99313f0c376150b5c0edec0d1699b30e9b8787`. The original findings and
bad-behavior probes remain in [the audit](AUDIT-2026-10-09.md). Those probes deliberately
assert the old defects, so after these fixes every one of them fails by design; use the
regression suites below to check the fixes.

The first batch implements A01-A09; the second, A10-A20. All twenty are fixed offline,
pending the game checks at the end. None of it is a published release.

# First batch: A01-A09

## Installation and recovery

- A01: checked backup creation and restoration. A failure retains recoverable originals
  and an installation record; locked-file failures return a failure status. Retrying after
  releasing the lock restores the files. Cleanup keeps the completion marker until the
  rollback journal and copies are gone, so interrupted cleanup cannot undo a successful
  installation or discard the only recovery copies.
- A02: every overwritten, previously unrecorded file is backed up, including shared
  helpers, configuration and files in hand-installed copies. Updates retain those originals.
  Uninstall removes recorded files and restores originals; unrecorded settings, logs and
  other additions stay. If an update drops a previously backed-up mod file, it restores
  that original instead of deleting it.
- A03: validate required payload contents and destination paths, stage the payload and
  patched configuration, snapshot all affected files, then flush a rollback journal before
  changing destinations. Atomic file replacement is checked and byte-verified. Disable
  the active loader during replacement and restore it last, after payload and ownership
  records. A failure rolls back or retains a retryable journal. Setup recovers an interrupted
  transaction before another mutation, and a per-installation lock prevents concurrent setups.
- A07: the downloaded setup receives an explicit allowance to request elevation, retaining
  the interactive permission route. Ordinary unattended installation still cannot prompt
  unexpectedly. The elevated child does not inherit that allowance, preventing a prompt loop.
  This control flow compiles and was reviewed; an actual protected-folder/UAC session remains
  an integration check, not a claimed automated test result.
- A08: payload and manifest paths reject traversal, rooted paths, drive prefixes, streams,
  ambiguous Windows names and reserved setup/game files. Existing path components are
  checked for junctions/symlinks before file operations. Payload lengths use subtraction-safe
  bounds excluding the footer; duplicate Windows path spellings are rejected. Recovery
  records are validated before rollback.
- A09: updates preserve the active/inactive loader choice. Failed updates preserve it too.
  Uninstall restores the original loader's location, including a pre-existing inactive loader.

Implementation: `installer/src/main.cpp`, `installer/src/file_transaction.h`.
Regression tests: `tools/test_setup_failures.py`, plus the existing `tools/test_setup.ps1`.
Both operate exclusively on unique disposable fake game folders. Never run installer
failure experiments against a real installation.

## Menu actions and load barriers

- A04: Blueprint activation requires the selected button's exact binding prefix; an unrelated
  function with the same event signature is no longer a fallback. An inherited exact binding
  works. Otherwise the selected button's native delegate is used, or activation is reported
  unavailable. Tests cover the delete/continue mix-up, multiple buttons, inherited handlers,
  common name prefixes, unnamed buttons, missing delegates and single activation.
- A05: a known settled menu can use dispatcher fallback without being marked loading every
  tick. An 11-second pause without Blueprint ticks still accepts a queued menu key. Explicit
  load marks continue to block work, and unknown UI states retain the conservative tick-loss
  barrier. World gameplay still requires ticks.
- A06: the explicit load barrier precedes crash-paused world handling, and public UI-busy
  checks are object-free during a load. Regression tests count object queries during both
  crash-paused startup and subsequent load marks, then verify safe queries resume afterward.

Implementation: `mod/Wandsong/Scripts/menus.lua`, `dispatch.lua`, `world.lua`, `state.lua`.
Regression tests: `native/tests/menu_activation_test.lua`, `dispatch_test.lua`,
`world_fuse_test.lua`, alongside the existing menu and tick-stop coverage.

## Validation and build gates

- 37 isolated Lua checks pass, including the new activation test.
- 28 existing setup checks pass.
- 28 installer regression cases pass, including real Windows file-sharing locks,
  restoration retry, late write failures, unsafe paths, a junction destination, vanilla
  updates, shared-file ownership and simulated interrupted-transaction recovery.
- Installer and all native/helper targets build on this Windows machine.
- The packaged candidate's 54 files were compared byte-for-byte with the build payload;
  its changed Lua scripts also match the source tree. That same executable passed an
  install, vanilla-mode update and uninstall in a fake game, retaining a custom shared
  helper and player settings. Artifact: `dist/WandsongSetup-0.4.1-audit1.exe`, with a sibling
  `.sha256` file; the distribution archive is `dist/Wandsong-0.4.1-audit1.zip`.
- Windows CI builds the installer and runs both setup suites. Release packaging now runs
  the Lua suite and both setup suites against the installer build it is about to package.
- Setup test directories are unique. Release cleanup checks its output paths before removal.

The installed reference mod documentation and the archived reference manual were consulted
for keyboard interaction and shared-file preservation conventions. No reference-mod code
was copied into this batch.

No live game session, real installation, save modification, UAC prompt or release publication
is part of this validation. Actual disk exhaustion and power interruption were not induced;
the recovery tests reconstruct incomplete on-disk transactions and exercise retry behavior.
Compilation and mocks do not establish that every affected game screen behaves correctly.

## Game checks still required

Follow [the game-PC testing instructions](TESTING_ON_GAME_PC.md), using a dedicated test
save. Verify a pause menu lasting at least ten seconds, failure/retry, repeated menu
open/close, actual map loads, and a crash-paused startup. Confirm that selected buttons
activate once, that an unavailable action is announced, and that no task errors or unsafe
object lookups appear around loads. Do not enable the experimental AI walk for this batch.

# Second batch: A10-A20

Each finding has its own regression test, which fails on the audited code and passes now.

- A10, `menu_screens_test`: a mod screen's selection follows the entry picked, by its id
  (Places, Controls and the game settings give ids) or else its words, when the list is
  rebuilt in another order or an entry is added before it. An entry that is gone, or can't be
  told from another, presses nothing and says so. The Places travel question and its
  confirming press go to the same Floo Flame however the player moved in between.
- A11, `gamesettings_choice_test`: switching a setting on the Controls screen takes it off the
  first start's list of settings to set again; untouched ones are still set again.
- A12, `keys_remap_test`: conflict checks count the bindings in force as well as Input.ini's
  edited copy, and the Controls menu says which conflict lasts until the restart and which
  starts with the next one. Rebinding a game key ignores a conflict that ends at the restart,
  when the new key takes effect.
- A13, `keys_remap_test`: `bindings.same_key` compares UE4SS and Unreal key names as the
  virtual key both stand for, so the stuck-hotspot interaction works on Delete, Space,
  punctuation and number keys. A hotspot counts as used only once its interaction worked.
- A14, `scanner_marker_test`, `navigation_test`: `path.walk_point` walks to the quest marker
  picked (a navmesh route, like any scanner target); the route's end still follows the game's
  route. Markers over no thing are known by position, so the selection survives reordering,
  and a marker the step dropped walks nowhere.
- A15, `world_identity_test`: each scan pass compares the fresh object's own path and class
  with the snapshot at its address and starts a new snapshot when they differ. This costs a
  GetFullName per tracked actor per pass (far actors already had one): compare the scan
  timings in the log ("scan NPC_Character: N nearby (X ms)") with earlier sessions.
- A16, `ai_walk_test`: `state.world` counts the worlds (map loads and a new player object).
  A map load ends the AI walk touching nothing, as before; a load mark in the same world
  (a menu's screen loading) only pauses it, and a hand-back asked for meanwhile runs once
  objects may be touched. The AI walk remains off by default.
- A17, `subtitles_carry_test`: nothing is carried over a load that came within 3 s of a menu
  (a save, Try Again, the main menu), and a menu or another load before the next scene drops
  what was carried. The title card's carry, as in the Oct 8 log (the new map in play for
  10 s, no menu, then its scene), still works.
- A18, `spells_checkpoint_keys_test`: the press key answers exactly the checkpoints it was
  named for (any option on the mouse only or unbound), and a keyboard key remapped onto
  option 3 or 4 is named as itself.
- A19, `audio_stop_test` (the real module, silent, skipped without an audio device):
  `stop_all` stops each one-shot voice before flushing it, and a voice is started again when
  its next sound is submitted. On this PC the old code left an already playing sound
  playing after `stop_all`, which the test catches; the fix stops it. `audio.playing()` counts
  the one-shot voices still holding a sound.
- A20, `menu_screens_test`: Enter presses on a mod screen in the world; in the world without
  one it stays the game's, and the typing and pop-up rules are unchanged.

Validation: 45 Lua checks, including the ten new or extended ones above. The native audio
module needs a full native deploy (`deploy.ps1 -Native`), not the input-module update helper.

## Game checks still required

Both batches: a pause menu lasting at least ten seconds, failure/retry, repeated menu
open/close, actual map loads and a crash-paused startup, with selected buttons activating
once, unavailable actions announced, and no task errors or unsafe lookups around loads.
Second batch: the Places list while walking (pick a Floo Flame, walk, confirm), two quest
markers, Interact remapped to Delete at a stuck hotspot, a spell checkpoint with option 1 on
the mouse, F9 mute during a long sound, and scan timings in a busy place. The AI walk stays
off for these checks.
