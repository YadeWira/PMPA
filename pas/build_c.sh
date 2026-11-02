#!/bin/sh
# The C part of PMPA (pmpal3c.c: the models' hot loops) and of the vendored
# PJA (vendor/pja: the album covers' JPEGs) as objects for FreePascal to
# link: pmpac.pas takes pmpal3c.o with {$L pmpal3c.o}, PJA's pjav7.pas its
# own, all found through -Fo<dir>. As PJA's build_c.sh.
#
#   pas/build_c.sh <out dir> [extra C flags]
#
# CC picks the compiler (cc by default): gcc or clang, native or a cross
# compiler (x86_64-w64-mingw32-gcc, i686-w64-mingw32-gcc, "gcc -m32").
#
# The object calls no library and needs no runtime: no stack protector, no
# loop turned into memset or memcpy (gcc's -fno-tree-loop-distribute-patterns,
# clang's -fno-builtin), no position-independent code where the executable is
# not (32-bit x86). -fwrapv keeps the hashes' wrapping arithmetic defined.
set -eu
OUT=${1:?usage: build_c.sh <out dir> [extra C flags]}
shift
HERE=$(cd "$(dirname "$0")" && pwd)
CC=${CC:-cc}
FLAGS="-O3 -fwrapv -ffp-contract=off -fno-stack-protector -std=c99 -Wall"
if $CC --version 2>/dev/null | grep -qi clang; then
  FLAGS="$FLAGS -fno-builtin"
else
  FLAGS="$FLAGS -fno-tree-loop-distribute-patterns"
fi
# 32-bit x86, whatever the compiler's default: no position-independent code
# where the executable is not, and nothing newer than the i686 (a compiler
# whose default is a Pentium 4, as MSYS2's MinGW-w64 gcc, would use SSE2,
# and the Windows x86 build is for XP's machines too). The integers are the
# same either way: the same streams.
TARGET=$($CC -dumpmachine 2>/dev/null || echo unknown)
case "$CC $* $TARGET" in
  *-m32*|*i686*|*i386*|*i586*) FLAGS="$FLAGS -march=i686 -mtune=generic" ;;
esac
case "$CC $*" in
  *-m32*) FLAGS="$FLAGS -fno-pic" ;;
esac
mkdir -p "$OUT"
# shellcheck disable=SC2086
$CC $FLAGS "$@" -c "$HERE/pmpal3c.c" -o "$OUT/pmpal3c.o"

# and the vendored PJA's (pjav7c.o, pjasysc.o: the album covers' JPEGs), by
# its own build_c.sh, which since PJA 0.6.3 makes the same choice for 32-bit
# x86 (-march=i686: its SSE2 path left out, its SSE4.1 and AVX2 copies by
# cpuid)
# shellcheck disable=SC2086
sh "$HERE/../vendor/pja/pas/build_c.sh" "$OUT" "$@"
