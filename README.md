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
compressor ([what it takes][wHandles]). The [wiki][wHome] has how to use it,
build it, and how it works. The command is described in [doc/CLI.md](doc/CLI.md), the file
in [doc/FORMAT.md](doc/FORMAT.md), the codec in [doc/CODEC.md](doc/CODEC.md).

**Status: in development.** The container and the command work end to end,
and every layer is modelled: Layer III files come out at 84.07% of their
size, where packMP3 3.0f makes 84.36%, and Layer II at 72.13%, where
packMP2 0.8 makes 76.95% at best (measured 01/11/2026, [how][wBench];
[doc/CODEC.md](doc/CODEC.md)). It is slow for now: about 0.65 MB/s to
compress a file on 2 threads and to extract it on one, where packMP3
does about 3 MB/s. Built bottom-up, each layer with its tests:

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
| the model's hot loop in C | | next |

## Building and testing

```sh
./run_tests.sh           # every layer's tests, with range and overflow checks on
```

Needs [Free Pascal](https://www.freepascal.org) 3.2.2.

## License

MIT; see [LICENSE](LICENSE) and [NOTICE](NOTICE).

[wHome]: https://github.com/YadeWira/PMPA/wiki
[wBench]: https://github.com/YadeWira/PMPA/wiki/Benchmarks
[wHandles]: https://github.com/YadeWira/PMPA/wiki/What-PMPA-handles
