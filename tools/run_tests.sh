#!/bin/sh
# Runs every offline test (UE4SS faked) and the syntax check. From the repo root:
#   sh tools/run_tests.sh
cd "$(dirname "$0")/.." || exit 1
host=native/build/Release/luahost.exe
$host native/tests/syntax_check.lua | grep -v "^ok"
for t in path_test scanner_test surroundings_test text_test sweep_test; do
    $host native/tests/$t.lua 2>&1 | tail -1
done
rm -f mod/Wandsong/tips_seen.txt   # written by the tests' tips
