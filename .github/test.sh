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
SAMPLES="tests/mp1 tests/mp2 tests/mp3 tests/covers"
case "$(uname -s)" in MINGW*|MSYS*|CYGWIN*) EXE=.exe ;; *) EXE= ;; esac
if command -v sha256sum > /dev/null; then SHA="sha256sum"; else SHA="shasum -a 256"; fi
rm -rf "$OUT"; mkdir -p "$OUT/u" "$OUT/t" "$OUT/p" "$OUT/x"

echo "== the C part"
# CC: the platform's C compiler. A compiler given by its full path (MSYS2's
# MinGW-w64 gcc on Windows) needs its own folder on PATH for its DLLs and
# its cc1/as; without it, it fails without a word (PJA found it).
case ${CC:-} in /*) PATH=$(dirname "$CC"):$PATH; export PATH ;; esac
sh pas/build_c.sh "$OUT/c" || { echo "the C part did not build (CC=${CC:-cc})"; exit 1; }

echo "== layer tests"
for prog in test_blake3 test_arith test_mpeg test_l3 test_l12 test_id3 test_codec test_format; do
  $FPC -O2 -Fupas -Fipas -Fuvendor/pja/pas -Fivendor/pja/pas -Fo"$OUT/c" -FU"$OUT/t" -FE"$OUT/t" "pas/tests/$prog.pas" > "$OUT/fpc.log" 2>&1 \
    || { cat "$OUT/fpc.log"; exit 1; }
done
"$OUT/t/test_blake3$EXE" pas/tests/kat.txt | tail -1
"$OUT/t/test_arith$EXE" | tail -1
"$OUT/t/test_mpeg$EXE" tests | tail -1
"$OUT/t/test_l3$EXE" -q tests/mp3 tests/odd | tail -1
"$OUT/t/test_l12$EXE" -q tests/mp1 tests/mp2 | tail -1
"$OUT/t/test_id3$EXE" tests/covers | tail -1
"$OUT/t/test_codec$EXE" $SAMPLES tests/odd > "$OUT/codec.txt" || { cat "$OUT/codec.txt"; exit 1; }
tail -3 "$OUT/codec.txt"
# the C and the Pascal write the same streams
PMPA_NOC=1 "$OUT/t/test_codec$EXE" $SAMPLES tests/odd > "$OUT/codec_noc.txt" || { cat "$OUT/codec_noc.txt"; exit 1; }
a=$(grep '^streams ' "$OUT/codec.txt"); b=$(grep '^streams ' "$OUT/codec_noc.txt")
[ -n "$a" ] && [ "$a" = "$b" ] || { echo "FAIL: C $a, Pascal $b"; exit 1; }
echo "the C and the Pascal: the same streams"
"$OUT/t/test_format$EXE" $SAMPLES | tail -1

echo "== the command"
# the commit, for --version and report (release.yml sets it from the tag)
if [ -z "${PMPA_COMMIT:-}" ]; then PMPA_COMMIT=$(git rev-parse --short HEAD 2>/dev/null || true); fi
export PMPA_COMMIT
$FPC -O3 -dPMPA_FAST -dPJA_FAST -Fupas -Fipas -Fuvendor/pja/pas -Fivendor/pja/pas -Fo"$OUT/c" -FU"$OUT/u" -o"$OUT/pmpa$EXE" pas/pmpacli.pas > "$OUT/fpc.log" 2>&1 \
  || { cat "$OUT/fpc.log"; exit 1; }
"$OUT/pmpa$EXE" --version
# the samples inside the binary, on every SIMD path here
"$OUT/pmpa$EXE" selftest -q
"$OUT/pmpa$EXE" a -q --output-dir="$OUT/p" tests/mp1/* tests/mp2/* tests/mp3/* tests/covers/*
"$OUT/pmpa$EXE" x -q --output-dir="$OUT/x" "$OUT"/p/*.pmpa
n=0
for f in tests/mp1/* tests/mp2/* tests/mp3/* tests/covers/*; do
  n=$((n + 1))
  cmp -s "$f" "$OUT/x/$(basename "$f")" || { echo "FAIL: $(basename "$f") does not come back"; exit 1; }
done
[ "$n" -ge 41 ] || { echo "FAIL: only $n samples"; exit 1; }
echo "$n samples back byte for byte"

echo "== libpmpa"
sh pas/lib/build.sh "$OUT/lib" > "$OUT/lib.log" 2>&1 || { cat "$OUT/lib.log"; echo "FAIL: libpmpa did not build"; exit 1; }
LIBF=$(tail -1 "$OUT/lib.log")
# its C objects call no library (the DLL has no C runtime); their own
# symbols aside (pmpa7z.o calls pmpafilter.o), and the GOT the linker makes
if [ "$(uname -s)" = Linux ] && command -v nm > /dev/null; then
  nm "$OUT"/lib/c/*.o | awk '$2 ~ /^[TDBR]$/ {print $3}' | sort -u > "$OUT/lib/defined.txt"
  nm -u "$OUT"/lib/c/*.o | awk 'NF {print $NF}' | grep -v ':$' | grep -vx '_GLOBAL_OFFSET_TABLE_' | sort -u | comm -23 - "$OUT/lib/defined.txt" > "$OUT/lib/undefined.txt"
  if [ -s "$OUT/lib/undefined.txt" ]; then cat "$OUT/lib/undefined.txt"; echo "FAIL: libpmpa's C objects need a library"; exit 1; fi
fi
# the test finds the library by its rpath alone (on macOS its install name
# is @rpath/pmpa.dylib, not the path it was built at)
RP=; case "$(uname -s)" in Linux) RP="-pthread -Wl,-rpath,$(dirname "$LIBF")" ;; Darwin) RP="-Wl,-rpath,$(dirname "$LIBF")" ;; esac
if [ "$(uname -s)" = Darwin ]; then
  ID=$(otool -D "$LIBF" | tail -1)
  [ "$ID" = "@rpath/pmpa.dylib" ] || { echo "FAIL: libpmpa's install name is $ID"; exit 1; }
fi
# shellcheck disable=SC2086
${CC:-cc} -O2 -Ipas/lib pas/lib/test_lib.c -o "$OUT/lib/test_lib$EXE" "$LIBF" $RP
# the command's settings set here: the library must not take them from the
# host's environment
PMPA_NOC=1 PMPA_NOASM=1 "$OUT/lib/test_lib$EXE" tests/mp1/* tests/mp2/* tests/mp3/* tests/covers/* README.md > "$OUT/lib/test.txt" \
  || { cat "$OUT/lib/test.txt"; echo "FAIL: libpmpa's test"; exit 1; }
tail -3 "$OUT/lib/test.txt"
# 7-Zip 23 or later (not p7zip): a copy with the plugin in its Codecs
# folder (the same word size as the library), an archive written and
# extracted. Linux: 7-Zip's package; Windows: the 64-bit 7-Zip installed
# (a 32-bit library: SEVEN32, if set)
case "$LIBF" in
  *.dll) SEVEN="/c/Program Files/7-Zip"; SLIB=7z.dll ;;
  *.so) SEVEN=/usr/lib/7zip; SLIB=7z.so ;;
  *) SEVEN=; SLIB= ;;
esac
case "${CC:-} $FPC" in *-m32*|*i386*|*mingw32*) SEVEN=${SEVEN32:-} ;; esac
if [ -z "$SEVEN" ] || [ ! -f "$SEVEN/$SLIB" ] || [ ! -f "$SEVEN/7z$EXE" ]; then
  echo "7-Zip: none of the library's word size here, not tried"
else
  Z="$OUT/7z"; rm -rf "$Z"; mkdir -p "$Z/Codecs" "$OUT/7in" "$OUT/7x"
  cp "$SEVEN/7z$EXE" "$SEVEN/$SLIB" "$Z/"
  cp "$LIBF" "$Z/Codecs/"
  cp tests/mp1/* tests/mp2/* tests/mp3/* tests/covers/* README.md "$OUT/7in/"
  "$Z/7z$EXE" i | grep -q '37F20 PMPA' || { echo "FAIL: 7-Zip does not list PMPA (37F20)"; exit 1; }
  (cd "$OUT/7in" && "../7z/7z$EXE" a -bso0 -bsp0 -m0=PMPA -m1=LZMA2 ../a.7z .)
  "$Z/7z$EXE" x -bso0 -bsp0 -o"$OUT/7x" "$OUT/a.7z"
  for f in "$OUT"/7in/*; do
    cmp -s "$f" "$OUT/7x/$(basename "$f")" || { echo "FAIL: 7-Zip: $(basename "$f") does not come back"; exit 1; }
  done
  echo "7-Zip with the PMPA plugin: every sample back, $(wc -c < "$OUT/a.7z" | tr -d ' ') bytes"
fi

echo "== the .pmpa files"
(cd "$OUT/p" && $SHA * | sed 's/ [ *]/  /' | sort) > "$OUT/pmpa.txt"
$SHA "$OUT/pmpa.txt" | cut -c1-64 > hash.txt
echo "$(wc -l < "$OUT/pmpa.txt" | tr -d ' ') files, SHA-256 of their list: $(cat hash.txt)"
