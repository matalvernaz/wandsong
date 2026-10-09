"""Installer regression tests using only private, disposable fake game directories."""
import argparse
from contextlib import contextmanager
import ctypes
import os
from pathlib import Path
import struct
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
ENV = dict(os.environ, WANDSONG_SETUP_QUIET="1", WANDSONG_SETUP_OFFLINE="1")
BASE_ITEMS = [
    ("dwmapi.dll", b"new loader"),
    ("UE4SS.dll", b"new UE4SS"),
    ("Mods/Wandsong/Scripts/main.lua", b"-- new mod"),
    ("Mods/Wandsong/version.txt", b"0.4.0"),
    ("Mods/Keybinds/Scripts/main.lua", b"new shared keybinds"),
]


@contextmanager
def locked(path):
    kernel = ctypes.WinDLL("kernel32", use_last_error=True)
    kernel.CreateFileW.argtypes = [ctypes.c_wchar_p, ctypes.c_uint32, ctypes.c_uint32,
                                  ctypes.c_void_p, ctypes.c_uint32, ctypes.c_uint32, ctypes.c_void_p]
    kernel.CreateFileW.restype = ctypes.c_void_p
    kernel.CloseHandle.argtypes = [ctypes.c_void_p]
    handle = kernel.CreateFileW(str(path), 0x80000000, 1, None, 3, 0, None)
    if handle in (None, ctypes.c_void_p(-1).value):
        raise ctypes.WinError(ctypes.get_last_error())
    try:
        yield
    finally:
        kernel.CloseHandle(handle)


class SetupTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="wandsong-setup-regression-")
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name)
        self.game = self.base / "game"
        self.bin = self.game / "Phoenix/Binaries/Win64"
        self.bin.mkdir(parents=True)
        self.write("HogwartsLegacy.exe", b"fake game")
        self.setup = self.pack("setup")

    def write(self, rel, data):
        path = self.bin / rel
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data)
        return path

    def pack(self, name, extra=(), items=None):
        path = self.base / (name + ".exe")
        path.write_bytes(SETUP.read_bytes())
        entries = (BASE_ITEMS if items is None else items) + list(extra)
        with path.open("ab") as out:
            start = out.tell()
            for rel, data in entries:
                rel = rel.encode("utf-8")
                out.write(struct.pack("<I", len(rel)) + rel + struct.pack("<Q", len(data)) + data)
            out.write(b"HWAPACK1" + struct.pack("<QQ", start, len(entries)))
        return path

    def run_setup(self, action="install", setup=None, success=True):
        result = subprocess.run([str(setup or self.setup), "--" + action, "--game", str(self.game)],
                                env=ENV, stdin=subprocess.DEVNULL, capture_output=True,
                                text=True, encoding="utf-8", errors="replace", timeout=40)
        self.assertEqual(result.returncode == 0, success, result.stdout + result.stderr)
        if not success:
            self.assertNotIn("Done. Wandsong", result.stdout)
        return result.stdout

    def snapshot(self):
        return {p.relative_to(self.bin).as_posix(): p.read_bytes()
                for p in self.bin.rglob("*") if p.is_file()}

    def test_shared_original_survives_update_and_uninstall(self):
        shared = self.write("Mods/Keybinds/Scripts/main.lua", b"original custom helper")
        self.write("UE4SS-settings.ini", b"[General]\r\nCustom = true\r\n")
        self.write("Mods/mods.txt", b"AnotherMod : 1\r\n")
        original = self.snapshot()
        self.run_setup()
        self.assertEqual(shared.read_bytes(), b"new shared keybinds")
        self.run_setup(setup=self.pack("update", [("Mods/shared/new.lua", b"new helper")]))
        self.write("Mods/shared/unrelated.lua", b"added by someone else")
        original["Mods/shared/unrelated.lua"] = b"added by someone else"
        self.run_setup("uninstall")
        self.assertEqual(self.snapshot(), original)

    def test_locked_restore_retains_backup_and_record_then_retries(self):
        loader = self.write("dwmapi.dll", b"original loader")
        self.run_setup()
        installed = self.snapshot()
        with locked(loader):
            self.run_setup("uninstall", success=False)
            self.assertEqual(self.snapshot(), installed)
        self.run_setup("uninstall")
        self.assertEqual(loader.read_bytes(), b"original loader")
        self.assertFalse((self.bin / "Wandsong-backup").exists())
        self.assertFalse((self.bin / "Wandsong-manifest.txt").exists())

    def test_failed_backup_creation_changes_no_game_files(self):
        self.write("dwmapi.dll", b"original loader")
        self.write("Wandsong-backup", b"blocked backup directory")
        before = self.snapshot()
        self.run_setup(success=False)
        self.assertEqual(self.snapshot(), before)

    def test_manifest_directory_is_rejected_before_install(self):
        (self.bin / "Wandsong-manifest.txt").mkdir()
        before = self.snapshot()
        self.run_setup(success=False)
        self.assertEqual(self.snapshot(), before)

    def test_blocked_destination_leaves_no_partial_install(self):
        self.write("blocked", b"not a directory")
        before = self.snapshot()
        self.run_setup(setup=self.pack("blocked", [("blocked/child.txt", b"new")]), success=False)
        self.assertEqual(self.snapshot(), before)

    def test_late_locked_destination_rolls_back_first_install(self):
        late = self.write("zz-last.txt", b"keep this")
        before = self.snapshot()
        with locked(late):
            self.run_setup(setup=self.pack("late", [("zz-last.txt", b"replace")]), success=False)
        self.assertEqual(self.snapshot(), before)

    def test_locked_manifest_rolls_back_an_update(self):
        self.run_setup()
        self.write("Mods/Wandsong/keys.ini", b"my keys")
        before = self.snapshot()
        # A new recorded file makes the next manifest different.
        update = self.pack("update", [("Mods/Wandsong/Scripts/new.lua", b"new script")])
        with locked(self.bin / "Wandsong-manifest.txt"):
            self.run_setup(setup=update, success=False)
        self.assertEqual(self.snapshot(), before)

    def test_locked_loader_preserves_previous_files(self):
        loader = self.write("dwmapi.dll", b"old loader")
        before = self.snapshot()
        with locked(loader):
            self.run_setup(success=False)
        self.assertEqual(self.snapshot(), before)

    def test_vanilla_choice_survives_update_and_toggle_back(self):
        self.run_setup()
        self.run_setup("vanilla")
        updated = [(name, b"updated loader" if name == "dwmapi.dll" else data) for name, data in BASE_ITEMS]
        self.run_setup(setup=self.pack("update", items=updated))
        self.assertFalse((self.bin / "dwmapi.dll").exists())
        self.assertEqual((self.bin / "dwmapi.dll.off").read_bytes(), b"updated loader")
        self.run_setup("vanilla")
        self.assertEqual((self.bin / "dwmapi.dll").read_bytes(), b"updated loader")
        self.run_setup("uninstall")
        self.assertEqual(self.snapshot(), {"HogwartsLegacy.exe": b"fake game"})

    def test_vanilla_failed_update_stays_off(self):
        self.run_setup()
        self.run_setup("vanilla")
        before = self.snapshot()
        updated = [(name, b"updated loader" if name == "dwmapi.dll" else data) for name, data in BASE_ITEMS]
        with locked(self.bin / "dwmapi.dll.off"):
            self.run_setup(setup=self.pack("update", items=updated), success=False)
        self.assertEqual(self.snapshot(), before)

    def test_uninstall_while_off_restores_original_loader(self):
        self.write("dwmapi.dll", b"original loader")
        before = self.snapshot()
        self.run_setup()
        self.run_setup("vanilla")
        self.run_setup("uninstall")
        self.assertEqual(self.snapshot(), before)

    def test_preexisting_inactive_loader_is_restored_inactive(self):
        self.write("dwmapi.dll.off", b"original inactive loader")
        before = self.snapshot()
        self.run_setup()
        self.run_setup("vanilla")
        self.run_setup("uninstall")
        self.assertEqual(self.snapshot(), before)

    def test_removed_payload_file_restores_its_original(self):
        original = self.write("Mods/Wandsong/Scripts/old.lua", b"original hand-installed script")
        self.run_setup(setup=self.pack("older", [("Mods/Wandsong/Scripts/old.lua", b"installed script")]))
        self.run_setup()
        self.assertEqual(original.read_bytes(), b"original hand-installed script")
        self.run_setup("uninstall")
        self.assertEqual(original.read_bytes(), b"original hand-installed script")

    def test_uninstall_keeps_player_settings_and_unrecorded_files(self):
        self.run_setup()
        self.write("Mods/Wandsong/keys.ini", b"my keys")
        self.write("Mods/Wandsong/Scripts/custom.lua", b"my addition")
        self.run_setup("uninstall")
        self.assertEqual(self.snapshot(), {"HogwartsLegacy.exe": b"fake game",
                                         "Mods/Wandsong/keys.ini": b"my keys",
                                         "Mods/Wandsong/Scripts/custom.lua": b"my addition"})

    def test_legacy_unlisted_backups_are_restored(self):
        self.run_setup()
        self.write("Wandsong-backup/Mods/mods.txt", b"old custom mod list")
        manifest = self.bin / "Wandsong-manifest.txt"
        manifest.write_text("\n".join(l for l in manifest.read_text().splitlines()
                                      if l.lower().replace("/", "\\") != "mods\\mods.txt") + "\n")
        self.run_setup("uninstall")
        self.assertEqual((self.bin / "Mods/mods.txt").read_bytes(), b"old custom mod list")

    def test_unsafe_payload_paths_are_rejected(self):
        before = self.snapshot()
        for index, rel in enumerate(("../outside.txt", "..\\outside.txt", "/absolute.txt", "C:relative.txt",
                                     "C:\\absolute.txt", "\\\\server\\share\\file", "x.txt:stream", "x. ",
                                     "dir/../file", "CON.txt", "nul", "dir//file", "dir/./file", "bad\x00name",
                                     "Wandsong-backup/stolen", "Wandsong-manifest.txt", "HogwartsLegacy.exe")):
            with self.subTest(path=repr(rel)):
                self.run_setup(setup=self.pack(f"unsafe-{index}", [(rel, b"bad")]), success=False)
                self.assertEqual(self.snapshot(), before)
        self.assertFalse((self.bin.parent / "outside.txt").exists())

    def test_duplicate_windows_paths_are_rejected(self):
        before = self.snapshot()
        self.run_setup(setup=self.pack("duplicates", [("MODS\\WANDSONG\\Scripts\\MAIN.lua", b"wrong")]), success=False)
        self.assertEqual(self.snapshot(), before)

    def test_unsafe_manifest_is_rejected_before_any_removal(self):
        self.run_setup()
        outside = self.bin.parent / "outside.txt"
        outside.write_bytes(b"untouched")
        with (self.bin / "Wandsong-manifest.txt").open("a") as record:
            record.write("../outside.txt\n")
        before = self.snapshot()
        self.run_setup("uninstall", success=False)
        self.assertEqual(self.snapshot(), before)
        self.assertEqual(outside.read_bytes(), b"untouched")

    def test_reparse_destination_is_refused(self):
        outside = self.base / "outside"
        outside.mkdir()
        junction = self.bin / "Mods"
        subprocess.run(["powershell", "-NoProfile", "-NonInteractive", "-Command",
                        "New-Item -ItemType Junction -Path $env:WANDSONG_TEST_JUNCTION "
                        "-Target $env:WANDSONG_TEST_TARGET -ErrorAction Stop | Out-Null"],
                       env=dict(ENV, WANDSONG_TEST_JUNCTION=str(junction), WANDSONG_TEST_TARGET=str(outside)),
                       check=True, capture_output=True, timeout=30)
        self.addCleanup(lambda: os.rmdir(junction))
        self.run_setup(success=False)
        self.assertEqual(list(outside.iterdir()), [])
        self.assertFalse((self.bin / "dwmapi.dll").exists())

    def test_payload_sizes_cannot_consume_footer_or_overflow(self):
        before = self.snapshot()
        for index, size in enumerate((1, 2**64 - 1)):
            path = self.base / f"bad-size-{index}.exe"
            path.write_bytes(SETUP.read_bytes())
            with path.open("ab") as out:
                start = out.tell()
                name = b"dwmapi.dll"
                out.write(struct.pack("<I", len(name)) + name + struct.pack("<Q", size))
                out.write(b"HWAPACK1" + struct.pack("<QQ", start, 1))
            self.run_setup(setup=path, success=False)
            self.assertEqual(self.snapshot(), before)

    def test_interrupted_transaction_is_recovered_before_retry(self):
        self.write("UE4SS.dll", b"partial new version")
        self.write("new-file.txt", b"partial new file")
        self.write("Wandsong-transaction/old/UE4SS.dll", b"previous version")
        self.write("Wandsong-transaction/journal.txt",
                   b"Wandsong transaction 1\nR\tUE4SS.dll\nN\tnew-file.txt\nEND\t2\n")
        # An unpacked setup refuses installation after recovery, letting us inspect the restored state.
        self.run_setup(setup=SETUP, success=False)
        self.assertEqual(self.snapshot(), {"HogwartsLegacy.exe": b"fake game", "UE4SS.dll": b"previous version"})

    def test_failed_recovery_keeps_journal_and_copies_for_retry(self):
        dll = self.write("UE4SS.dll", b"partial new version")
        self.write("Wandsong-transaction/old/UE4SS.dll", b"previous version")
        self.write("Wandsong-transaction/journal.txt", b"Wandsong transaction 1\nR\tUE4SS.dll\nEND\t1\n")
        before = self.snapshot()
        with locked(dll):
            self.run_setup(setup=SETUP, success=False)
        self.assertEqual((self.bin / "Wandsong-transaction/old/UE4SS.dll").read_bytes(), b"previous version")
        self.assertEqual(dll.read_bytes(), before["UE4SS.dll"])
        self.run_setup(setup=SETUP, success=False)
        self.assertEqual(dll.read_bytes(), b"previous version")
        self.assertFalse((self.bin / "Wandsong-transaction").exists())

    def test_committed_transaction_cleanup_does_not_roll_back(self):
        self.write("UE4SS.dll", b"committed version")
        self.write("Wandsong-transaction/old/UE4SS.dll", b"old version")
        self.write("Wandsong-transaction/journal.txt", b"Wandsong transaction 1\nR\tUE4SS.dll\nEND\t1\n")
        self.write("Wandsong-transaction/committed", b"committed\n")
        self.run_setup(setup=SETUP, success=False)
        self.assertEqual((self.bin / "UE4SS.dll").read_bytes(), b"committed version")
        self.assertFalse((self.bin / "Wandsong-transaction").exists())

    def test_cleanup_failure_keeps_completion_marker_until_retry(self):
        self.write("UE4SS.dll", b"committed version")
        self.write("Wandsong-transaction/old/UE4SS.dll", b"old version")
        journal = self.write("Wandsong-transaction/journal.txt",
                             b"Wandsong transaction 1\nR\tUE4SS.dll\nEND\t1\n")
        marker = self.write("Wandsong-transaction/committed", b"committed\n")
        with locked(journal):
            self.run_setup(setup=SETUP, success=False)
        self.assertEqual(marker.read_bytes(), b"committed\n")
        self.run_setup(setup=SETUP, success=False)
        self.assertEqual((self.bin / "UE4SS.dll").read_bytes(), b"committed version")
        self.assertFalse((self.bin / "Wandsong-transaction").exists())

    def test_corrupt_journal_is_retained_without_changing_files(self):
        self.write("UE4SS.dll", b"keep")
        self.write("Wandsong-transaction/journal.txt", b"Wandsong transaction 1\nN\tUE4SS.dll\n")
        before = self.snapshot()
        self.run_setup(setup=SETUP, success=False)
        self.assertEqual(self.snapshot(), before)

    def test_missing_required_payload_is_rejected(self):
        before = self.snapshot()
        self.run_setup(setup=self.pack("incomplete", items=[("dwmapi.dll", b"loader")]), success=False)
        self.assertEqual(self.snapshot(), before)

    def test_existing_lock_file_is_never_deleted(self):
        self.write("Wandsong-setup.lock", b"unrelated existing file")
        before = self.snapshot()
        self.run_setup(success=False)
        self.assertEqual(self.snapshot(), before)

    def test_incomplete_recovery_keeps_loader_disabled_until_files_restore(self):
        self.write("dwmapi.dll", b"partly installed loader")
        dll = self.write("UE4SS.dll", b"partly installed runtime")
        self.write("Wandsong-transaction/old/dwmapi.dll", b"original loader")
        self.write("Wandsong-transaction/old/UE4SS.dll", b"original runtime")
        self.write("Wandsong-transaction/journal.txt",
                   b"Wandsong transaction 1\nR\tUE4SS.dll\nR\tdwmapi.dll\nEND\t2\n")
        with locked(dll):
            self.run_setup(setup=SETUP, success=False)
        self.assertFalse((self.bin / "dwmapi.dll").exists())
        self.assertTrue((self.bin / "Wandsong-transaction/old/dwmapi.dll").is_file())
        self.run_setup(setup=SETUP, success=False)
        self.assertEqual((self.bin / "dwmapi.dll").read_bytes(), b"original loader")
        self.assertEqual(dll.read_bytes(), b"original runtime")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--setup", type=Path, default=ROOT / "installer/build/Release/WandsongSetup.exe")
    args, remaining = parser.parse_known_args()
    SETUP = args.setup.resolve()
    if not SETUP.is_file():
        parser.error(f"Build the unpacked setup first: {SETUP}")
    unittest.main(argv=[__file__, *remaining], verbosity=2)
