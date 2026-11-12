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

# Tables a codec builds on first use, when two threads get there at once,
# were an access violation once (01/11/2026): each process's first files
# go to 8 threads at once, 20 times over
check "20 runs of x and a with -th 8: no thread trips over another" bash -c "
  for k in \$(seq 1 20); do
    rm -rf '$W/race'; mkdir -p '$W/race/p' '$W/race/x'
    '$PMPA' x -q -th 8 '$W'/pmpa/*.pmpa -o '$W/race/x/' || exit 1
    '$PMPA' a -q -th 8 '$W'/in/*.mp? -o '$W/race/p/' || exit 1
  done"

# a file of two bands or more is coded on every thread before the small
# ones: a 4.3 MB one (a sample 250 times over) among small ones, lines in
# the order of the inputs, every file back
python3 -I -c "
import sys; d = open(sys.argv[1], 'rb').read(); open(sys.argv[2], 'wb').write(d * 250)" "$W/in/l3_cbr128_44k_joint.mp3" "$W/big.mp3"
mkdir -p "$W/mixin"; cp "$W/in/l2_64k_32k_mono_crc.mp2" "$W/mixin/a.mp2"; cp "$W/big.mp3" "$W/mixin/b.mp3"; cp "$W/in/l1_192k_44k_stereo.mp1" "$W/mixin/c.mp1"
check "a big file among small ones, -th 4: lines in the order of the inputs" bash -c "
  '$PMPA' a -th 4 '$W'/mixin/* -o '$W/mixp/' | sed 's/ ->.*//' > '$W/mix.txt' &&
  ls '$W'/mixin/* > '$W/mix_in.txt' && cmp -s '$W/mix.txt' '$W/mix_in.txt'"
check "  and every file back, on 4 threads" bash -c "
  '$PMPA' x -q -th 4 '$W'/mixp/*.pmpa -o '$W/mixx/' &&
  cmp -s '$W/mixin/a.mp2' '$W/mixx/a.mp2' && cmp -s '$W/mixin/b.mp3' '$W/mixx/b.mp3' && cmp -s '$W/mixin/c.mp1' '$W/mixx/c.mp1'"
check "  the big file's .pmpa the same on 1 thread" bash -c "
  '$PMPA' a -q -th 1 '$W/mixin/b.mp3' -o '$W/b1.pmpa' && cmp -s '$W/b1.pmpa' '$W/mixp/b.pmpa'"

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
# a damaged declared size (issue #1): larger, and smaller, than the stream's
python3 -I -c "
import struct, sys
d = bytearray(open(sys.argv[1], 'rb').read()); n = struct.unpack_from('<Q', d, 8)[0]
for name, v in (('sz_big', n + 1000), ('sz_small', n - 1000)):
    e = bytearray(d); struct.pack_into('<Q', e, 8, v); open(sys.argv[2] + '/' + name + '.pmpa', 'wb').write(e)" "$W/g.pmpa" "$W"
check "a .pmpa whose declared size is too large: rc 1, nothing written" bash -c "
  ! '$PMPA' x '$W/sz_big.pmpa' 2>/dev/null && [ ! -e '$W/sz_big.mp2' ]"
check "  with --keep-corrupt: kept as sz_big.mp2.corrupt (issue #1)" bash -c "
  ! '$PMPA' x --keep-corrupt '$W/sz_big.pmpa' 2>/dev/null && [ ! -e '$W/sz_big.mp2' ] &&
  cmp -s '$W/sz_big.mp2.corrupt' '$W/in/l2_64k_32k_mono_crc.mp2'"
check "  too small: kept as well, all the stream gives" bash -c "
  ! '$PMPA' x --keep-corrupt '$W/sz_small.pmpa' 2>/dev/null && [ ! -e '$W/sz_small.mp2' ] &&
  cmp -s '$W/sz_small.mp2.corrupt' '$W/in/l2_64k_32k_mono_crc.mp2'"
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

echo "--- interrupted runs, and the disk (PJA's checks)"
# strace with fault injection holds the write at its fsync, between a
# complete temporary and its rename, for as long as the test needs: the
# signal lands exactly there. Without it, the signal is sent as soon as a
# temporary shows up (a race the write usually wins: a weaker check).
mkdir -p "$W/sig"
for i in $(seq 24); do cp "$W/pmpa/l3_cbr128_44k_joint.pmpa" "$W/sig/c$i.pmpa"; done
HOLD=0
if command -v strace > /dev/null 2>&1 &&
   strace -f -qq -o /dev/null -e trace=fsync -e inject=fsync:delay_enter=1ms true > /dev/null 2>&1; then HOLD=1; fi
cat > "$W/sig.py" <<'EOF'
import glob, os, signal, subprocess, sys, time
pmpa, d, sig, hold, ignore = sys.argv[1], sys.argv[2], getattr(signal, sys.argv[3]), sys.argv[4] == '1', sys.argv[5] == '1'
out = os.path.join(d, 'o')
files = sorted(glob.glob(os.path.join(d, 'c*.pmpa')))[:1 if ignore else None]
cmd = [pmpa, 'x', '-q', '-f', '-th', '1'] + files + ['-o', out + '/']
if hold:
    cmd = ['strace', '-f', '-qq', '-o', '/dev/null', '-e', 'trace=fsync', '-e', 'inject=fsync:delay_enter=3s'] + cmd
def pre():
    signal.signal(sig, signal.SIG_IGN if ignore else signal.SIG_DFL)
p = subprocess.Popen(cmd, preexec_fn=pre)
def state(pid):
    try: return open('/proc/%d/stat' % pid).read().rsplit(')', 1)[1].split()[0]
    except (OSError, IndexError): return ''
seen, t0 = False, time.time()
while time.time() - t0 < 120 and p.poll() is None:
    if glob.glob(os.path.join(out, '.pmpa-tmp-*')): seen = True; break
    time.sleep(0.005)
target = p.pid
if hold and seen and p.poll() is None:
    target = int(open('/proc/%d/task/%d/children' % (p.pid, p.pid)).read().split()[0])
    run, t1 = 0, time.time()
    while run < 5 and time.time() - t1 < 60 and p.poll() is None:
        run = run + 1 if state(target) == 't' else 0
        time.sleep(0.02)
if p.poll() is None: os.kill(target, sig)
rc = p.wait()
rc = 128 - rc if rc < 0 else rc
left = glob.glob(os.path.join(out, '.pmpa-tmp-*'))
print(rc, 'seen' if seen else 'missed', len(left))
EOF
sigcheck() {   # sigcheck <signal> <rc> [ignore]: no temporary left, and the conventional rc
  rm -rf "$W/sig/o"
  local r; r=$(python3 -I "$W/sig.py" "$PMPA" "$W/sig" "$1" "$HOLD" "${3:-0}") || return 1
  set -- $r "$2"
  [ "$3" -eq 0 ] || return 1
  if [ "$HOLD" = 1 ]; then [ "$2" = seen ] && [ "$1" -eq "$4" ]
  else [ "$1" -eq "$4" ] || [ "$1" -eq 0 ]; fi
}
if [ "$HOLD" = 1 ]; then how="held at its fsync"; else how="strace not here: racy"; fi
check "SIGINT while a temporary is written: deleted, rc 130 ($how)" sigcheck SIGINT 130
check "SIGTERM: the same, rc 143" sigcheck SIGTERM 143
check "SIGHUP: the same, rc 129" sigcheck SIGHUP 129
check "SIGPIPE: the same, rc 141" sigcheck SIGPIPE 141
if [ "$HOLD" = 1 ]; then
  check "a SIGINT ignored by whoever started it (nohup) stays ignored: rc 0" bash -c "
    r=\$(python3 -I '$W/sig.py' '$PMPA' '$W/sig' SIGINT 1 1) && [ \"\$r\" = '0 seen 0' ] && [ -e '$W/sig/o/c1.mp3' ]"
  check "the data and then the directory reach the disk: fsync, rename, fsync" bash -c "
    strace -f -qq -o '$W/sync.txt' -e trace=fsync,rename,renameat2,link '$PMPA' a -q -f '$W/in/l2_64k_32k_mono_crc.mp2' -o '$W/sync.pmpa' &&
    grep -oE '^[0-9]+ +(fsync|rename|renameat2|link)\(' '$W/sync.txt' | sed -E 's/^[0-9]+ +//; s/renameat2|link/rename/' | tr -d '(' |
      tr '\n' ' ' | grep -qx 'fsync rename fsync '"
  check "the directory flush fails: rc 1, and the message says the file is there" bash -c "
    rm -f '$W/sync4.pmpa'
    ! strace -f -qq -o /dev/null -e trace=fsync -e inject=fsync:error=EIO:when=2 '$PMPA' a -q '$W/in/l2_64k_32k_mono_crc.mp2' -o '$W/sync4.pmpa' 2> '$W/sync4.txt' &&
    grep -q 'sync4.pmpa: written, but its directory could not be flushed to the disk' '$W/sync4.txt' && [ -s '$W/sync4.pmpa' ]"
  check "  the data flush fails: rc 1, nothing left, not even a temporary" bash -c "
    rm -rf '$W/sync5'; mkdir '$W/sync5'
    ! strace -f -qq -o /dev/null -e trace=fsync -e inject=fsync:error=EIO:when=1 '$PMPA' a -q '$W/in/l2_64k_32k_mono_crc.mp2' -o '$W/sync5/g.pmpa' 2> '$W/sync5.txt' &&
    grep -q 'could not write it' '$W/sync5.txt' && [ -z \"\$(ls -A '$W/sync5')\" ]"
  check "--no-sync: no fsync at all, and the file comes back" bash -c "
    strace -f -qq -o '$W/sync3.txt' -e trace=fsync,fdatasync '$PMPA' a -q -f --no-sync '$W/in/l2_64k_32k_mono_crc.mp2' -o '$W/sync3.pmpa' &&
    ! grep -qE 'fsync|fdatasync' '$W/sync3.txt' && '$PMPA' x -q -f '$W/sync3.pmpa' -o '$W/sync3.mp2' && cmp -s '$W/sync3.mp2' '$W/in/l2_64k_32k_mono_crc.mp2'"
else
  check "--no-sync: the file comes back" bash -c "
    '$PMPA' a -q -f --no-sync '$W/in/l2_64k_32k_mono_crc.mp2' -o '$W/sync3.pmpa' && '$PMPA' x -q -f --no-sync '$W/sync3.pmpa' -o '$W/sync3.mp2' &&
    cmp -s '$W/sync3.mp2' '$W/in/l2_64k_32k_mono_crc.mp2'"
fi
L="$W/left"; rm -rf "$L"; mkdir -p "$L"; cp "$W/in/l2_64k_32k_mono_crc.mp2" "$L/g.mp2"
sh -c 'exit 0' & wait $!; DEAD=$!
while kill -0 "$DEAD" 2> /dev/null; do DEAD=$((DEAD + 1)); done
mk() { echo left > "$L/$1"; touch -d "${2:-2 hours ago}" "$L/$1"; }
mk ".pmpa-tmp-$DEAD-0"; mk "g.pmpa.pmpa-tmp4"           # old, of a dead run (and of 0.2.0)
mk ".pmpa-tmp-$DEAD-1" now                              # fresh: maybe still being written
mk ".pmpa-tmp-$$-0"                                     # old, but its process (this shell) lives
mk ".pmpa-tmp-$DEAD-x"                                  # not PMPA's pattern
echo victim > "$W/left_victim"; ln -s "$W/left_victim" "$L/.pmpa-tmp-$DEAD-2"; touch -h -d '2 hours ago' "$L/.pmpa-tmp-$DEAD-2"
check "a run that writes there names the leftovers, rc 0, deletes nothing" bash -c "
  '$PMPA' a -q '$L/g.mp2' 2> '$W/left.txt' && grep -q 'found 2 leftover temporaries of an interrupted run' '$W/left.txt' &&
  grep -q -- '--clean-temps' '$W/left.txt' && [ -e '$L/.pmpa-tmp-$DEAD-0' ] && [ -e '$L/g.pmpa.pmpa-tmp4' ]"
check "--clean-temps deletes the old one of a dead pid and 0.2.0's" bash -c "
  '$PMPA' a -q -f --clean-temps '$L/g.mp2' 2> '$W/left2.txt' && grep -q 'deleted 2 leftover temporaries' '$W/left2.txt' &&
  [ ! -e '$L/.pmpa-tmp-$DEAD-0' ] && [ ! -e '$L/g.pmpa.pmpa-tmp4' ]"
check "  not a fresh one, not a live process's, not another name, not a link" bash -c "
  [ -e '$L/.pmpa-tmp-$DEAD-1' ] && [ -e '$L/.pmpa-tmp-$$-0' ] && [ -e '$L/.pmpa-tmp-$DEAD-x' ] &&
  [ -L '$L/.pmpa-tmp-$DEAD-2' ] && [ \"\$(cat '$W/left_victim')\" = victim ]"
check "--clean-temps with list: rc 2" test "$(rc "$PMPA" list --clean-temps "$W/g.pmpa")" -eq 2
check "--no-verify: the same .pmpa" bash -c "
  '$PMPA' a -q -f --no-verify '$W/in/l3_cbr128_44k_joint.mp3' -o '$W/nv.pmpa' && cmp -s '$W/nv.pmpa' '$W/pmpa/l3_cbr128_44k_joint.pmpa'"
check "--no-verify is for a: rc 2" test "$(rc "$PMPA" x --no-verify "$W/g.pmpa")" -eq 2

echo "--- version, selftest, --cpu"
check "--version: the build, the system and the path" bash -c "
  o=\$('$PMPA' --version) && grep -q '^pmpa ' <<< \"\$o\" && grep -q '^cpu_path: ' <<< \"\$o\" && grep -q '^stream_version: ' <<< \"\$o\""
check "selftest: every check passed, rc 0" bash -c "'$PMPA' selftest | grep -q 'checks passed'"
check "selftest -q: the summary alone" bash -c "[ \$('$PMPA' selftest -q | wc -l) -eq 1 ]"
check "selftest has an older stream version, only extracted" bash -c "'$PMPA' selftest | grep -q '(version 7): '"
PATHS=$("$PMPA" --version | sed -n 's/^cpu_paths_supported: //p')
check "--cpu: every path here ($PATHS) gives the very same .pmpa" bash -c "
  for p in $PATHS; do
    '$PMPA' --cpu=\$p a -q -f '$W/in/l3_cbr128_44k_joint.mp3' '$W/in/l2_64k_32k_mono_crc.mp2' -o '$W/cpu_'\$p/ || exit 1
    cmp -s '$W/cpu_'\$p/l3_cbr128_44k_joint.pmpa '$W/pmpa/l3_cbr128_44k_joint.pmpa' || exit 1
    cmp -s '$W/cpu_'\$p/l2_64k_32k_mono_crc.pmpa '$W/pmpa/l2_64k_32k_mono_crc.pmpa' || exit 1
  done"
check "selftest --cpu=plain: that path alone" bash -c "'$PMPA' selftest --cpu=plain -q | grep -q 'on 1 path(s) (plain)'"
check "--cpu with a path that is no path: rc 2" test "$(rc "$PMPA" --cpu=avx512 selftest)" -eq 2
check "--cpu plain (a space): rc 2, naming --cpu=plain" bash -c "'$PMPA' selftest --cpu plain 2>&1 | grep -q 'write --cpu=plain'"
check "selftest takes no files: rc 2" test "$(rc "$PMPA" selftest "$W/g.pmpa")" -eq 2

echo "--- t"
python3 -I -c "
import sys; d = bytearray(open(sys.argv[1], 'rb').read()); d[-20] ^= 4; open(sys.argv[2], 'wb').write(d)" "$W/pmpa/l3_cbr128_44k_joint.pmpa" "$W/damaged.pmpa"
check "t: OK for each that verifies, rc 0, nothing written" bash -c "
  [ \$('$PMPA' t '$W/pmpa/l3_cbr128_44k_joint.pmpa' '$W/pmpa/l2_64k_32k_mono_crc.pmpa' | grep -c ': OK') -eq 2 ] &&
  [ ! -e '$W/pmpa/l3_cbr128_44k_joint.mp3' ]"
check "t with a damaged one: FAILED for it, rc 1" bash -c "
  ! '$PMPA' t '$W/pmpa/l3_cbr128_44k_joint.pmpa' '$W/damaged.pmpa' > '$W/t.out' 2> '$W/t.err' &&
  grep -q ': OK' '$W/t.out' && grep -q 'damaged.pmpa: FAILED' '$W/t.err'"
check "t on an MP3: rc 1" test "$(rc "$PMPA" t "$W/in/l3_cbr128_44k_joint.mp3")" -eq 1
check "t -o: rc 2" test "$(rc "$PMPA" t "$W/g.pmpa" -o "$W/tt/")" -eq 2

echo "--- info and report"
# an MP3 whose tags say private things: ID3v2 (a title, a comment), ID3v1, APE
python3 -I -c "
import struct, sys
d = open(sys.argv[1], 'rb').read()
def fr(i, p): return i + struct.pack('>I', len(p)) + b'\0\0' + p
body = fr(b'TIT2', b'\x00PRIVATE-TITLE-TEXT') + fr(b'COMM', b'\x00eng\x00PRIVATE-COMMENT-TEXT')
n = len(body); ss = bytes([(n >> 21) & 127, (n >> 14) & 127, (n >> 7) & 127, n & 127])
v1 = b'TAG' + b'PRIVATE-V1-TITLE'.ljust(30, b'\0') + b'\0' * 94
open(sys.argv[2], 'wb').write(b'ID3\x03\x00\x00' + ss + body + d + v1)" "$W/in/l3_cbr128_44k_joint.mp3" "$W/private.mp3"
check "info: the streams, the tags with their sizes, what PMPA does" bash -c "
  o=\$('$PMPA' info '$W/private.mp3') && grep -q 'MPEG-1 Layer III, 44100 Hz' <<< \"\$o\" && grep -q 'kind: id3v2\|id3v2 at 0' <<< \"\$o\" &&
  grep -q 'metadata_bytes: ID3v2 ' <<< \"\$o\" && grep -q '  pmpa: takes it: stream version ' <<< \"\$o\""
check "info on a .pmpa: the container, the stream, its bands, that it extracts" bash -c "
  o=\$('$PMPA' info '$W/mixp/b.pmpa') && grep -q 'original_size: ' <<< \"\$o\" && grep -q 'bands: [2-9]' <<< \"\$o\" &&
  grep -q 'pmpa: extracts it' <<< \"\$o\""
check "info on a stored .pmpa: a .pmpa, not MPEG audio" bash -c "
  '$PMPA' info '$W/st.pmpa' | grep -q 'format: .pmpa'"
check "info on something else: refuses it, rc 0" bash -c "'$PMPA' info '$W/text.mp2' | grep -q 'pmpa: refuses it'"
check "info on a missing file: rc 1" test "$(rc "$PMPA" info "$W/missing.mp3")" -eq 1
mkdir -p "$W/rep"
check "report: the system, the file's hash, its structure, what PMPA does" bash -c "
  '$PMPA' report '$W/private.mp3' > '$W/rep/r.txt' && grep -q '^cpu_path: ' '$W/rep/r.txt' &&
  grep -q '^blake3_128: ' '$W/rep/r.txt' && grep -q '^pmpa: takes it' '$W/rep/r.txt'"
check "  privacy: no tag text in info, --json or report, only sizes" bash -c "
  for c in info 'info --json' report; do '$PMPA' \$c '$W/private.mp3' | grep -q PRIVATE && exit 1; done; exit 0"
check "  privacy: the file's name, never its folders" bash -c "
  ! grep -q '$(basename "$W")/' '$W/rep/r.txt' && grep -q '^pmpa report private.mp3$' '$W/rep/r.txt'"
check "  a link to a new issue, its body the report, under 6000 characters" bash -c "
  u=\$(grep '^https://' '$W/rep/r.txt') &&
  [[ \$u == https://github.com/YadeWira/PMPA/issues/new?template=bug_report.yml\&title=*\&body=PMPA%20bug%20report* ]] &&
  [ \${#u} -le 6000 ] && ! grep -q PRIVATE <<< \"\$u\""
check "report -o: the report in that file, the link on the screen" bash -c "
  '$PMPA' report '$W/private.mp3' -o '$W/rep/out.txt' | grep -q '^https://github.com/YadeWira/PMPA/issues/new' &&
  grep -q '^PMPA bug report' '$W/rep/out.txt'"
check "  an existing report is not replaced: rc 1" bash -c "
  echo keep > '$W/rep/keep.txt' && ! '$PMPA' report '$W/private.mp3' -o '$W/rep/keep.txt' 2>/dev/null &&
  [ \"\$(cat '$W/rep/keep.txt')\" = keep ]"
check "report --with-file: the file copied beside the report, byte for byte" bash -c "
  '$PMPA' report --with-file '$W/private.mp3' -o '$W/rep/w.txt' > /dev/null && cmp -s '$W/private.mp3' '$W/rep/pmpa-report-private.mp3'"
check "report with no file: the system part, rc 0" bash -c "'$PMPA' report | grep -q '^== No file'"
check "report with two files: rc 2" test "$(rc "$PMPA" report "$W/private.mp3" "$W/g.pmpa")" -eq 2
check "--with-file is for report: rc 2" test "$(rc "$PMPA" a --with-file "$W/private.mp3")" -eq 2

echo "--- --stats and --json"
check "a --stats -th 1: parse, encode, verify, write; and a summary" bash -c "
  o=\$('$PMPA' a -f --stats -th 1 '$W/in/l3_cbr128_44k_joint.mp3' '$W/in/l2_64k_32k_mono_crc.mp2' -o '$W/stt/') &&
  [ \$(grep -c '  stats: read .*parse .*encode .*verify .*write .*; 1 thread(s), 1 band(s)' <<< \"\$o\") -eq 2 ] &&
  grep -q '^pmpa: 2 file(s), ' <<< \"\$o\""
check "x --stats: decode and hash" bash -c "
  '$PMPA' x -f --stats '$W/stt/l3_cbr128_44k_joint.pmpa' -o '$W/stt/' | grep -q 'stats: read .*decode .*hash .*write'"
check "t --stats -q: the stats alone" bash -c "
  o=\$('$PMPA' t -q --stats '$W/stt/l3_cbr128_44k_joint.pmpa') && ! grep -q OK <<< \"\$o\" && grep -q 'stats: read' <<< \"\$o\""
check "--stats is not for list: rc 2" test "$(rc "$PMPA" list --stats "$W/g.pmpa")" -eq 2
JS="import json, sys
lines = sys.stdin.read().splitlines()
objs = [json.loads(l) for l in lines]
assert objs and 'summary' in objs[-1], objs[-1:]
for o in objs[:-1]: assert 'file' in o and o['ok'] in (True, False)
assert len(objs) - 1 == int(sys.argv[1]), len(objs)"
check "a --json: a JSON object a file and a summary" bash -c "
  '$PMPA' a -f --json --stats '$W/in/l3_cbr128_44k_joint.mp3' '$W/in/l2_64k_32k_mono_crc.mp2' '$W/text.mp2' -o '$W/js/' 2>/dev/null |
  python3 -I -c \"\$1\" 3" _ "$JS"
check "  with the failure as ok false and its error" bash -c "
  '$PMPA' a -f --json '$W/text.mp2' -o '$W/js/' 2>/dev/null | head -1 |
  python3 -I -c 'import json,sys; o=json.load(sys.stdin); assert o[\"ok\"] is False and \"not MPEG audio\" in o[\"error\"]'"
check "x --json" bash -c "'$PMPA' x -f --json '$W'/js/*.pmpa -o '$W/js/' | python3 -I -c \"\$1\" 2" _ "$JS"
check "t --json" bash -c "'$PMPA' t --json '$W/pmpa/l3_cbr128_44k_joint.pmpa' '$W/damaged.pmpa' 2>/dev/null | python3 -I -c \"\$1\" 2" _ "$JS"
check "list --json" bash -c "'$PMPA' list --json '$W'/js/*.pmpa | python3 -I -c \"\$1\" 2" _ "$JS"
check "info --json, an MP3, an MP2, a .pmpa" bash -c "
  '$PMPA' info --json '$W/private.mp3' '$W/in/l2_64k_32k_mono_crc.mp2' '$W/g.pmpa' | python3 -I -c \"\$1\" 3" _ "$JS"
check "--json: original_size and pmpa_size in a, x, t, list; info's stream_version" bash -c "
  '$PMPA' a -f --json '$W/in/l2_64k_32k_mono_crc.mp2' -o '$W/jn/' | head -1 > '$W/jn.txt' &&
  '$PMPA' x -f --json '$W/jn/l2_64k_32k_mono_crc.pmpa' -o '$W/jn/' | head -1 >> '$W/jn.txt' &&
  '$PMPA' t --json '$W/jn/l2_64k_32k_mono_crc.pmpa' | head -1 >> '$W/jn.txt' &&
  '$PMPA' list --json '$W/jn/l2_64k_32k_mono_crc.pmpa' | head -1 >> '$W/jn.txt' &&
  '$PMPA' info --json '$W/in/l2_64k_32k_mono_crc.mp2' | head -1 >> '$W/jn.txt' &&
  python3 -I -c '
import json, sys
o = [json.loads(l) for l in open(sys.argv[1])]
for k in range(4): assert o[k][\"original_size\"] == 8064 and o[k][\"pmpa_size\"] > 0, o[k]
assert o[4][\"pmpa\"][\"stream_version\"] == 9, o[4]' '$W/jn.txt'"
check "--json is not for bench: rc 2" test "$(rc "$PMPA" bench --json "$W/g.pmpa")" -eq 2

echo "--- bench"
mkdir -p "$W/bench"; cp "$W/in/l2_64k_32k_mono_crc.mp2" "$W/g.pmpa" "$W/bench/"
check "bench: a, a --no-verify and x, each with MB/s, rc 0" bash -c "
  o=\$('$PMPA' bench -r 2 -th 2 '$W/bench/l2_64k_32k_mono_crc.mp2' '$W/bench/g.pmpa') && grep -q '^cpu_path: ' <<< \"\$o\" &&
  grep -q '^  a --no-verify .* MB/s' <<< \"\$o\" && [ \$(grep -c '^  x .* MB/s' <<< \"\$o\") -eq 3 ]"
check "  and nothing written beside the inputs" test "$(ls "$W/bench" | wc -l)" -eq 2
check "bench -r 0: rc 2" test "$(rc "$PMPA" bench -r 0 "$W/bench/g.pmpa")" -eq 2
check "bench on something else: rc 1" test "$(rc "$PMPA" bench "$W/text.mp2")" -eq 1

echo "--- a bug in PMPA"
cp "$W/in/l2_64k_32k_mono_crc.mp2" "$W/bug.mp2"
check "an internal error (a range check): its own exit code, 3, and what to do" bash -c "
  PMPA_TEST_CRASH=range '$PMPA' a -f '$W/bug.mp2' -o '$W/bug.pmpa' 2> '$W/bug.txt'; [ \$? -eq 3 ] &&
  grep -q 'internal error: ERangeError' '$W/bug.txt' &&
  grep -q 'This is a bug in PMPA. Please run: pmpa report .*bug.mp2 and open an issue at https://github.com/YadeWira/PMPA/issues' '$W/bug.txt'"
check "  and nothing written" test ! -e "$W/bug.pmpa"
check "an access violation, in a worker thread: rc 3" bash -c "
  PMPA_TEST_CRASH=access '$PMPA' a -f -th 4 '$W/bug.mp2' '$W/in/l3_cbr128_44k_joint.mp3' -o '$W/bugs/' 2> '$W/bug2.txt'; [ \$? -eq 3 ] &&
  grep -q 'EAccessViolation' '$W/bug2.txt' && grep -q 'This is a bug in PMPA' '$W/bug2.txt'"
check "a file that fails as a file is not a bug: rc 1" bash -c "'$PMPA' a '$W/text.mp2' 2> '$W/nb.txt'; [ \$? -eq 1 ] && ! grep -q 'bug' '$W/nb.txt'"

echo "$cells cells, $failures failures"
[ "$failures" -eq 0 ] && [ "$cells" -ge 115 ]
