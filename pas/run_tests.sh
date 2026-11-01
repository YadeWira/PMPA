#!/bin/bash
# The whole suite, layer by layer: each test is built with range and
# overflow checks on (the reference build) and demands its own minimum cell
# count: a test that runs zero cells is not green.
#
# Paths are relative to the repository's root: on Windows a native fpc does
# not understand MSYS's absolute paths (/d/a/...).
set -euo pipefail
FPC=${FPC:-fpc}
cd "$(dirname "$0")/.."
OUT=${PAS_OUT:-pas/build/tests}
SAMPLES="tests/mp1 tests/mp2 tests/mp3"
mkdir -p "$OUT"

echo "== source guards"
python3 pas/collisions.py pas

echo "== build"
for prog in test_blake3 test_arith test_mpeg test_l3 test_l12 test_codec test_format test_pmpafs; do
  $FPC -O2 -Fupas -Fipas -FU"$OUT" -FE"$OUT" "pas/tests/$prog.pas" > "$OUT/fpc.log" 2>&1 \
    || { cat "$OUT/fpc.log"; exit 1; }
done

echo "== tests"
"$OUT/test_blake3" pas/tests/kat.txt | tail -1
"$OUT/test_arith" | tail -1
"$OUT/test_mpeg" tests | tail -1
"$OUT/test_l3" -q tests/mp3 tests/odd | tail -1
"$OUT/test_l12" -q tests/mp1 tests/mp2 | tail -1
"$OUT/test_codec" $SAMPLES tests/odd > "$OUT/codec.txt" || { cat "$OUT/codec.txt"; exit 1; }
tail -3 "$OUT/codec.txt" | head -1
"$OUT/test_format" $SAMPLES | tail -1
# pmpafs touches the disk: a directory of its own
rm -rf "$OUT/tmp_fs"; mkdir -p "$OUT/tmp_fs"; "$OUT/test_pmpafs" "$(realpath "$OUT/tmp_fs")" | tail -1

echo "== the command"
mkdir -p "$OUT/cli"
$FPC -O3 -dPMPA_FAST -Fupas -Fipas -FU"$OUT/cli" -o"$OUT/pmpa" pas/pmpacli.pas > "$OUT/fpc.log" 2>&1 \
  || { cat "$OUT/fpc.log"; exit 1; }
pas/tests/cli.sh "$OUT/pmpa" "$OUT/tmp_cli" $SAMPLES | tail -1

echo "== the fast build makes the same streams"
mkdir -p "$OUT/fast"
$FPC -O3 -dPMPA_FAST -Fupas -Fipas -FU"$OUT/fast" -FE"$OUT/fast" pas/tests/test_codec.pas > "$OUT/fpc.log" 2>&1 \
  || { cat "$OUT/fpc.log"; exit 1; }
"$OUT/fast/test_codec" $SAMPLES tests/odd > "$OUT/codec_fast.txt" || { cat "$OUT/codec_fast.txt"; exit 1; }
a=$(grep '^streams ' "$OUT/codec.txt"); b=$(grep '^streams ' "$OUT/codec_fast.txt")
[ -n "$a" ] && [ "$a" = "$b" ] || { echo "FAIL: checked $a, fast $b"; exit 1; }
echo "$a"
echo "== the assembly makes the same streams as the Pascal (PMPA_NOASM=1)"
PMPA_NOASM=1 "$OUT/fast/test_codec" $SAMPLES tests/odd > "$OUT/codec_noasm.txt" || { cat "$OUT/codec_noasm.txt"; exit 1; }
c=$(grep '^streams ' "$OUT/codec_noasm.txt")
[ "$a" = "$c" ] || { echo "FAIL: assembly $a, Pascal $c"; exit 1; }
echo "$c"
echo "all green"
