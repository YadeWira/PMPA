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

**Status: in development.** Built bottom-up, each layer with its tests:

| Layer | Unit | Status |
|---|---|---|
| hash (BLAKE3-128) | `pas/pmpablake3.pas` | done, from PJA |
| binary arithmetic coder | `pas/pmpaarith.pas` | done, from PJA |
| MPEG audio frame parser (Layer I, II, III; MPEG-1, 2, 2.5) | | next |
| the stream's model and codec | | |
| the `.pmpa` container and the `pmpa` command | | |

## Building and testing

```sh
./run_tests.sh           # every layer's tests, with range and overflow checks on
```

Needs [Free Pascal](https://www.freepascal.org) 3.2.2.

## License

MIT; see [LICENSE](LICENSE) and [NOTICE](NOTICE).
