#!/bin/sh
# The check every platform runs (CI): the portable layer tests (checked
# build), the pmpa command built as it is shipped, every sample compressed
# and extracted by it (each must come back byte for byte), and the SHA-256
# of all the .pmpa files written to hash.txt: the format makes the same
# bytes on every platform, which the last CI job checks. The suite that
# needs a Unix filesystem (links, the command from the outside) is
# pas/run_tests.sh, run on Linux.
#
#   FPC=<compiler> PMPA_OUT=<dir> sh .github/test.sh
set -eu
FPC=${FPC:-fpc}
OUT=${PMPA_OUT:-build/ci}
SAMPLES="tests/mp1 tests/mp2 tests/mp3"
case "$(uname -s)" in MINGW*|MSYS*|CYGWIN*) EXE=.exe ;; *) EXE= ;; esac
if command -v sha256sum > /dev/null; then SHA="sha256sum"; else SHA="shasum -a 256"; fi
rm -rf "$OUT"; mkdir -p "$OUT/u" "$OUT/t" "$OUT/p" "$OUT/x"

echo "== layer tests"
for prog in test_blake3 test_arith test_mpeg test_codec test_format; do
  $FPC -O2 -Fupas -Fipas -FU"$OUT/t" -FE"$OUT/t" "pas/tests/$prog.pas" > "$OUT/fpc.log" 2>&1 \
    || { cat "$OUT/fpc.log"; exit 1; }
done
"$OUT/t/test_blake3$EXE" pas/tests/kat.txt | tail -1
"$OUT/t/test_arith$EXE" | tail -1
"$OUT/t/test_mpeg$EXE" tests | tail -1
"$OUT/t/test_codec$EXE" $SAMPLES tests/odd | tail -3
"$OUT/t/test_format$EXE" $SAMPLES | tail -1

echo "== the command"
$FPC -O3 -dPMPA_FAST -Fupas -Fipas -FU"$OUT/u" -o"$OUT/pmpa$EXE" pas/pmpacli.pas > "$OUT/fpc.log" 2>&1 \
  || { cat "$OUT/fpc.log"; exit 1; }
"$OUT/pmpa$EXE" --version
"$OUT/pmpa$EXE" a -q --output-dir="$OUT/p" tests/mp1/* tests/mp2/* tests/mp3/*
"$OUT/pmpa$EXE" x -q --output-dir="$OUT/x" "$OUT"/p/*.pmpa
n=0
for f in tests/mp1/* tests/mp2/* tests/mp3/*; do
  n=$((n + 1))
  cmp -s "$f" "$OUT/x/$(basename "$f")" || { echo "FAIL: $(basename "$f") does not come back"; exit 1; }
done
[ "$n" -ge 29 ] || { echo "FAIL: only $n samples"; exit 1; }
echo "$n samples back byte for byte"

echo "== the .pmpa files"
(cd "$OUT/p" && $SHA * | sed 's/ [ *]/  /' | sort) > "$OUT/pmpa.txt"
$SHA "$OUT/pmpa.txt" | cut -c1-64 > hash.txt
echo "$(wc -l < "$OUT/pmpa.txt" | tr -d ' ') files, SHA-256 of their list: $(cat hash.txt)"
