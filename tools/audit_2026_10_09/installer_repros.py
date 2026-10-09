"""Audit probes: run only against fresh fake games under a private temporary directory."""
import argparse
import ctypes
import json
import os
from pathlib import Path
import struct
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--setup', type=Path, default=ROOT/'dist/audit-2026-10-09/WandsongSetup-audit.exe',
                    help='Freshly built, unpacked WandsongSetup.exe')
SETUP = parser.parse_args().setup.resolve()
assert SETUP.is_file(), f'Build the installer and pass its path with --setup: {SETUP}'
ENV = dict(os.environ, WANDSONG_SETUP_QUIET='1', WANDSONG_SETUP_OFFLINE='1')
RESULTS = {}

with tempfile.TemporaryDirectory(prefix='wandsong-audit-') as temp:
    base = Path(temp).resolve()

    def game(name):
        root = base / name
        bin = root / 'Phoenix/Binaries/Win64'
        bin.mkdir(parents=True)
        (bin / 'HogwartsLegacy.exe').write_bytes(b'fake game')
        return root, bin

    def pack(name, extra=()):
        path = base / (name + '.exe')
        path.write_bytes(SETUP.read_bytes())
        items = [('dwmapi.dll', b'wandsong loader'),
                 ('UE4SS.dll', b'wandsong UE4SS'),
                 ('Mods/Wandsong/Scripts/main.lua', b'-- mod'),
                 ('Mods/Wandsong/version.txt', b'0.4.0'),
                 ('Mods/Keybinds/Scripts/main.lua', b'wandsong keybinds'), *extra]
        with path.open('ab') as f:
            offset = f.tell()
            for rel, data in items:
                encoded = rel.encode()
                f.write(struct.pack('<I', len(encoded)) + encoded + struct.pack('<Q', len(data)) + data)
            f.write(b'HWAPACK1' + struct.pack('<QQ', offset, len(items)))
        return path

    setup = pack('setup')

    def run(exe, action, root):
        p = subprocess.run([str(exe), '--' + action, '--game', str(root)],
                           env=ENV, stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=30)
        return {'exit': p.returncode, 'output': p.stdout.strip().replace(str(base), '<audit-temp>')}

    root, bin = game('vanilla_update')
    assert run(setup, 'install', root)['exit'] == 0
    assert run(setup, 'vanilla', root)['exit'] == 0
    assert not (bin / 'dwmapi.dll').exists()
    assert run(setup, 'install', root)['exit'] == 0
    RESULTS['vanilla_update'] = {'enabled_after_update': (bin / 'dwmapi.dll').exists(),
        'off_file_also_exists': (bin / 'dwmapi.dll.off').exists(), 'next_toggle': run(setup, 'vanilla', root)}

    root, bin = game('shared_file')
    shared = bin / 'Mods/Keybinds/Scripts/main.lua'
    shared.parent.mkdir(parents=True)
    shared.write_bytes(b'original custom keybinds')
    assert run(setup, 'install', root)['exit'] == 0
    overwritten = shared.read_bytes() != b'original custom keybinds'
    outcome = run(setup, 'uninstall', root)
    RESULTS['shared_file'] = {'overwritten': overwritten, 'original_restored': shared.exists(), **outcome}

    root, bin = game('locked_restore')
    loader = bin / 'dwmapi.dll'
    loader.write_bytes(b'original loader')
    assert run(setup, 'install', root)['exit'] == 0
    kernel = ctypes.WinDLL('kernel32', use_last_error=True)
    kernel.CreateFileW.argtypes = [ctypes.c_wchar_p, ctypes.c_uint32, ctypes.c_uint32, ctypes.c_void_p,
                                   ctypes.c_uint32, ctypes.c_uint32, ctypes.c_void_p]
    kernel.CreateFileW.restype = ctypes.c_void_p
    kernel.CloseHandle.argtypes = [ctypes.c_void_p]
    handle = kernel.CreateFileW(str(loader), 0x80000000, 1, None, 3, 0, None)
    assert handle not in (None, ctypes.c_void_p(-1).value), ctypes.get_last_error()
    try:
        outcome = run(setup, 'uninstall', root)
        RESULTS['locked_restore'] = {'backup_survives': (bin / 'Wandsong-backup/dwmapi.dll').exists(),
            'manifest_survives': (bin / 'Wandsong-manifest.txt').exists(),
            'loader_restored': loader.read_bytes() == b'original loader', **outcome}
    finally:
        kernel.CloseHandle(handle)

    root, bin = game('manifest_error')
    (bin / 'Wandsong-manifest.txt').mkdir()
    RESULTS['manifest_error'] = run(setup, 'install', root)
    RESULTS['manifest_error']['manifest_is_file'] = (bin / 'Wandsong-manifest.txt').is_file()

    root, bin = game('partial_install')
    (bin / 'blocked').write_bytes(b'not a directory')
    bad = pack('partial', [('blocked/child.txt', b'new')])
    RESULTS['partial_install'] = run(bad, 'install', root)
    RESULTS['partial_install'].update(loader_written=(bin / 'dwmapi.dll').exists(),
        manifest_written=(bin / 'Wandsong-manifest.txt').exists(), uninstall=run(bad, 'uninstall', root))

    root, bin = game('path_escape')
    marker = (bin.parent / 'audit-marker.txt').resolve()
    assert marker.is_relative_to(base)
    escaped = pack('escape', [('../audit-marker.txt', b'escaped payload')])
    RESULTS['path_escape'] = run(escaped, 'install', root)
    RESULTS['path_escape']['wrote_outside_win64'] = marker.exists()
    assert run(escaped, 'uninstall', root)['exit'] == 0
    RESULTS['path_escape']['uninstall_removed_outside_win64'] = not marker.exists()

output = ROOT/'dist/audit-2026-10-09'
output.mkdir(parents=True, exist_ok=True)
report = json.dumps(RESULTS, indent=2)
(output/'installer-results.json').write_text(report + '\n', encoding='utf-8')
print(report)
