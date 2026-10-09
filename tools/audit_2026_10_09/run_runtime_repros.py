"""Run isolated Lua audit probes without touching the game or live player settings."""
import os
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[2]
output = root/'dist/audit-2026-10-09'
output.mkdir(parents=True, exist_ok=True)
cases = ['menu_stall', 'settings_override', 'wrong_handler', 'menu_reorder',
         'virtual_enter', 'hotspot_remap', 'scanner_marker', 'disabled_world_loading',
         'pending_bindings', 'reused_address', 'ai_ui_load', 'description_save_load',
         'spell_checkpoint_fallback']
failed = []
logs = []
for case in cases:
    with tempfile.TemporaryDirectory(prefix='wandsong-audit-lua-') as tmp:
        env = dict(os.environ, WANDSONG_TEST_DIR=tmp, LOCALAPPDATA=tmp, WANDSONG_AUDIT_CASE=case)
        p = subprocess.run([str(root/'native/build-tests/Release/luahost.exe'),
                            'tools/audit_2026_10_09/runtime_repros.lua'],
                           cwd=root, env=env, capture_output=True, text=True, timeout=30)
        logs.append(f'CASE {case}\n{p.stdout}\n{p.stderr}')
        if p.returncode or 'AUDIT RESULT:' not in p.stdout or 'task failed (' in p.stdout:
            failed.append(case)
            print('PROBE FAILED:', case, p.stdout, p.stderr)
        else:
            print(case + ': ' + p.stdout.split('AUDIT RESULT:', 1)[1].strip())
(output/'runtime-results.txt').write_text('\n\n'.join(logs), encoding='utf-8')
raise SystemExit(bool(failed))
