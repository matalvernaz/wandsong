# Wandsong

A blind accessibility mod for Hogwarts Legacy (PC). It reads the game's menus through your
screen reader, lets you review and press anything on screen from the keyboard, and is growing
toward full, free exploration of Hogwarts and the Highlands by sound.

It speaks through NVDA, JAWS, Narrator and other screen readers via
[Prism](https://github.com/ethindp/prism), with braille output where your screen reader
supports it. Without a screen reader it uses a Windows voice.

## Status

Early, but playable through the menus. Working now:

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

Coming next: radar and wall sounds, 3D sound beacons on objects, area names, an object
tracker, combat cues, subtitles and dialogue choices. See docs/ for the plans.

## Requirements

- Hogwarts Legacy for PC, the Steam or Epic version. Game Pass and Microsoft Store copies
  are not supported.
- Windows 10 or 11, 64-bit.
- A screen reader is recommended but not required.

## Installing

1. Download the latest Wandsong zip from the Releases page.
2. Extract it anywhere, for example your Downloads folder.
3. Quit Hogwarts Legacy if it is running.
4. Open the extracted Wandsong folder and run WandsongSetup.exe.
5. Setup finds the game by itself. Type 1 and press Enter to install.
6. Start the game from Steam or Epic as usual. When it has loaded you will hear
   "Wandsong ready".

Setup backs up any files it replaces. Run it again any time to update, uninstall, or switch
"vanilla mode" on (play without mods) and off again.

If Windows SmartScreen warns about an unrecognised app, choose More info, then Run anyway.
The files are not code-signed yet.

## First launch

The very first time the game starts it shows an Accessibility Options screen that normally
can't be used until its own menu reader is switched on. Wandsong switches it on for you
(silently; your screen reader does the talking) and tells you what to do. Press F to continue.

## Keys

These keys were chosen so they don't clash with NVDA, JAWS or the game. Insert, Caps Lock and
the number pad are left alone.

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
- Control semicolon: repeat the last thing said. Press again to go further back.
- Control backslash: turn Wandsong speech off or on.

In the world:

- F9: what's around you, with distance and clock direction.

The game's own keys still work as normal, for example Escape for the pause menu, Q and E to
switch tabs, and F to continue.

## Tips for NVDA users

- In NVDA's Keyboard settings, consider turning off "Speech interrupt for typed characters",
  or make an NVDA configuration profile for Hogwarts Legacy. Otherwise your own key presses
  can cut off what the mod is saying.
- NVDA's own reading of the game window has nothing useful to say; everything comes from the
  mod.

## Troubleshooting

- No speech at all: check that Mods\Wandsong\helper\wandsong_helper.exe exists inside the
  game's Phoenix\Binaries\Win64 folder. Its log, wandsong_helper.log, says which screen reader it
  is using.
- The game crashes or won't start after an update: run setup and choose vanilla mode, then
  report the problem.
- Bug reports: attach UE4SS.log from Phoenix\Binaries\Win64. It records everything the mod
  said, which makes problems easy to trace.

## Uninstalling

Run WandsongSetup.exe and choose 2. Your original files are restored.

## Building from source

Needs Visual Studio 2022 Build Tools (C++), CMake and the GitHub CLI. Run:

    powershell -ExecutionPolicy Bypass -File tools\build_release.ps1

This fetches Prism and UE4SS, builds the speech helper and the installer, and writes
dist\Wandsong-<version>.zip.

Layout:

- mod\Wandsong\Scripts: the UE4SS Lua mod (speech, menus, scanner).
- helper: wandsong_helper.exe, the Prism-based speech process the mod starts and talks to over a
  named pipe.
- installer: WandsongSetup.exe.
- ue4ss: the UE4SS settings and mods.txt the game needs.
- docs: research notes and plans.

## Credits and licences

- Wandsong is MIT licensed; see LICENSE.
- [RE-UE4SS](https://github.com/UE4SS-RE/RE-UE4SS) (MIT) loads the mod.
- [Prism](https://github.com/ethindp/prism) (MPL 2.0) handles screen reader and voice output;
  its notices are in the licenses folder of each release.
- Ideas borrowed with thanks from other access mods, and from the audio games A Hero's Call and Swamp.

Wandsong is a fan-made accessibility mod. It is not affiliated with or endorsed by
Warner Bros. Games, Avalanche Software or Portkey Games, and it needs a legitimate copy of the
game.
