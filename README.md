# PMPA

**packMediaPlayer Algorithm**: lossless recompression of **MPEG audio**
(MP1, MP2 and MP3) files, in FreePascal, with the models' hot loops in C
and some x86-64 assembly; no libraries. The successor of
[packMP3](https://github.com/YadeWira/packMP3) and
[packMP2](https://github.com/YadeWira/packMP2): a new codec and format of
its own (it does not read `.pm3` files), smaller and verified before
anything is written.

| Component | Status |
|---|---|
| CI | [![CI][ciBadge]][ciLink] |
| Latest release | [![Release][relBadge]][relLink] |

```sh
pmpa a song.mp3          # -> song.pmpa, about 16% smaller
pmpa x song.pmpa         # -> song.mp3, the same file byte for byte
```

The original comes back **byte for byte**, and nothing is written under an
output's name unless it verified: compressing decompresses the result and
compares it with the input before writing, and extracting checks the size
and the BLAKE3 hash stored in the `.pmpa`.

What a published release wrote opens in every later release; the formats
are not frozen yet, and will be in a 0.9.x
([doc/STABILITY.md](doc/STABILITY.md)).

PMPA belongs to a family of recompressors that share that rule: the original
comes back byte for byte, and nothing is written unless it verified.

| Sibling | Formats | Successor of |
|---|---|---|
| [PRA](https://github.com/YadeWira/PRA) | raster images (PNM, BMP, TIFF, PSD, HDR, ...) | [packPNM](https://github.com/packjpg/packPNM) |
| [PPA](https://github.com/YadeWira/PPA) | the PNG family (PNG, APNG, MNG, JNG) | [packPNG](https://github.com/YadeWira/packPNG) |
| [PAIA](https://github.com/YadeWira/PAIA) | animated images (GIF, WebP, FLI/FLC, ANI, ...) | (new) |
| [POA](https://github.com/YadeWira/POA) | Ogg (Vorbis, Opus, FLAC, Speex, Theora) | (new) |
| [PJA](https://github.com/YadeWira/PJA) | JPEG, JPEG-LS and JPEG 2000 | [packJPG](https://github.com/YadeWira/packJPG) |
| **PMPA** | MPEG audio (MP1, MP2, MP3) | [packMP3](https://github.com/YadeWira/packMP3), [packMP2](https://github.com/YadeWira/packMP2) |

## What it handles

- **Layer III** (MP3): MPEG-1, 2 and 2.5, every block type and channel
  mode, CBR, VBR, ABR and free format, with or without CRC, the bit
  reservoir; each granule's values decoded and modelled.
- **Layer II** (MP2) and **Layer I** (MP1): MPEG-1 and 2, every allocation
  table, with or without CRC, free format.
- **Tags**: ID3v2, ID3v1, APE and Lyrics3, kept as they are; the JPEG
  covers inside ID3v2 tags recompressed through PJA (since 0.2.0).
- MPEG audio inside WAV, MP4/M4A and MPEG program streams: the frames
  modelled, the container's bytes kept.

Anything else in the file goes through as bytes; a file with no MPEG audio
frame is refused, and `pmpa a` says why ([details][wHandles]).

## Install

Download the command for your platform from the [latest release][relLink]:
Linux (x86-64, x86, arm64; glibc 2.34 or later), macOS (Apple silicon) or
Windows (x64, and x86 from XP on). Each build is tested by CI on its own
platform, the Windows ones on Windows 10 and 7 too (x86 on XP as well),
and a `.pmpa` made on one opens on any other ([installing][wInstall],
[platforms][wPlat]).

```sh
pmpa a *.mp3 --output-dir=packed   # compress many
pmpa x packed/*.pmpa -o restored/  # and back
pmpa list packed/*.pmpa            # sizes and hashes
pmpa selftest                      # check this build on this machine
```

The command's manual is [doc/CLI.md](doc/CLI.md).

## Against other compressors

One file at a time, against the recompressors PMPA follows:
[packMP3](https://github.com/YadeWira/packMP3) 3.0f and
[packMP2](https://github.com/YadeWira/packMP2) 0.8. Each set's whole output
against its input, every file extracted and compared; a file a tool does
not take counts at its own size ([how, and the details][wBench]).

| set | files | size | packMP3 3.0f | packMP2 0.8 (zpaq 5) | PMPA 0.2.0 |
|---|---|---|---|---|---|
| Layer III (MP3), a public sample corpus | 11 | 24.2 MB | 84.36% (stores one as it is) | | **84.12%** |
| MP3 with a JPEG cover, from archive.org (the first MB of each) | 55 | 56.9 MB | 82.49% (fails on 4) | | **79.60%** |
| Layer II (MP2), from samples.ffmpeg.org | 53 | 42.9 MB | | 95.39% (18 come back byte for byte) | **72.17%** |
| Layer I (MP1), from samples.ffmpeg.org | 3 | 1.1 MB | | | **51.58%** |

Speed (two Xeon E5-2697A v4, with other work running; "8 at once":
`pmpa -th 8`, the others 8 processes):

| | packMP3 3.0f, Layer III set | PMPA, Layer III set | packMP2 0.8 (zpaq 5), Layer II set | PMPA, Layer II set |
|---|---|---|---|---|
| compress, 1 thread | **8.5 s** | 44.0 s | 156.7 s | **76.9 s** |
| decompress, 1 thread | **9.6 s** | 19.3 s | 157.0 s | **40.9 s** |
| compress, 8 at once | **2.5 s** | 8.3 s | 29.7 s | **10.0 s** |
| decompress, 8 at once | **2.8 s** | 3.6 s | 31.1 s | **5.1 s** |

PMPA is the smallest on every set and gives every file back byte for byte;
packMP2 0.8 gives back 18 of the 53 Layer II files byte for byte (34 come
back different, most short of their last bytes, with exit 0; it refuses
one), and nothing else we know of recompresses Layer I. packMP3 is about five times as fast to
compress on one thread; packMP2 with zpaq is slower than PMPA.

## Safe by design

PMPA's first rule is that the original comes back byte for byte, or nothing
is written. Measured against packMP3 3.0f and packMP2 0.8 on the same 20
files (14 MP3, 6 MP2 and MP1; packMP2 takes only the latter) and the same
damage, PJA's method ([how][wSafe]):

| | PMPA | packMP3 | packMP2 |
|---|---|---|---|
| single-bit flips in the compressed file: a wrong file given back without an error | **0** of 4,000 | 1,581 of 3,600 (it exits 0 whatever happens) | 0 of 1,200 |
| stores a hash of the original | **yes** (BLAKE3) | no | no |
| checks its output before writing it, by default | **yes** | no | no |
| fuzzed inputs taken that do not come back | **0** of 948 | 58 of 810 | 159 of 261 |
| disk full: a truncated file under the output's name | **no** (an old file is kept) | no (but an old file is lost with `-o`) | yes (and exit 0) |
| writes through a symbolic link at the output's name | **no** | yes | yes |
| killed while writing: a partial file under the output's name | **no** | yes | yes |
| written promise that its files keep opening | **yes** ([STABILITY](doc/STABILITY.md)) | within a main version | no |

It is design, not luck: a stored hash and size, a decode-and-compare before
writing, a temporary that takes the output's name only when it is complete
and on the disk (and is deleted on Ctrl-C), and a clean refusal of anything
it does not understand. packMP3 exits 0 whatever happens, so a script
cannot tell its failures. What PMPA does not do: repair a damaged `.pmpa`
(keep backups, or use an archiver with recovery records) or authenticate it
(the hash catches accidents, not tampering).

## Against archivers

PMPA has no archiver plugin yet (below), so here it is the command, one
`.pmpa` a file, and the same `.pmpa` files put in a 7-Zip archive, against
the archivers alone: 7-Zip 25.01 `-mx9`, zpaq-std 2.7.2 `-m5` and `-m1`,
and zstd 1.5.7 `-19` over a tar. One archive per set, 8 threads; every file
extracted and compared. Size, then the time to write / extract:

| set | PMPA | PMPA, then 7-Zip | 7-Zip | zpaq-std -m5 | zpaq-std -m1 | tar + zstd -19 |
|---|---|---|---|---|---|---|
| corpus: every MPEG audio file (24, 31.4 MB) | **82.81%**, 10.1 / 4.6 s | 82.82%, 12.1 / 4.7 s | 95.72%, 2.9 / 0.9 s | 93.55%, 136.7 / 140.9 s | 97.90%, 0.6 / 0.4 s | 95.44%, 6.7 / 0.0 s |
| MP3 with a cover (55, 56.9 MB) | **79.60%**, 15.3 / 5.8 s | 79.61%, 18.6 / 5.9 s | 95.01%, 5.8 / 1.4 s | 93.30%, 255.6 / 270.6 s | 96.14%, 0.7 / 0.5 s | 94.70%, 8.5 / 0.1 s |
| MP2 and MP1 from samples.ffmpeg.org (56, 43.9 MB) | 71.66%, 10.6 / 5.4 s | **68.23%**, 12.9 / 5.5 s | 87.35%, 5.1 / 1.3 s | 83.60%, 188.8 / 191.4 s | 94.12%, 0.4 / 0.2 s | 89.58%, 8.3 / 0.1 s |

MPEG audio is already compressed: the archivers save 2 to 16%, PMPA 17 to
28%. 7-Zip after PMPA gains nothing on the MP3 sets and 3.4 points on the
MP2 one. zpaq-std's strongest method comes closest, and is the slowest.

## In 7-Zip and zpaq-std

**7-Zip** and [7-Zip-zstd](https://github.com/mcmilk/7-Zip-zstd) (since
0.5.0): put `libpmpa`'s `pmpa.dll` (or `pmpa.so`; in each release, x64 for
64-bit 7-Zip, x86 for 32-bit) in the `Codecs` folder next to 7-Zip, and

```sh
7z a -m0=PMPA -m1=LZMA2 music.7z music/      # 7-Zip-zstd: -m1=zstd
```

(in 7-Zip's window: **Parameters** `0=PMPA 1=LZMA2`). PMPA goes first in
the chain as a filter: it recompresses the runs of MPEG audio frames in
the solid block, tags included, and passes every other byte on. Extracting
needs the plugin too. On the three sets above: 82.83%, 79.60% and 69.19%,
where 7-Zip alone makes 95.72%, 95.01% and 87.35% ([details][wLib]).

**[zpaq-std](https://github.com/YadeWira/zpaq-std)**: not yet; a plugin
whose blocks any zpaq extracts is planned, as PJA and PPA have them
([zpaq-std plugin][wPlugin]).

## Reporting a bug

```sh
pmpa report song.mp3 -o report.txt   # what happened, on which machine
```

It writes a plain-text report (PMPA's build, the system, the command line,
and the file's size, hash and structure, but no audio, no tag contents and
no folder names) and prints a link that opens a [new issue][issues] with it
filled in. `--with-file` puts a copy of the file beside it, to attach if
you choose to ([details][wBugs],
[doc/CLI.md](doc/CLI.md#checking-and-reporting)).

## More

The [wiki][wiki] has the rest: [benchmarks][wBench], [safety and
robustness][wSafe], [building and testing][wBuild], [how it works][wHow],
the [source layout][wLayout], [FreePascal pitfalls][wFpc], the [release
history][wRel] and the [FAQ][wFaq]. The codec's full notes are in
[doc/CODEC.md](doc/CODEC.md), the file format in
[doc/FORMAT.md](doc/FORMAT.md), what does not change in
[doc/STABILITY.md](doc/STABILITY.md).

## Building

FreePascal 3.2 and a C compiler (gcc or clang):

```sh
pas/build_c.sh build/c                       # the C part (PMPA's and the vendored PJA's)
fpc -O3 -dPMPA_FAST -dPJA_FAST -Fupas -Fipas -Fuvendor/pja/pas -Fivendor/pja/pas \
    -Fobuild/c -FUbuild -opmpa pas/pmpacli.pas   # the command
./run_tests.sh                               # every test
```

## License

MIT, see `LICENSE`. The album covers' codec is PJA, vendored in
`vendor/pja`; see `NOTICE` for that and other credits.

[ciBadge]: https://github.com/YadeWira/PMPA/actions/workflows/ci.yml/badge.svg?branch=main "Continuous Integration"
[ciLink]: https://github.com/YadeWira/PMPA/actions/workflows/ci.yml
[relBadge]: https://img.shields.io/github/v/release/YadeWira/PMPA "Latest release"
[relLink]: https://github.com/YadeWira/PMPA/releases/latest
[wiki]: https://github.com/YadeWira/PMPA/wiki
[wBench]: https://github.com/YadeWira/PMPA/wiki/Benchmarks
[wSafe]: https://github.com/YadeWira/PMPA/wiki/Safety-and-robustness
[wHandles]: https://github.com/YadeWira/PMPA/wiki/What-PMPA-handles
[wInstall]: https://github.com/YadeWira/PMPA/wiki/Installing
[wPlat]: https://github.com/YadeWira/PMPA/wiki/Platforms
[wLib]: https://github.com/YadeWira/PMPA/wiki/Library-and-7-Zip
[wPlugin]: https://github.com/YadeWira/PMPA/wiki/The-zpaq-std-plugin
[wBuild]: https://github.com/YadeWira/PMPA/wiki/Building
[wHow]: https://github.com/YadeWira/PMPA/wiki/How-it-works
[wLayout]: https://github.com/YadeWira/PMPA/wiki/Source-layout
[wFpc]: https://github.com/YadeWira/PMPA/wiki/FreePascal-pitfalls
[wRel]: https://github.com/YadeWira/PMPA/wiki/Releases
[wBugs]: https://github.com/YadeWira/PMPA/wiki/Reporting-bugs
[wFaq]: https://github.com/YadeWira/PMPA/wiki/FAQ
[issues]: https://github.com/YadeWira/PMPA/issues
