These probes accompany the October 9, 2026 Wandsong audit at commit
`3d99313f0c376150b5c0edec0d1699b30e9b8787`.

They document the bugs as they were. A successful Lua probe means it reproduced the bad
behavior; these are evidence scripts, not regression tests asserting the desired behavior.
All twenty findings have since been fixed (docs/AUDIT_FIXES-2026-10-09.md), so every probe
now fails by design; the regression tests in native/tests and tools/test_setup_failures.py
check the fixes. The installer probe records observed outcomes as JSON and asserts its
setup prerequisites.

Run from the repository root on Windows with Python, CMake and Visual Studio build tools.
The existing test runner builds the matching Lua host:

```powershell
python tools/run_tests.py
python tools/audit_2026_10_09/run_runtime_repros.py
```

The Lua runner creates a separate temporary settings directory and process for each case.
Game objects, input and screen reader output are mocked. It does not load the game, send
real keys or edit player settings. A few probes inspect Lua upvalues to isolate a specific
internal decision; their dependencies on internal names are intentional.

The installer runner requires a freshly built, unpacked installer executable. The copy
used for this audit is retained under the ignored `dist/audit-2026-10-09` directory. To
rebuild independently:

```powershell
cmake -S installer -B dist/audit-2026-10-09/installer-build -G 'Visual Studio 17 2022' -A x64 '-DWANDSONG_VERSION=0.4.0'
cmake --build dist/audit-2026-10-09/installer-build --config Release
python tools/audit_2026_10_09/installer_repros.py --setup dist/audit-2026-10-09/installer-build/Release/WandsongSetup.exe
```

Or, using the retained audit executable:

```powershell
python tools/audit_2026_10_09/installer_repros.py
```

The installer runner forces quiet, offline operation and creates fresh fake games and
appended payloads under its own `TemporaryDirectory`. The lock test locks only a fake DLL.
The path traversal marker stays inside the disposable test tree. No administrator rights,
network requests, real installation or live game input are needed.

Results are written to ignored local artifacts:

- `dist/audit-2026-10-09/runtime-results.txt`: 13 Lua scenarios covering A04-A06, A10-A18 and A20.
- `dist/audit-2026-10-09/installer-results.json`: six installer scenarios covering A01-A03, A08 and A09. A03 has two scenarios.

A07 is a control-flow finding; A19 follows from the native implementation and Microsoft's
documented XAudio2 behavior. Neither is claimed as an executable reproduction here.
