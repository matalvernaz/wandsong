# Wandsong

A blind accessibility mod for Hogwarts Legacy (PC). It reads the game's menus through your
screen reader, lets you review and press anything on screen from the keyboard, and is growing
toward full, free exploration of Hogwarts and the Highlands by sound.

It speaks through NVDA, JAWS, Narrator and other screen readers via
[Prism](https://github.com/ethindp/prism), with braille output where your screen reader
supports it. Without a screen reader it uses a Windows voice.

## Status

An early mod, tested with Matt through menus and parts of the intro. Confirmed features:

- Every menu screen is read when it opens, including key hints and descriptions.
- A review cursor steps through all text, buttons, checkboxes and shortcuts on screen.
- You can press any button, toggle any checkbox, and adjust sliders and choices.
- Choice buttons say which one is selected (voice, difficulty, dormitory and so on).
- Text boxes, such as your character's name, read their contents and echo what you type.
- The character creator is fully labelled: real tab names, every option numbered within
  its section (Face Shape 3 of 15, Hairstyle 12 of 50), named sliders, and a short
  description of each of the 30 preset faces.
- Text-heavy screens, like your Hogwarts acceptance letter, are read in full.
- Shortcuts shown on screen (like "F, Continue") can be triggered from the review cursor,
  even when the game ignores the key.
- The first-launch accessibility screen unlocks itself, with spoken instructions.
- Contextual help, item descriptions, repeat last speech, copy screen text.
- A surroundings scan in the world (enemies, creatures, chests, doors, people and more).

World sounds, walls and openings, route beacons, guide following, turning keys and intro audio
description are implemented. The latest reliability fixes and new interaction/health/combat
feedback need testing in the game. See [the game-PC test guide](docs/TESTING_ON_GAME_PC.md)
for the update command, expected behavior and logs. The complete game is not yet accessible.

## Requirements

- Hogwarts Legacy for PC, the Steam or Epic version. Game Pass and Microsoft Store copies
  are not supported.
- Windows 10 or 11, 64-bit.
- A screen reader is recommended but not required.

## Installing and updating

Everything comes in one file, WandsongSetup-<version>.exe, from the
[latest release](https://github.com/matalvernaz/wandsong/releases/latest). For a development
installation, use [the update script](docs/TESTING_ON_GAME_PC.md).

1. Quit Hogwarts Legacy if it is running.
2. Run WandsongSetup-<version>.exe from wherever you saved it.
3. Setup finds the game by itself (Steam or Epic) and says which Wandsong is installed,
   if any. Press Enter to install it, or to update it to this version. If setup can't find the
   game, it asks for the game's folder: paste it and press Enter.
4. Start the game as usual. When it has loaded you will hear "Wandsong ready".

To update later, run any Wandsong setup you have, even an old one: it checks online for a newer
version, and Enter downloads it, checks it against its published checksum and installs it. Or
download the newer setup yourself and run it. Updating replaces the mod's files, removes files
the old version had that the new one doesn't, and keeps your settings and keys. The same setup
uninstalls (type 2) and switches vanilla mode on and off (type 3: play without mods).
An update keeps vanilla mode on if you switched mods off.

Setup is read out by your screen reader; without one running, it speaks with Windows' own voice.
If the game is in a folder Windows protects, setup asks for permission first. If someone else's
UE4SS mods were already installed, setup backs up the files it replaces and puts them back when
you uninstall.
Setup stages and verifies file changes before applying them. If a file is locked or a write
fails, it restores the previous files or keeps a recovery record for the next attempt. Keep
the backup, transaction folder and install record if setup reports that recovery is pending;
close programs using the affected files and run setup again.

If Windows SmartScreen warns about an unrecognised app, choose More info, then Run anyway.
The file is not code-signed yet.

## First launch

The very first time the game starts it shows an Accessibility Options screen that normally
can't be used until its own menu reader is switched on. Wandsong switches it on for you
(silently; your screen reader does the talking) and tells you what to do. Press F to continue.

## Keys

These are the defaults, chosen so they don't clash with NVDA, JAWS or the game. Insert, Caps
Lock and the number pad are left alone.

Every control, the game's and the mod's, lives in one accessible Controls menu: press
Control apostrophe. Entries are grouped by situation (On foot, Spells and combat, Riding and
flying, ... then Wandsong's own groups) and read like "Basic cast: slash, left mouse
button". Press the press key on one, then the key you want; clashes with other controls or
your screen reader are named first. Game keys take effect the next time the game starts.
The no-mouse preset adds slash for casting, right shift for aiming, 9 and 0 for spell sets,
and delete for skipping scenes where those actions have no keyboard binding. Existing custom
keys stay in place. The menu lists the assigned keys. Mouse buttons keep working.

Reading the screen:

- Left bracket and right bracket: previous and next item on screen.
- Shift with left or right bracket: previous and next button or shortcut.
- Control with left or right bracket: first and last item.
- Apostrophe: read the whole screen.
- Shift apostrophe: copy all the screen's text to the clipboard, for codes and links.
- Shift semicolon: description of the current item, the text a sighted player sees when
  hovering it.

Doing things:

- Backslash: press the current button, toggle a checkbox, switch to a tab, or use a
  shortcut. On a text box, it starts typing: type, then press Enter.
- Shift backslash: go back.
- Minus and equals: decrease and increase a slider or choice. Hold shift for bigger steps.

Help and speech:

- Semicolon: what this screen is, what's on it, and how to use the current item.
- Semicolon twice quickly: all the keys.
- F6: the guide and current key assignments.
- F7: repeat the last thing said. Press again to go further back.
- F9: turn Wandsong speech and sounds off or on.
- Shift+F6: audio description on or off. Shift+F7: read subtitles aloud on or off.
- F8: mark a problem in the log.

In the world:

- Page Down/Up: next/previous nearby thing, with name, distance and direction.
- Shift+Page Down/Up: change scanner category, including the quest objective.
- Home: read the selected thing again and face it. Shift+Home: walk to it.
- Shift+grave accent: autowalk to the objective or follow your guide; press again to stop.
- Left/right arrows: turn 45 degrees. Shift+left/right: turn 90 degrees. Down: turn around.
- Up arrow: facing direction, objective and tracked quest. Comma: face the nearest enemy.
- Grave accent: explain recent sounds. F5: objective beacon on/off.
- Shift+F5: world sounds on/off. Scanning and navigation stay available.
- Shift+F8: resume world features if a previous crash paused them.
- End: health, healing potions and your target from the HUD (new, needs game verification).
- F11: places. Floo Flames you can travel to and what the map marks near you, nearest first.
  Press twice on a Floo Flame to travel; once on anything else to set the game's route to it.
- Shift+End: optional teleport near the objective when stuck.
- Locking on (the game's lock-on key) says your target and its shield; a high tick is the game
  picking a new target. The game's own audio cues are turned on for you: being spotted, a beast
  noticing you and where a hit came from are spoken.

On the first start, Wandsong turns on the game's own audio cues, subtitles, path line,
target names and highlights and objective markers, and tells you which it changed. The Controls
menu (Ctrl+apostrophe) lists them, with the game's spell toggle, sprint toggle and camera aiming,
to switch any of them.

The game's own keys still work as normal, for example Escape for the pause menu, Q and E to
switch tabs, and F to continue.

## Tips for NVDA users

- In NVDA's Keyboard settings, consider turning off "Speech interrupt for typed characters",
  or make an NVDA configuration profile for Hogwarts Legacy. Otherwise your own key presses
  can cut off what the mod is saying.
- NVDA's own reading of the game window has nothing useful to say; everything comes from the
  mod.

## Troubleshooting

- No speech at all: open UE4SS.log in the game's Phoenix\Binaries\Win64 folder and search
  for "speech:". It says whether speech runs in-process (and through which screen reader) or
  had to fall back to the helper program, and why.
- The game crashes or won't start after an update: run setup and choose vanilla mode, then
  report the problem.
- Bug reports: attach UE4SS.log from Phoenix\Binaries\Win64. It records everything the mod
  said, which makes problems easy to trace.

## Uninstalling

Run the setup, type 2 and press Enter. Files recorded as installed by Wandsong are removed,
and files setup backed up are put back, including shared mod helpers. Your settings, logs
and other unrecorded files stay in place. When updating a hand-installed copy without an
install record, setup preserves the files it replaces; uninstall restores that earlier copy.

## Building from source

Needs Visual Studio 2022 Build Tools (C++), CMake and the GitHub CLI. Run:

    powershell -ExecutionPolicy Bypass -File tools\build_release.ps1 -Version 0.4.0

This fetches Prism and UE4SS, builds the speech helper, the native modules and the setup, and
writes dist\WandsongSetup-<version>.exe (the setup with UE4SS and the mod appended to it)
and dist\Wandsong-<version>.zip (that file, this README and the licences). Test the setup
against fake game folders, never the real game, with:

    powershell -ExecutionPolicy Bypass -File tools\test_setup.ps1

Publish a release (the setup, its SHA-256 and the zip) with
`tools\publish_release.ps1 -Version <version>`; setups already out there find it themselves.

Run offline checks with Python 3 and CMake on Windows or Linux:

```text
python tools/run_tests.py
```

The runner builds the bundled Lua 5.4.4 host and gives each test separate temporary settings.
It fails on Lua errors, failed assertions, syntax errors and dispatcher task errors. GitHub
Actions runs these checks on Windows and Linux and builds the Windows input module.

Layout:

- mod\Wandsong\Scripts: the UE4SS Lua mod (speech, menus, scanner).
- native: Lua C modules loaded in the game process: prism_bridge (speech and braille through
  Prism) and click_bridge (presses buttons through their own OnClicked event).
- helper: wandsong_helper.exe, a fallback speech process used only if prism_bridge can't load.
- installer: WandsongSetup.exe.
- ue4ss: the UE4SS settings and mods.txt the game needs.
- docs: research notes and plans.

## Credits and licences

- Wandsong is MIT licensed; see LICENSE.
- [RE-UE4SS](https://github.com/UE4SS-RE/RE-UE4SS) (MIT) loads the mod.
- [Prism](https://github.com/ethindp/prism) (MPL 2.0) handles screen reader and voice output;
  its notices are in the licenses folder of each release.
- The in-process speech and click modules (native/prism_bridge.c, native/click_bridge.cpp)
  are adapted, with permission, from another access mod's code. They statically link
  Lua 5.4.4 (MIT), the version UE4SS embeds.
- Ideas borrowed with thanks from other access mods, and from the audio games A Hero's Call
  and Swamp.

Wandsong is a fan-made accessibility mod. It is not affiliated with or endorsed by
Warner Bros. Games, Avalanche Software or Portkey Games, and it needs a legitimate copy of the
game.
