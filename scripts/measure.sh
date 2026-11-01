#!/bin/bash
# How the README's and doc/CODEC.md's numbers are measured: every file of a
# directory compressed by pmpa and extracted again, each compared with its
# original, and the sizes added up with stat (never by parsing pmpa's own
# output: a name with a space once shifted its columns and left a 6.5 MB
# file out of a total).
#
#   scripts/measure.sh <pmpa binary> <directory of originals> <work directory> [threads]
#
# Files pmpa refuses (no MPEG audio frame) are counted apart. Prints, by
# layer (the first frame's), the files, their size and the .pmpa's, and the
# time to compress and to extract.
set -euo pipefail
PMPA=$(realpath "$1"); SRC=$(realpath "$2"); W=$3; TH=${4:-8}
rm -rf "$W"; mkdir -p "$W/p" "$W/x"
t0=$(date +%s.%N)
"$PMPA" a -q -th "$TH" --output-dir="$W/p" "$SRC"/* 2> "$W/refused.txt" || true
t1=$(date +%s.%N)
"$PMPA" x -q -th "$TH" --output-dir="$W/x" "$W"/p/*.pmpa
t2=$(date +%s.%N)
refused=$(grep -c 'not MPEG audio' "$W/refused.txt" || true)
python3 -I - "$SRC" "$W" "$refused" "$t0" "$t1" "$t2" <<'PY'
import os, sys, filecmp
src, w, refused, t0, t1, t2 = sys.argv[1], sys.argv[2], int(sys.argv[3]), *map(float, sys.argv[4:7])
BR = {(3, 3): [0,32,64,96,128,160,192,224,256,288,320,352,384,416,448],
      (3, 2): [0,32,48,56,64,80,96,112,128,160,192,224,256,320,384],
      (3, 1): [0,32,40,48,56,64,80,96,112,128,160,192,224,256,320],
      (2, 3): [0,32,48,56,64,80,96,112,128,144,160,176,192,224,256],
      (2, 2): [0,8,16,24,32,40,48,56,64,80,96,112,128,144,160]}
SR = {3: [44100, 48000, 32000], 2: [22050, 24000, 16000], 0: [11025, 12000, 8000]}

def frame_len(d, i):
    """the length of the frame whose header is at i, or 0"""
    if i + 4 > len(d) or d[i] != 0xFF or (d[i + 1] & 0xE0) != 0xE0:
        return 0
    v, l = (d[i + 1] >> 3) & 3, (d[i + 1] >> 1) & 3
    bi, si, pad = d[i + 2] >> 4, (d[i + 2] >> 2) & 3, (d[i + 2] >> 1) & 1
    if v == 1 or l == 0 or bi in (0, 15) or si == 3:
        return 0
    br = BR[(3, l) if v == 3 else (2, 3 if l == 3 else 2)][bi] * 1000
    sr = SR[v][si]
    if l == 3:
        return (12 * br // sr + pad) * 4
    return (144 if (l == 2 or v == 3) else 72) * br // sr + pad

def first_layer(d):
    """the layer of the first frame followed by another (free format is left out)"""
    for i in range(len(d) - 3):
        n = frame_len(d, i)
        if n and frame_len(d, i + n) and ((d[i + n + 1] >> 1) & 3) == ((d[i + 1] >> 1) & 3):
            return 'Layer ' + {1: 'III', 2: 'II', 3: 'I'}[(d[i + 1] >> 1) & 3]
    return '?'

orig = {os.path.splitext(f)[0]: f for f in os.listdir(src)}
by = {}
bad = []
for f in sorted(os.listdir(os.path.join(w, 'p'))):
    stem = f[:-5]
    o = os.path.join(src, orig[stem])
    xs = [x for x in os.listdir(os.path.join(w, 'x')) if os.path.splitext(x)[0] == stem]
    if len(xs) != 1 or not filecmp.cmp(o, os.path.join(w, 'x', xs[0]), shallow=False):
        bad.append(stem)
    layer = first_layer(open(o, 'rb').read())
    a, b = os.path.getsize(o), os.path.getsize(os.path.join(w, 'p', f))
    for k in (layer, 'all'):
        n, sa, sb = by.get(k, (0, 0, 0))
        by[k] = (n + 1, sa + a, sb + b)
for k in sorted(by):
    n, a, b = by[k]
    print(f'{k:10} {n:4} files  {a:12,} B -> {b:12,} B  {100 * b / a:6.2f}%')
print(f'refused (no MPEG audio): {refused}')
print(f'compress {t1 - t0:.1f} s, extract {t2 - t1:.1f} s')
if bad:
    print('DID NOT COME BACK:', ' '.join(bad))
    sys.exit(1)
print('every file back byte for byte')
PY
