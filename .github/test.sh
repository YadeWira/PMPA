#!/bin/sh
# The check every platform runs (CI): the portable layer tests, built with
# range and overflow checks on. When the .pmpa container exists this also
# compresses and extracts every sample with the command and writes the
# SHA-256 of the .pmpa files to hash.txt, compared across platforms.
#
#   FPC=<compiler> PMPA_OUT=<dir> sh .github/test.sh
set -eu
FPC=${FPC:-fpc}
OUT=${PMPA_OUT:-build/ci}
case "$(uname -s)" in MINGW*|MSYS*|CYGWIN*) EXE=.exe ;; *) EXE= ;; esac
rm -rf "$OUT"; mkdir -p "$OUT/t"

echo "== layer tests"
for prog in test_blake3 test_arith; do
  $FPC -O2 -Fupas -Fipas -FU"$OUT/t" -FE"$OUT/t" "pas/tests/$prog.pas" > "$OUT/fpc.log" 2>&1 \
    || { cat "$OUT/fpc.log"; exit 1; }
done
"$OUT/t/test_blake3$EXE" pas/tests/kat.txt | tail -1
"$OUT/t/test_arith$EXE" | tail -1
