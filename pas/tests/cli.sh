#!/bin/bash
# The pmpa command, from the outside: round trips, and each refusal with
# nothing written where it must not be. Adapted from PJA's.
#
#   pas/tests/cli.sh <pmpa binary> <work directory> <dir with samples>...
set -uo pipefail
PMPA=$(realpath "$1"); W=$2; shift 2
cells=0; failures=0
check() {   # check <description> <command...>: the command has to succeed
  local what=$1; shift
  cells=$((cells + 1))
  if "$@" > /dev/null 2>&1; then printf '  %-66s ok\n' "$what"
  else printf '  %-66s FAIL\n' "$what"; failures=$((failures + 1)); fi
}
rc() { "$@" > /dev/null 2>&1; echo $?; }

rm -rf "$W"; mkdir -p "$W/in" "$W/out"
for d in "$@"; do cp "$d"/* "$W/in/"; done
# MPEG audio the codec cannot shrink: frames whose bodies are noise
python3 -I -c "
import random, sys
r = random.Random(1); d = bytearray()
for i in range(20): d += bytes([0xFF, 0xFB, 0x90, 0x64]) + bytes(r.randrange(256) for _ in range(413))
open(sys.argv[1], 'wb').write(d)" "$W/noise.mp3"
n=$(ls "$W/in" | wc -l)
check "samples: $n files" test "$n" -ge 10

echo "--- round trip of every sample"
check "a, all at once, into a directory" "$PMPA" a -q "$W"/in/* -o "$W/pmpa/"
check "  one .pmpa per input" test "$(ls "$W/pmpa" | wc -l)" -eq "$n"
check "x, all at once" "$PMPA" x -q "$W"/pmpa/*.pmpa -o "$W/out/"
same=0
for f in "$W"/in/*; do cmp -s "$f" "$W/out/$(basename "$f")" && same=$((same + 1)); done
check "  every file back byte for byte, with its extension ($same of $n)" test "$same" -eq "$n"
check "the same .pmpa with 1 thread and with 4" bash -c "
  '$PMPA' a -q -th 1 '$W/in/l3_cbr128_44k_joint.mp3' -o '$W/t1.pmpa' && '$PMPA' a -q --threads=4 '$W/in/l3_cbr128_44k_joint.mp3' -o '$W/t4.pmpa' &&
  cmp -s '$W/t1.pmpa' '$W/t4.pmpa'"
check "with -th 4 and several files, the lines follow the input order" bash -c "
  '$PMPA' a -th 4 -f '$W'/in/*.mp? -o '$W/ord/' | sed 's/ ->.*//' > '$W/ord.txt' &&
  ls '$W'/in/*.mp? > '$W/ord_in.txt' && cmp -s '$W/ord.txt' '$W/ord_in.txt'"
check "a file the codec cannot shrink is stored as is, and says so" bash -c "
  '$PMPA' a -f '$W/noise.mp3' -o '$W/st.pmpa' | grep -q 'stored as is' && '$PMPA' list '$W/st.pmpa' | grep -q 'stored as is' &&
  '$PMPA' x -q '$W/st.pmpa' -o '$W/st.mp3' && cmp -s '$W/noise.mp3' '$W/st.mp3'"
check "the extension comes back as written (song.MP3, take.Mp2)" bash -c "
  cp '$W/in/l3_cbr128_44k_joint.mp3' '$W/song.MP3' && cp '$W/in/l2_64k_32k_mono_crc.mp2' '$W/take.Mp2' &&
  '$PMPA' a -q -f '$W/song.MP3' '$W/take.Mp2' -o '$W/ext/' && '$PMPA' x -q '$W'/ext/*.pmpa -o '$W/extx/' &&
  cmp -s '$W/song.MP3' '$W/extx/song.MP3' && cmp -s '$W/take.Mp2' '$W/extx/take.Mp2'"
check "an extension the format does not keep: by the content (.mp1)" bash -c "
  cp '$W/in/l1_192k_44k_stereo.mp1' '$W/odd.x.y z' && '$PMPA' a -q -f '$W/odd.x.y z' -o '$W/odd.pmpa' &&
  '$PMPA' x -q '$W/odd.pmpa' -o '$W/oddx/' && cmp -s '$W/in/l1_192k_44k_stereo.mp1' '$W/oddx/odd.mp1'"
check "list shows the original size" bash -c "'$PMPA' list '$W/pmpa/l3_cbr128_44k_joint.pmpa' | grep -q 'original $(stat -c %s "$W/in/l3_cbr128_44k_joint.mp3") B'"

echo "--- existing outputs"
cp "$W/in/l2_64k_32k_mono_crc.mp2" "$W/g.mp2"; "$PMPA" a -q "$W/g.mp2"
echo old > "$W/g.mp2"
check "x over an existing file: refused (rc 1)" test "$(rc "$PMPA" x "$W/g.pmpa")" -eq 1
check "  and the file is untouched" test "$(cat "$W/g.mp2")" = old
check "with -f: replaced" "$PMPA" x -q -f "$W/g.pmpa"
check "  by the original" cmp -s "$W/g.mp2" "$W/in/l2_64k_32k_mono_crc.mp2"
echo victim > "$W/victim"; rm -f "$W/g.mp2"; ln -s "$W/victim" "$W/g.mp2"
check "a symbolic link with the output's name: refused" test "$(rc "$PMPA" x "$W/g.pmpa")" -eq 1
check "  with -f, the link is replaced" bash -c "'$PMPA' x -q -f '$W/g.pmpa' && [ ! -L '$W/g.mp2' ]"
check "  and its target never written through" test "$(cat "$W/victim")" = victim
rm -f "$W/g.mp2"; ln -s "$W/nowhere" "$W/g.mp2"
check "a dangling link also takes the name" test "$(rc "$PMPA" x "$W/g.pmpa")" -eq 1
check "  and nothing is created where it points" test ! -e "$W/nowhere"
rm -f "$W/g.mp2"

echo plain > "$W/plain"
check "a write the system refuses: its own words, not just a number" bash -c "
  ! '$PMPA' a '$W/in/l2_64k_32k_mono_crc.mp2' -o '$W/plain/x.pmpa' 2> '$W/err.txt' && grep -q 'could not write it: [A-Za-z]' '$W/err.txt'"
echo "--- what does not verify"
python3 -I -c "
import sys; d = bytearray(open(sys.argv[1], 'rb').read()); d[20] ^= 1; open(sys.argv[2], 'wb').write(d)" "$W/g.pmpa" "$W/h.pmpa"
check "a .pmpa with one hash bit changed: rc 1" test "$(rc "$PMPA" x "$W/h.pmpa")" -eq 1
check "  nothing written under the name" test ! -e "$W/h.mp2"
check "with --keep-corrupt: still rc 1" test "$(rc "$PMPA" x --keep-corrupt "$W/h.pmpa")" -eq 1
check "  kept as h.mp2.corrupt, not as h.mp2" bash -c "[ -e '$W/h.mp2.corrupt' ] && [ ! -e '$W/h.mp2' ]"
python3 -I -c "
import sys; d = bytearray(open(sys.argv[1], 'rb').read()); d[-20] ^= 4; open(sys.argv[2], 'wb').write(d)" "$W/g.pmpa" "$W/p.pmpa"
check "one bit in the stream: rc 1, nothing written" bash -c "! '$PMPA' x '$W/p.pmpa' 2>/dev/null && [ ! -e '$W/p.mp2' ]"
check "--max-output below the original: refused" test "$(rc "$PMPA" x --max-output=100 "$W/g.pmpa" -o "$W/m.mp2")" -eq 1
check "  nothing written" test ! -e "$W/m.mp2"
check "--max-output=8K is enough for an 8064-byte original" "$PMPA" x -q --max-output=8K "$W/g.pmpa" -o "$W/m.mp2"

echo "--- what is not for this command"
check "a on a .pmpa: rc 1" test "$(rc "$PMPA" a "$W/g.pmpa" -o "$W/gg.pmpa")" -eq 1
check "x on an MP2: rc 1" test "$(rc "$PMPA" x "$W/in/l2_64k_32k_mono_crc.mp2" -o "$W/xx.mp2")" -eq 1
echo "not MPEG audio" > "$W/text.mp2"
check "a on something else: rc 1, says why, nothing written" bash -c "
  ! '$PMPA' a '$W/text.mp2' 2> '$W/err2.txt' && grep -q 'not MPEG audio PMPA takes' '$W/err2.txt' && [ ! -e '$W/text.pmpa' ]"
printf 'ID3\003\000\000\000\000\000\012TIT2\000\000\000\000\000\000' > "$W/tag.mp3"
check "an ID3v2 tag and no frame: rc 1, says why" bash -c "
  ! '$PMPA' a '$W/tag.mp3' 2> '$W/err3.txt' && grep -q 'no MPEG audio frames' '$W/err3.txt'"
check "one bad among good ones: rc 1" test "$(rc "$PMPA" a "$W/text.mp2" "$W/in/l2_64k_32k_mono_crc.mp2" -o "$W/mix/")" -eq 1
check "  and the good one is written" test -e "$W/mix/l2_64k_32k_mono_crc.pmpa"
check "a directory as input: rc 1" test "$(rc "$PMPA" a "$W/in")" -eq 1
check "a missing input: rc 1" test "$(rc "$PMPA" a "$W/missing.mp2")" -eq 1

echo "--- options"
check "-n writes nothing" bash -c "'$PMPA' a -q -n '$W/in/l2_64k_32k_mono_crc.mp2' -o '$W/dry.pmpa' && [ ! -e '$W/dry.pmpa' ]"
cp "$W/in/l2_64k_32k_mono_crc.mp2" "$W/-dash.mp2"
check "-- and a file that starts with a dash" bash -c "cd '$W' && '$PMPA' a -q -- -dash.mp2 && [ -e '-dash.pmpa' ]"
check "-o with several inputs and no directory: rc 2" test "$(rc "$PMPA" a "$W/in/l2_64k_32k_mono_crc.mp2" "$W/in/l3_cbr128_44k_joint.mp3" -o "$W/one.pmpa")" -eq 2
cp "$W/in/l2_64k_32k_mono_crc.mp2" "$W/歌ñ.mp2"
check "a non-ASCII name, both ways" bash -c "'$PMPA' a -q '$W/歌ñ.mp2' -o '$W/u.pmpa' && '$PMPA' x -q '$W/u.pmpa' -o '$W/歌ñ2.mp2' &&
  cmp -s '$W/歌ñ.mp2' '$W/歌ñ2.mp2'"
check "--output-dir" bash -c "'$PMPA' a -q '$W/in/l2_64k_32k_mono_crc.mp2' --output-dir='$W/od' && [ -e '$W/od/l2_64k_32k_mono_crc.pmpa' ]"
check "an unknown option: rc 2" test "$(rc "$PMPA" a --frobnicate "$W/in/l2_64k_32k_mono_crc.mp2")" -eq 2
check "a glued -th4: rc 2, naming the spelling" bash -c "'$PMPA' a -th4 x.mp2 2>&1 | grep -q 'write -th 4'"
check "an unknown command: rc 2" test "$(rc "$PMPA" mix "$W/in/l2_64k_32k_mono_crc.mp2")" -eq 2
check "no files: rc 2" test "$(rc "$PMPA" a)" -eq 2
check "--help: rc 0" "$PMPA" --help

echo "$cells cells, $failures failures"
[ "$failures" -eq 0 ] && [ "$cells" -ge 40 ]
