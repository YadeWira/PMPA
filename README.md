# PMPA

**packMediaPlayer Algorithm**: lossless recompression of **MPEG audio**
(MP1, MP2 and MP3), in FreePascal, with a C core where it pays and some
x86-64 assembly; no libraries.

The successor of [packMP3](https://github.com/YadeWira/packMP3) and
[packMP2](https://github.com/YadeWira/packMP2): written from scratch, with
a codec and container of its own; it shares no code with them and does not
read their files.

| Component | Status |
|---|---|
| CI | [![CI][ciBadge]][ciLink] |
| Latest release | [![Release][relBadge]][relLink] |

```sh
pmpa a song.mp3          # -> song.pmpa
pmpa x song.pmpa         # -> song.mp3, the same file byte for byte
```

The original comes back **byte for byte**, and nothing is written unless it
verified: `a` decompresses its own result and compares it with the input
first, and `x` checks the size and the BLAKE3 hash the `.pmpa` carries.

## The family

PMPA belongs to a family of recompressors that share that rule.

| Sibling | Formats | Successor of |
|---|---|---|
| **PMPA** | MPEG audio (MP1, MP2, MP3) | [packMP3](https://github.com/YadeWira/packMP3), [packMP2](https://github.com/YadeWira/packMP2) |
| [PRA](https://github.com/YadeWira/PRA) | raster images (PNM, BMP, TIFF, PSD, HDR, ...) | [packPNM](https://github.com/packjpg/packPNM) |
| [PPA](https://github.com/YadeWira/PPA) | the PNG family (PNG, APNG, MNG, JNG) | [packPNG](https://github.com/YadeWira/packPNG) |
| [PAIA](https://github.com/YadeWira/PAIA) | animated images (GIF, WebP, FLI/FLC, ANI, ...) | (new) |
| [PJA](https://github.com/YadeWira/PJA) | JPEG and JPEG-LS | [packJPG](https://github.com/YadeWira/packJPG) |

A file with no MPEG audio frame is refused: PMPA is not a general
compressor ([what it takes][wHandles]). The [wiki][wHome] has how to use it,
build it, and how it works. The command is described in [doc/CLI.md](doc/CLI.md), the file
in [doc/FORMAT.md](doc/FORMAT.md), the codec in [doc/CODEC.md](doc/CODEC.md).

## Against packMP3 and packMP2

Measured on 01/11/2026 ([how][wBench]), every file compressed, extracted
and compared with its original:

| set | files | size | packMP3 3.0f | packMP2 0.8 (best) | PMPA 0.1.0 |
|---|---|---|---|---|---|
| Layer III (MP3), a public sample corpus | 11 | 24.2 MB | 84.36% (stores one as it is) | | **84.12%** |
| Layer II (MP2), from samples.ffmpeg.org | 53 | 42.9 MB | | 76.95% (takes 52) | **72.17%** |
| Layer I (MP1), from samples.ffmpeg.org | 3 | 1.1 MB | | | **51.58%** |

PMPA is slower: a 6.5 MB MP3 compresses in 3.6 s and extracts in 1.6 s on
4 threads (in bands of 2 MiB), 12.1 s and 5.2 s on one, where packMP3
compresses it in 2 s.

## Install

Download the command for your platform from the [latest release][relLink]:
Linux (x86-64, x86, arm64), macOS (Apple silicon) or Windows (x64, and x86
from XP on). Each build is tested by CI on its own platform, and the
Windows ones on Windows 10 and 7 too (x86 on XP as well); a `.pmpa` made on
one opens on any other ([installing][wInstall]).

```sh
pmpa a *.mp3 --output-dir=packed   # compress many
pmpa x packed/*.pmpa -o restored/  # and back
pmpa list packed/*.pmpa            # sizes and hashes
```

## How it was built

Bottom-up, each layer with its tests:

| Layer | Unit | Status |
|---|---|---|
| hash (BLAKE3-128) | `pas/pmpablake3.pas` | done, from PJA |
| binary arithmetic coder | `pas/pmpaarith.pas` | done, from PJA |
| MPEG audio parser: frames (Layer I, II, III; MPEG-1, 2, 2.5; free format) and tags (ID3v2, ID3v1, APE, Lyrics3) | `pas/pmpampeg.pas` | done |
| the codec stream, version 1: the segments, frame headers predicted, bytes in order 0/1 (a scaffold) | `pas/pmpacodec.pas` | done |
| version 2: Layer III's side information, CRC and bit reservoir | `pas/pmpal3.pas` | done |
| the `.pmpa` container and the `pmpa` command | `pas/pmpaformat.pas`, `pas/pmpapack.pas`, `pas/pmpafs.pas`, `pas/pmpacli.pas` | done, from PJA by way of PRA |
| version 3: Layer III's Huffman-coded values decoded and modelled, coded again exactly | `pas/pmpahuff.pas` | done, a first model |
| version 4: Layer III mixed (values, signs, scalefactors), part2_3_length derived | `pas/pmpamodel.pas` | done |
| version 5: Layer I and II (allocation, scale factors, samples) | `pas/pmpal12.pas` | done |
| version 6: faster (contexts hashed once a value, verifying on a second thread) | | done |
| the models' hot loops in C, Layer III's values and Layer I and II's samples (the same streams as the Pascal) | `pas/pmpal3c.c`, `pas/pmpac.pas` | done |
| version 7: bands of 2 MiB coded and decoded at once on several threads | `pas/pmpacodec.pas` | done |

## Building and testing

```sh
./run_tests.sh           # every layer's tests, with range and overflow checks on
```

Needs [Free Pascal](https://www.freepascal.org) 3.2.2 and a C compiler
(gcc or clang; `CC` picks it): `pas/build_c.sh <dir>` builds the C part,
and `fpc -Fo<dir>` links it. The [wiki](https://github.com/YadeWira/PMPA/wiki/Building)
has the details.

## License

MIT; see [LICENSE](LICENSE) and [NOTICE](NOTICE).

[wHome]: https://github.com/YadeWira/PMPA/wiki
[wBench]: https://github.com/YadeWira/PMPA/wiki/Benchmarks
[wHandles]: https://github.com/YadeWira/PMPA/wiki/What-PMPA-handles
[wInstall]: https://github.com/YadeWira/PMPA/wiki/Installing
[ciBadge]: https://github.com/YadeWira/PMPA/actions/workflows/ci.yml/badge.svg?branch=main
[ciLink]: https://github.com/YadeWira/PMPA/actions/workflows/ci.yml
[relBadge]: https://img.shields.io/github/v/release/YadeWira/PMPA
[relLink]: https://github.com/YadeWira/PMPA/releases/latest
