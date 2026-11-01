# PMPA

**packMediaPlayer Algorithm**: lossless recompression of **MPEG audio**
(MP1, MP2 and MP3), in FreePascal, with a C core where it pays and some
x86-64 assembly; no libraries.

The successor of [packMP3](https://github.com/YadeWira/packMP3) and
[packMP2](https://github.com/YadeWira/packMP2): written from scratch, with
a codec and container of its own; it shares no code with them and does not
read their files. A sibling of [PJA](https://github.com/YadeWira/PJA) (JPEG),
[PPA](https://github.com/YadeWira/PPA) (PNG) and
[PRA](https://github.com/YadeWira/PRA) (raster images).

```sh
pmpa a song.mp3          # -> song.pmpa
pmpa x song.pmpa         # -> song.mp3, the same file byte for byte
```

The original comes back **byte for byte**, and nothing is written unless it
verified: `a` decompresses its own result and compares it with the input
first, and `x` checks the size and the BLAKE3 hash the `.pmpa` carries.

A file with no MPEG audio frame is refused: PMPA is not a general
compressor. The command is described in [doc/CLI.md](doc/CLI.md), the file
in [doc/FORMAT.md](doc/FORMAT.md), the codec in [doc/CODEC.md](doc/CODEC.md).

**Status: in development.** The container and the command work end to end,
and Layer III's values are modelled (a first model), but not yet Layer I
and II's samples: on the 24 files with MPEG audio of a local sample corpus
(24.8 MB), the `.pmpa` files are 90.99% of the originals, Layer III files
73.5% to 93.1% (measured 01/11/2026). Built bottom-up, each layer with its tests:

| Layer | Unit | Status |
|---|---|---|
| hash (BLAKE3-128) | `pas/pmpablake3.pas` | done, from PJA |
| binary arithmetic coder | `pas/pmpaarith.pas` | done, from PJA |
| MPEG audio parser: frames (Layer I, II, III; MPEG-1, 2, 2.5; free format) and tags (ID3v2, ID3v1, APE, Lyrics3) | `pas/pmpampeg.pas` | done |
| the codec stream, version 1: the segments, frame headers predicted, bytes in order 0/1 (a scaffold) | `pas/pmpacodec.pas` | done |
| version 2: Layer III's side information, CRC and bit reservoir | `pas/pmpal3.pas` | done |
| the `.pmpa` container and the `pmpa` command | `pas/pmpaformat.pas`, `pas/pmpapack.pas`, `pas/pmpafs.pas`, `pas/pmpacli.pas` | done, from PJA by way of PRA |
| version 3: Layer III's Huffman-coded values decoded and modelled, coded again exactly | `pas/pmpahuff.pas` | done, a first model |
| Layer III's scalefactors, and a better model of the values | | next |
| Layer I and II: bit allocation, scalefactors, samples | | |

## Building and testing

```sh
./run_tests.sh           # every layer's tests, with range and overflow checks on
```

Needs [Free Pascal](https://www.freepascal.org) 3.2.2.

## License

MIT; see [LICENSE](LICENSE) and [NOTICE](NOTICE).
