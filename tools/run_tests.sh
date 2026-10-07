#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
if command -v python3 >/dev/null 2>&1; then
    exec python3 tools/run_tests.py "$@"
fi
exec python tools/run_tests.py "$@"
