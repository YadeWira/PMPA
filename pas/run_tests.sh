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
SAMPLES="tests/mp1 tests/mp2 tests/mp3 tests/covers"
mkdir -p "$OUT"

echo "== source guards"
python3 pas/collisions.py pas

echo "== the 7-Zip plugin's version is PMPA_VERSION"
python3 -I -c "
import re, sys
v = re.search(r\"PMPA_VERSION = '(\\d+)\\.(\\d+)\\.(\\d+)'\", open('pas/pmpacodec.pas').read()).groups()
m = re.search(r'\\((\\d+)u << 16\\) \\| (\\d+)u; }   /\\* 0', open('pas/lib/pmpa7z.c').read()).groups()
want = (v[0], v[1] + v[2])
sys.exit(0 if (m[0], m[1]) == want else 'pmpa7z.c says %s.%s, PMPA_VERSION %s' % (m[0], m[1], '.'.join(v)))" || exit 1
echo "pmpa7z.c: the version is PMPA_VERSION"

echo "== the C part"
sh pas/build_c.sh "$OUT/c" > "$OUT/cc.log" 2>&1 || { cat "$OUT/cc.log"; exit 1; }

echo "== build"
for prog in test_blake3 test_arith test_mpeg test_l3 test_l12 test_id3 test_codec test_format test_pmpafs; do
  $FPC -O2 -Fupas -Fipas -Fuvendor/pja/pas -Fivendor/pja/pas -Fo"$OUT/c" -FU"$OUT" -FE"$OUT" "pas/tests/$prog.pas" > "$OUT/fpc.log" 2>&1 \
    || { cat "$OUT/fpc.log"; exit 1; }
done

echo "== tests"
"$OUT/test_blake3" pas/tests/kat.txt | tail -1
"$OUT/test_arith" | tail -1
"$OUT/test_mpeg" tests | tail -1
"$OUT/test_l3" -q tests/mp3 tests/odd | tail -1
"$OUT/test_l12" -q tests/mp1 tests/mp2 | tail -1
"$OUT/test_id3" tests/covers | tail -1
"$OUT/test_codec" $SAMPLES tests/odd > "$OUT/codec.txt" || { cat "$OUT/codec.txt"; exit 1; }
tail -3 "$OUT/codec.txt" | head -1
"$OUT/test_format" $SAMPLES | tail -1
# pmpafs touches the disk: a directory of its own
rm -rf "$OUT/tmp_fs"; mkdir -p "$OUT/tmp_fs"; "$OUT/test_pmpafs" "$(realpath "$OUT/tmp_fs")" | tail -1

echo "== the selftest's samples are the codec's current streams"
$FPC -O2 -Fupas -Fipas -Fuvendor/pja/pas -Fivendor/pja/pas -Fo"$OUT/c" -FU"$OUT" -FE"$OUT" pas/tests/gen_selftest.pas > "$OUT/fpc.log" 2>&1 \
  || { cat "$OUT/fpc.log"; exit 1; }
"$OUT/gen_selftest" tests "$OUT/selftest.inc" > /dev/null
cmp -s "$OUT/selftest.inc" pas/pmpaselftest.inc || { echo "FAIL: pas/pmpaselftest.inc is old: run gen_selftest tests pas/pmpaselftest.inc"; exit 1; }
echo "pas/pmpaselftest.inc current"

echo "== the command"
if [ -z "${PMPA_COMMIT:-}" ]; then PMPA_COMMIT=$(git rev-parse --short HEAD 2>/dev/null || true); fi
export PMPA_COMMIT
mkdir -p "$OUT/cli"
$FPC -O3 -dPMPA_FAST -dPJA_FAST -Fupas -Fipas -Fuvendor/pja/pas -Fivendor/pja/pas -Fo"$OUT/c" -FU"$OUT/cli" -o"$OUT/pmpa" pas/pmpacli.pas > "$OUT/fpc.log" 2>&1 \
  || { cat "$OUT/fpc.log"; exit 1; }
pas/tests/cli.sh "$OUT/pmpa" "$OUT/tmp_cli" $SAMPLES | tail -1

echo "== the fast build makes the same streams"
mkdir -p "$OUT/fast"
$FPC -O3 -dPMPA_FAST -dPJA_FAST -Fupas -Fipas -Fuvendor/pja/pas -Fivendor/pja/pas -Fo"$OUT/c" -FU"$OUT/fast" -FE"$OUT/fast" pas/tests/test_codec.pas > "$OUT/fpc.log" 2>&1 \
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
echo "== the C makes the same streams as the Pascal (PMPA_NOC=1)"
PMPA_NOC=1 "$OUT/fast/test_codec" $SAMPLES tests/odd > "$OUT/codec_noc.txt" || { cat "$OUT/codec_noc.txt"; exit 1; }
c=$(grep '^streams ' "$OUT/codec_noc.txt")
[ "$a" = "$c" ] || { echo "FAIL: C $a, Pascal $c"; exit 1; }
echo "$c"
echo "all green"
