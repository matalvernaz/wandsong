"""Build the standalone Lua host and run isolated tests, preserving every failure."""
import argparse
import os
from pathlib import Path
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parent.parent


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--host", type=Path, help="Use an existing Lua 5.4 host")
    parser.add_argument("tests", nargs="*", help="Test names without .lua; default: all")
    args = parser.parse_args()
    os.chdir(ROOT)
    if args.host:
        host = args.host.resolve()
    else:
        build = ROOT / "native" / "build-tests"
        subprocess.run(["cmake", "-S", "native", "-B", str(build)], check=True,
                       stdout=subprocess.DEVNULL)
        subprocess.run(["cmake", "--build", str(build), "--config", "Release", "--target", "luahost"],
                       check=True, stdout=subprocess.DEVNULL)
        host = build / ("Release/luahost.exe" if os.name == "nt" else "luahost")
    names = args.tests or ["syntax_check"] + sorted(p.stem for p in (ROOT / "native/tests").glob("*_test.lua"))
    failures = []
    for name in names:
        if not name.replace("_", "").isalnum():
            raise ValueError("Invalid test name: " + name)
        with tempfile.TemporaryDirectory(prefix="wandsong-test-") as tmp:
            env = dict(os.environ, WANDSONG_TEST_DIR=tmp, LOCALAPPDATA=tmp)
            run = subprocess.run([str(host), f"native/tests/{name}.lua"], env=env,
                                 capture_output=True, text=True, timeout=120)
        output = run.stdout + run.stderr
        failed = run.returncode != 0 or "[Wandsong] task failed (" in output or "[Wandsong] tick failed:" in output
        print(f"{'FAIL' if failed else 'PASS'} {name}", flush=True)
        if failed:
            failures.append(name)
            print(output, flush=True)
    print(f"{len(names) - len(failures)} passed, {len(failures)} failed")
    return 1 if failures else 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        print(f"Test runner failed: {error}", file=sys.stderr)
        sys.exit(1)
