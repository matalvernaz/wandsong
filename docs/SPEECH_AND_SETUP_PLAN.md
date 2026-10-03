# Native speech and easy setup plan (2026-10-02)

Decision: a **native helper exe (C++, Tolk)** that the Lua mod starts at load and feeds over a
named pipe. Keep the Lua side behind one module (`speech.lua`: `speak(text, interrupt)`,
`silence()`) so it can be swapped for a UE4SS C++ mod later (needs UEPseudo / Epic-linked
GitHub, one-time, dev only). Rejected: compiled AHK (antivirus magnet), a second proxy DLL.

## Helper
- Windowless (/SUBSYSTEM:WINDOWS), static CRT, version resource, no UPX.
- Tolk: `Tolk_TrySAPI(true)` then `Tolk_Load()` on a COM-initialised thread. Ship
  `nvdaControllerClient64.dll` next to Tolk.dll (rename from x64\nvdaControllerClient.dll if
  needed). Test NVDA, JAWS demo, no screen reader (SAPI).
- Pipe `\\.\pipe\wandsong`, unlimited instances, 64 KB buffers, reader thread only
  queues; speech on its own thread. Protocol: one UTF-8 line per message, `I|text` interrupt,
  `Q|text` queue, newlines in text replaced by spaces.
- Named mutex (single instance); watch HogwartsLegacy.exe with SYNCHRONIZE and exit with it;
  exit after 60 s if no game.

## Lua client
- Launch at main.lua load: `os.execute('start "" "<dir>\\wandsong_helper.exe"')` (before the game
  window exists, so no focus theft). Test for console flash.
- `io.open(pipe, "wb")` in pcall; setvbuf("no"); on failure retry at most every 2 s; on write
  error drop the handle and reconnect. No helper = silently no speech, never a crash.

## Installer (C++ console exe, shares Tolk; every prompt printed and spoken)
- Find game: Steam (HKCU SteamPath -> libraryfolders.vdf -> appmanifest_990080.acf), Epic
  (ProgramData manifests .item JSON), else ask. Game Pass: unsupported, say so.
- Menu: Install/Update (back up dwmapi.dll, ini, mods.txt; merge mods.txt; set ini
  EngineVersionOverride 4.27, GuiConsoleEnabled=0, bUseUObjectArrayCache=false; write
  manifest; strip Zone.Identifier; speak a test line), Vanilla mode toggle (rename dwmapi.dll),
  Uninstall (manifest + restore backups), Check for updates (opens releases page).
- Record game exe size/hash; warn by speech if the game updated.

## Order
1. Helper + PowerShell pipe test client (NVDA, SAPI).
2. speech.lua, drop AHK/file polling, test flash/focus and helper restart.
3. Stress: fast scrolling, full buffer, Unicode; JAWS demo.
4. Installer: detect, install, ini merge, manifest, speech confirm.
5. Uninstall, vanilla toggle, update check; clean-account test from a GitHub zip.
6. Release packaging, AV false-positive submission, SignPath; Epic test if possible.
