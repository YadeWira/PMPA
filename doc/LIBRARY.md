# libpmpa: PMPA as a library and a 7-Zip plugin

`libpmpa` (since 0.5.0) is one shared object (`pmpa.so`, `pmpa.dll`,
`pmpa.dylib`) that does two jobs, as PJA's `libpja` and PPA's `libppa` do
(their shape, their code where the format does not differ):

- a **C library** (`pas/lib/pmpa.h`) for any program: one file in memory to
  a `.pmpa` and back, and a **filter** over a stream of any bytes;
- a **codec plugin for 7-Zip and 7-Zip-zstd**, the method `PMPA`, which is
  that filter.

PMPA's formats are not frozen before a 0.9.x (`FORMAT.md`,
`STABILITY.md`): what a published release wrote is read by every later
one, but a `.pmpa`, a filter stream or a 7-Zip archive a later release
wrote may not open in an earlier one, which then says so
(`PMPA_E_VERSION`, 7-Zip's "Unsupported Method").

It is built from `pas/lib/`: `pmpalib.pas` (the library, its exports and
PMPA's codec), `pmpafilter.c` (the filter), `pmpa7z.c` (7-Zip's
interfaces), plus PMPA's C part (`pas/build_c.sh`, which builds the
vendored PJA's for the covers too):

```sh
pas/lib/build.sh build/lib                                   # Linux: pmpa.so
CC=x86_64-w64-mingw32-gcc FPC="fpc -Twin64 -Px86_64" pas/lib/build.sh build/w64   # pmpa.dll
```

## The filter

An archiver that puts many files into one stream (7-Zip's solid blocks)
cannot hand PMPA one file at a time. The filter takes the stream as it is,
finds the MPEG audio inside it, recompresses each run of frames with PMPA's
codec (verified: it must come back byte for byte), and passes **every
other byte through untouched**, so that the archiver's own compressor
(LZMA2, zstd) still sees them:

```
solid block ──► PMPA filter ──► [ raw bytes | run as PMPA | raw bytes | ... ] ──► LZMA2 ──► archive
```

### How it finds a run

MPEG audio has no end marker, so what the filter takes is a **run of
frames**: at least three in a row, each header valid (no reserved field,
not free format) and of the same stream (MPEG version, layer, sample rate)
as the first, each frame starting where the one before ends, and each
followed by another such header, a tag (`TAG`, `ID3`, `APETAGEX`) or the end
of the input. That last rule matters in a solid block: a file cut short
ends in part of a frame whose header gives a length that runs into the
next file; without it the run swallowed the next file's ID3v2 tag, and its
cover went to LZMA2 as bytes (measured: 84.74% instead of 79.60% on the 55
covers). With the run go the ID3v2 tag that ends where it starts (and up
to 64 KiB of zero padding after the tag) and the 128-byte ID3v1 tag that
starts where it ends. A run PMPA does not take, that does not come back or
that does not get smaller stays among the raw bytes; one longer than 256
MiB is cut at a frame there and goes on as another.

### The stream

```
"PMPF" 01                 magic and version
records, each a tag byte:
  00 n bytes              n raw bytes (n a LEB128 number, 1 to 256 KiB)
  01 size n stream        a run of `size` bytes as PMPA's codec stream of n bytes
                          (pmpacodec.EncodeFile; 0 < n < size <= 256 MiB)
  FF                      the end
```

Tags 02 to FE are left for records of later releases: a decoder that meets
one stops with `PMPA_E_VERSION`, as it does at a filter version past its
own or a run whose codec stream is of a later version. Raw bytes go out in
records of 256 KiB counted from the end of the last run written, so the
stream is the same however the input was read, and whatever the threads.

### Threads

Runs go to a pool of threads as the filter finds them, up to eight per
thread (or 64 MiB) ahead of the oldest, which is written as soon as it is
done; so reading, compressing and writing overlap, and extracting works the
same way. A run alone gets the threads for its bands (2 MiB each). None of
this changes the stream.

## The C interface

`pas/lib/pmpa.h`. Every function can be called from several threads at
once, and no exception leaves the library: errors are return codes.

| function | does |
|---|---|
| `pmpa_version()` | `"pmpa 0.5.0"` |
| `pmpa_compress(in, size, &out, &out_size, threads)` | an MPEG audio file → a `.pmpa` (the command's format: size and BLAKE3 hash inside; no extension kept); `PMPA_E_NOT_TAKEN` for a file PMPA does not take or does not make smaller |
| `pmpa_decompress(in, size, &out, &out_size, max_size, threads)` | a `.pmpa` → the original, checked against its size and hash; `PMPA_E_VERSION` for one a newer PMPA wrote |
| `pmpa_filter_encode(read, ctx, write, ctx, threads)` | the filter: every byte read → its stream, written |
| `pmpa_filter_decode(read, ctx, write, ctx, threads)` | its stream → the bytes |
| `pmpa_free(p)` | frees what the library returned (never `free()`) |

Return codes: `PMPA_OK` (0), `PMPA_E_NOT_TAKEN` (1), `PMPA_E_DATA` (2:
damaged, or not PMPA's), `PMPA_E_MEMORY` (3: out of memory or over a size
limit), `PMPA_E_READ` (4) and `PMPA_E_WRITE` (5: the filter's callbacks),
`PMPA_E_ARG` (6), and `PMPA_E_VERSION` (7): the input was written by a
newer PMPA, a `.pmpa` format version, a codec stream version, a filter
version or record this release does not know. Those bytes can also be
damaged, and nothing tells the two apart there: damage that makes a codec
stream's first byte 10 to 255 gives `PMPA_E_VERSION` as well; damage
anywhere else gives `PMPA_E_DATA`. More codes may come; a caller treats one
it does not know as an error.

`threads` is 1 to 64 (outside that, the nearest). `max_size` caps the
original's size (0: the library's own cap, 2^31).

The settings the `pmpa` command reads from the environment (`PMPA_NOC`,
`PMPA_NOASM`, `PJA_NOASM`, `PJA_NOAVX2`) are put back when the library
loads: the C loops on, the best SIMD path the processor has. A host's
environment changes nothing (the streams are the same on every path; CI
runs the test with them set).

`pas/lib/test_lib.c` is the test, and an example: each file through
`pmpa_compress`/`pmpa_decompress` (the same bytes on one thread and two),
four threads compressing at once and forty short-lived ones (the same
bytes), all the files in one stream with bytes and false frame headers
between them through the filter, read 1 byte to 1 MiB at a time (the same
stream every time, and on one thread), damaged and cut filter streams, and
what a newer PMPA would write (a `.pmpa` of format version 2, codec
streams of versions 10 to 255, `PMPF` 02, records 02 to FE, a run record of
a later codec stream): `PMPA_E_VERSION` every time. 249 checks on the
repository's samples.

## The 7-Zip plugin

Put the library in the `Codecs` folder next to 7-Zip: `7z.exe` on Windows
(7-Zip or 7-Zip-zstd), `7z` and `7z.so` on Linux. The library's build must
be 7-Zip's: the x64 `pmpa.dll` for 64-bit 7-Zip, the x86 one for 32-bit
7-Zip. `7z i` lists the method:

```
 1  ED     37F20 PMPA
```

```sh
7z a -m0=PMPA -m1=LZMA2 music.7z music/        # 7-Zip
7z a -m0=PMPA -m1=zstd  music.7z music/        # 7-Zip-zstd
7z x music.7z
```

A stream a newer PMPA wrote (`PMPA_E_VERSION`) comes out of the plugin as
`E_NOTIMPL`, which 7-Zip reports as "Unsupported Method" for the block's
files, and damaged data as "Data Error".

`-mmt` sets the filter's threads when compressing; extracting, 7-Zip
gives its thread count only to the first coder of the chain that takes one
(LZMA2), so PMPA uses the processors (up to 8; 2 in a 32-bit 7-Zip).
**The archive needs the plugin to be extracted**, in every 7-Zip that
opens it. It works with 7-Zip on Windows and with 7-Zip 23 or later on
Linux and macOS; p7zip (the old port, `7z` 16.02) builds its interfaces
differently and does not load it.

Measured on 12/11/2026 with 7-Zip 25.01 on Linux (`-m0=PMPA
-m1=LZMA2:d=64m -mmt=8`, one archive per set, every file extracted and
compared): the archive against the input, and the times to write it and to
extract it, with other work running on the machine.

| set | files | 7-Zip + PMPA | 7-Zip `-mx9` alone | `pmpa` alone |
|---|---|---|---|---|
| corpus: every MPEG audio file | 24 | **82.83%**, 19.7 / 6.7 s | 95.72% | 82.81% |
| MP3 with a cover (the first MB of each) | 55 | **79.60%**, 17.2 / 7.4 s | 95.01% | 79.60% |
| MP2 and MP1 from samples.ffmpeg.org | 56 | **69.19%**, 14.7 / 7.7 s | 87.35% | 71.66% |

On MP3, LZMA2 after PMPA finds nothing more; on these MP2 streams it finds
2.5 points PMPA alone does not.

The method ID, `03 7F 20`, is in the slot 7-Zip's `DOC/Methods.txt` keeps
for an experimental method, in the family's share for PMPA (`03 7F 2x`;
PJA has `03 7F 01` and `02`, PPA `03 7F 11`), so that the plugins can sit
in the same `Codecs` folder; PMPA will move to an ID of its own with 1.0.0
(the family asks 7-Zip for one) and stay able to read this one.

On Windows the library takes its memory from the process heap (PJA's
`pjaheap.pas`, vendored), not FreePascal's own: FreePascal 3.2.2's heap, in
a DLL, deletes its lock when the thread that loaded the DLL ends, and
7-Zip's file manager loads its codecs from such a short-lived thread (PJA
found it). With the memory gone it returns nil, never a runtime error, so
a host gets `PMPA_E_MEMORY`. Each block has 16 bytes to spare after it
(PPA found, on Windows XP, that FreePascal's 32-bit code may read past the
end of an array).

PJA's codec (the covers' JPEGs) keeps its models (about 18 MB) in
threadvars, which FreePascal does not free when a thread of the host ends:
every call gives them back before returning, and so do the filter's
threads.

How it is made: 7-Zip's interfaces are C++ classes with only virtual
methods, which is a table of function pointers at the start of the object,
so `pmpa7z.c` builds them in plain C (`__stdcall` on 32-bit Windows). The
library exports `GetNumberOfMethods`, `GetMethodProperty`,
`CreateDecoder`, `CreateEncoder`, `CreateObject` and `GetModuleProp`
(which tells 7-Zip on Linux, since version 23, that `IUnknown` has no
virtual destructor, and gives the module's version, PMPA's: 0.50 for
0.5.0). Strings handed to 7-Zip are BSTRs of `wchar_t`: OLE's on Windows,
7-Zip's own layout from `malloc` elsewhere. CI builds the library on all
six platforms, runs `test_lib`, and on Linux x64 and Windows x64 writes an
archive of every sample through a real 7-Zip and extracts it.
