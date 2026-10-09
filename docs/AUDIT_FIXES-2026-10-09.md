# October 9 audit fixes: first batch

Baseline: `3d99313f0c376150b5c0edec0d1699b30e9b8787`. The original findings and
bad-behavior probes remain in [the audit](AUDIT-2026-10-09.md). Those probes deliberately
assert the old defects; use the regression suites below to check the fixes.

This batch implements A01-A09. A10-A20 remain open. It is an offline-tested local
candidate, `0.4.1-audit1`, pending the game checks below. It is not a published release.

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

## Remaining audit work

A10-A20 remain open: stable menu selection during reorder; explicit settings choices;
active/pending key conflicts and key-name normalization; selected quest-marker navigation;
actor identity when addresses are reused; AI possession during UI loads; description
continuity across save loads; spell-checkpoint fallback; immediate stopping of one-shot
audio; and Enter on virtual mod screens. Start the next runtime batch with stable selection
and shared binding conversion, retaining a separate regression case for each finding.
