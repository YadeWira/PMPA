# The `pmpa` command

```
pmpa a [options] FILE...     compress:  song.mp3 -> song.pmpa, take.mp2 -> take.pmpa
pmpa x [options] FILE...     extract:   song.pmpa -> song.mp3 (the original's extension)
pmpa list FILE...            what each .pmpa holds: original size, stored size, hash
pmpa t FILE...               test each .pmpa: extract and verify in memory, write nothing
pmpa info FILE...            the structure of each file, and what PMPA does with it
pmpa report [FILE]           a bug report (no audio, no tag contents) and a link to open an issue
pmpa bench FILE...           how fast this machine runs a, a --no-verify and x on them
pmpa selftest                the samples inside the binary, on every SIMD path here
pmpa --version, pmpa -V      the build, the compilers, the system and the SIMD path
```

The commands, switches and exit codes are PJA's (the family's, from
PJA's `doc/CLI.md`); what is PMPA's own is said where it differs.

| switch | what it does |
|---|---|
| `-o PATH` | output name with one input; a directory if it exists or ends in `/` |
| `--output-dir=DIR` | output directory, and nothing else |
| `-f`, `--force` | replace an existing output, only with something that verified |
| `-th N`, `--threads=N` | threads; by default the processors, up to 8. They go to files first, several at once, the largest first, and a file also takes for its bands (2 MiB each, stream version 7 on) as many of the free ones as its share of the bytes not yet started is of N, so that the last files take what the others left. A file of one band takes two threads when it can: its stream is decoded and checked on the second while it is encoded. The `.pmpa` is the same whatever the threads. Each file's lines still come out in the order of the inputs |
| `--max-output=SIZE` | `x`: refuse a declared original above SIZE (`256M` by default, `K`/`M`/`G`, `0` = no limit) |
| `--keep-corrupt` | `x`: an output that does not verify stays as `NAME.corrupt` (`pmpa.corrupt` beside it if that name would be too long): one whose hash does not match, and since 0.3.1 one whose size is not the one the `.pmpa` declares (what the stream gives, within `--max-output`) |
| `--no-verify` | `a`: do not decompress the stream to check it before writing. On one thread about 1.8 times as fast on a 17 KB MP3 (with two threads or more a file of one band is checked on the second while it is encoded, which costs less); a codec bug would then only show when extracting, where the hash catches it. The covers' JPEGs are still checked by PJA, and the `.pmpa` is the same byte for byte |
| `--no-sync` | `a`, `x`, `report`, `bench`: do not wait for each output to reach the disk before it takes its name. A few percent faster on a real disk (none on tmpfs), but after a power cut an output may be empty or missing ([below](#interrupted-runs)). `bench` then measures its write without the flush |
| `--clean-temps` | `a`, `x`: delete the temporaries an interrupted run left in the directories this run writes to: only PMPA's (`.pmpa-tmp-PID-N`, and the `NAME.pmpa-tmpN` of 0.2.0 and earlier), only regular files, only older than an hour, and never one whose process is still running ([below](#interrupted-runs)) |
| `-n`, `--dry-run` | do everything but write: an output that exists, or that two inputs share, or (`x`) a `.pmpa` whose size or hash does not match, fails as it would for real |
| `-q`, `--quiet` | only errors (`--stats` lines still come out, each under its file's name: they were asked for) |
| `--stats` | `a`, `x`, `t`: after each file, where its time went (below), its threads and its bands; then a line for the run: files, bytes in and out, time, MB/s of the originals |
| `--json` | `a`, `x`, `t`, `info`, `list`: one JSON object a line for each file, in the order of the inputs, then `{"summary": ...}`; errors still go to stderr as well |
| `--cpu=PATH` | the model's SIMD path: `plain` or `sse41`, before or after the command (`--cpu plain`, with a space, is refused naming `--cpu=plain`). A path this processor or this build lacks is refused (exit 2) naming those it has. Every path writes and reads the same bytes: only the speed changes (`selftest` proves it; `selftest --cpu=PATH` checks that path alone) |
| `-o REPORT` | `report`: the file the report goes to (never over an existing one) |
| `--with-file` | `report`: also copy the file beside the report as `pmpa-report-NAME`, to attach if you choose to (without FILE it is refused: exit 2) |
| `-r N` | `bench`: runs of each measure, the best one counts (3 by default) |
| `--` | everything after it is a file, even if it starts with a dash |

All warnings and errors go to stderr.

| exit status | when |
|---|---|
| 0 | every file went through (`t`: every `.pmpa` verified; `selftest`: every check passed) |
| 1 | a file failed: it is not what the command takes, it is damaged, it could not be read or written (each with its line on stderr); the command's own output could not be written (a full disk, `pmpa: could not write the output: ...`); `selftest`: a check failed |
| 2 | usage error: an unknown command or option, a value out of range, an option for another command, `--cpu` with a path not here |
| 3 | a bug in PMPA: an exception that is not about the file or the system (a range check, an access violation, an assertion; not a read or a write the system refused, nor memory it did not give). The run ends with `This is a bug in PMPA. Please run: pmpa report FILE and open an issue at https://github.com/YadeWira/PMPA/issues` |
| 130, 143, 129, 141 | ended by SIGINT (Ctrl-C), SIGTERM, SIGHUP or SIGPIPE, after deleting the temporaries it was writing ([below](#interrupted-runs)); `STATUS_CONTROL_C_EXIT` on Windows |

A run time error the run time library does not turn into an exception (none
is known) would end with its own number, which is 200 or more.

## Checking and reporting

These are for helping: telling what happened, on which machine, in a form
that can be pasted into an issue, and checking a build before trusting it.

### `pmpa t FILE...`

What `x` does, without writing: the format, the declared size against
`--max-output`, decoding, then the size and the BLAKE3-128. A line
`NAME: OK` for each one that verifies, `pmpa: NAME: FAILED: why` on stderr
for each that does not (exit 1). Takes `-th`, `-q`, `--max-output`,
`--stats` and `--json`; `-o`, `-f`, `-n` and `--keep-corrupt` are refused
(exit 2).

### `pmpa info FILE...`

Any file: what it is and what PMPA does with it. Each format has a provider
(`pas/pmpainfo.pas`; a new format is one more unit):

- **.pmpa** (`pas/pmpainfopmpa.pas`): the container (version, flags, the
  original's size, BLAKE3-128 and extension, stored or not) and the
  stream: its version, the original's length it declares and, from
  version 7, its bands (where each starts in the file, how many bytes of
  the stream it takes; past 64, counted). Nothing is decoded for this. A
  `.pmpa` is described as one even when it stores an MP3 as it is.
- **MPEG audio** (`pas/pmpainfompeg.pas`), as the codec's scanner sees it:
  the streams (version, layer, sample rate and channel mode, with their
  frames, bit rates or free format, and how many carry a CRC; past 32,
  counted), the frames and their bytes, the length in seconds; the tags
  (ID3v2 with its version and unsynchronisation, ID3v1, APE, Lyrics3),
  each with its place and length, and in each ID3v2 tag the JPEG pictures
  PMPA takes through PJA (place, length, how their bytes are kept); the
  bytes that are neither frames nor tags (a container's headers, junk); the
  container when the file starts as one PMPA knows (RIFF WAVE, MP4,
  MPEG program stream).

Then `pmpa: ...`: for a `.pmpa`, whether it extracts and verifies (one that
declares an original larger than `--max-output` is not decoded, as `x`
refuses it); for anything else, `a`'s dry run with the verification: `takes
it: stream version 8, 17135 B -> 12571 B (73.36%)`, `takes it: stored as is
(the stream would not be smaller), ...`, or `refuses it: NotMpeg(no MPEG
audio frames)`. Exit 1 only for a file that cannot be read. `--json` gives
the same tree.

What the tags say is never printed, only their size: `metadata_bytes: ID3v2
24244 B, ID3v1 0 B, APE 0 B, Lyrics3 0 B; contents not shown`.

### `pmpa report [FILE] [-o REPORT.txt] [--with-file]`

A plain-text bug report, to stdout or to `-o`'s file:

- PMPA: version, commit, build date, FPC's version, the C compiler, the
  target; the system, the processor's name and features, the SIMD path in
  use and those it could take, whether the C loops run, the path the
  covers' JPEG model takes, the processors, the threads;
- the command line, each path cut to its name (an option's value too:
  `--output-dir=NAME`; a path after `--` that starts with a dash as well);
- for FILE: its size, BLAKE3-128, what PMPA does with it (`a`'s dry run,
  with the verification) and its structure, as `info` gives them. Above 64
  MB there is no dry run (`not estimated: the file is larger than 64 MB`),
  only the structure.

**What is not in it**: no audio, no tag contents (titles, comments, lyrics,
the pictures: only their sizes and places), no folder names. A report on a
file that hits a bug says so (`internal_error`) instead of ending.

Then a link that opens a new issue on GitHub with the report in it
(`https://github.com/YadeWira/PMPA/issues/new?template=bug_report.yml&title=...&body=...`):
a report too long for a link (about 6000 characters) keeps its start (PMPA,
the system, the command) and its end (the streams, the tags' sizes, what
PMPA does), with a line in their place saying how many lines were cut and
to paste the whole report; the line before the link says so too.
`--with-file` copies FILE beside the report as `pmpa-report-NAME` (never
over an existing file): it goes nowhere unless you attach it, which shows
the very bytes; GitHub does not take audio files, so zip it first. Without
FILE, the system part alone, for a problem with no file.

### `pmpa bench FILE... [-r N] [-th N]`

Prints the system part of the report, then for each file the best of N
runs (3 by default) of `a`, `a --no-verify` and `x`, in milliseconds and
MB/s (2^20 bytes) of the original, with where `a`'s and `x`'s time went,
and the write of the `.pmpa` alone; then the totals. Everything is in
memory but that write, which goes to a folder of its own in the system's
temporary folder and is deleted: nothing is written beside the inputs. A
`.pmpa` given is only extracted.

### `pmpa selftest`

The binary carries five small samples (`pas/pmpaselftest.inc`, written by
`pas/tests/gen_selftest.pas` from `tests/`): the start of a Layer I, a
Layer II and a Layer III file with CRCs, an MP3 whose ID3v2 tag holds a JPEG
that goes through PJA, and the Layer III one again as stream version 7,
the stream 0.1.0 wrote; and the `.pmpa` each one has to give. On every SIMD
path the processor has, with one thread and with two (two decode the
stream while it is encoded), each is compressed, compared byte for byte
with its expected `.pmpa` (whose BLAKE3-128 it prints), and extracted back;
the version 7 one is only extracted. `--cpu=PATH` checks that path alone.
Exit 0 only if every check passed. CI runs it on every platform, and
`run_tests.sh` checks that the include is the codec's current output.

### `pmpa --version`

```
pmpa 0.3.0
commit: 074217f
built: 2026/11/11
fpc: 3.2.2
c_compiler: gcc 14.2.0
target: x86_64-linux
system: Linux 6.12.115+deb13.1-amd64 x86_64
cpu: Intel(R) Xeon(R) CPU E5-2697A v4 @ 2.60GHz
cpu_features: sse2 sse4.1 avx2
cpu_path: sse41
cpu_paths_supported: plain sse41
stream_version: 8
c_loops: on (Layer III values, Layer I and II samples)
covers_jpeg_path: avx2
processors: 64
default_threads: 8
```

The commit comes from `PMPA_COMMIT` at build time: `.github/test.sh` and
`pas/run_tests.sh` set it from git when it is not set (in a release, the
tag's commit); a build without it says `commit:` and nothing.

### `--cpu=PATH`

PMPA's mixer (`pas/pmpamodel.pas`) has plain code and, on x86-64, an
SSE4.1 copy. The path is chosen at start from cpuid (`PMPA_NOASM=1` turns
the copy off); `--cpu` chooses it instead, to compare speeds or to rule a
path out when chasing a bug. 32-bit builds have the plain path only. The C
loops (`pas/pmpal3c.c`, the Layer III values and the Layer I and II
samples) have no SIMD copy and run on every path (`PMPA_NOC=1` leaves them
to Pascal: the same streams). The covers' JPEG model is PJA 0.6.3's, which
picks its own path from cpuid (`PJA_NOASM=1`, `PJA_NOAVX2=1`); that
release has no public switch for it, so `--cpu` does not reach it, and
`--version` says which one it takes (`covers_jpeg_path`). Its paths write
the same bytes too.

### `--stats`

```
song.mp3 -> song.pmpa  16.7 KB -> 12.3 KB  73.36%
  stats: read 0.04 ms, parse 0.07 ms, encode 38.91 ms, verify 30.55 ms, hash 0.07 ms, write 0.10 ms; total 69.74 ms; 1 thread(s), 1 band(s)
pmpa: 1 file(s), 16.7 KB -> 12.3 KB, 69.96 ms, 1 thread(s), 0.23 MB/s
```

The stages: `read` the input; `parse` the scan of its frames and tags and
the bands' plan (`a`); `encode` the model (the covers through PJA
included); `verify` decoding the stream to compare it with the input (with
two threads or more, a file of one band is decoded on the second thread
while it is encoded, and that time is `encode`'s); `decode` (`x`, `t`);
`hash` BLAKE3; `write` the output, verified, flushed to the disk (unless
`--no-sync`) and renamed; `other` what falls between. `threads` are the
file's own (what `-th` leaves each file), `bands` the stream's.

### `--json`

One object a line, so that `python3 -c 'import json'` or `jq` read it
line by line:

```
{"file":"song.mp3","output":"song.pmpa","original_size":17135,"pmpa_size":12571,"ratio_percent":73.36,"stored":false,"ok":true}
{"summary":{"command":"a","files":1,"failed":0,"bugs":0,"bytes_in":17135,"bytes_out":12571,"seconds":0.045,"threads":8}}
```

The same thing has the same name in every command: `original_size` is
the original's bytes, `pmpa_size` the `.pmpa`'s.

| command | fields of each file (after `"file"`) |
|---|---|
| every one | `ok` (`true`: it went through; for `info`, it was read and described); `error` (what failed, as on stderr) when it did not; `internal_error` when it met a bug |
| `a` | `output`, `original_size`, `pmpa_size`, `ratio_percent`, `stored` |
| `x` | `output`, `original_size`, `pmpa_size` |
| `t` | `original_size`, `pmpa_size` |
| `list` | `original_size`, `pmpa_size`, `ratio_percent`, `stored`, `extension`, `blake3_128` |
| `info` | the tree the text shows: `format`, `size`, and the format's own (MPEG audio: `streams`, `frames`, `seconds`, `tags`, `jpeg_pictures`, `other_bytes`, `metadata_bytes`...; `.pmpa`: `container`, `stream` with `version` a number and `bands`); then `pmpa`: `command` (`a` or `x`), `ok`, `summary` (the line of the text), and for `a`: `takes`, `stream` (in words), `stream_version` (a number; 0 for stored as is), `pmpa_size`, `ratio_percent`, or `error`; for `x`: `original_size` or `error` |
| `--stats` (`a`, `x`, `t`) | `stats`: each stage's `NAME_ms`, `total_ms`, `threads`, `bands` |

The summary: `command`, `files`, `failed`, `bugs`, `bytes_in`, `bytes_out`,
`seconds`, `threads`.

## Nothing written that did not verify

- `a` writes the `.pmpa` only after the codec has decompressed its own stream
  and compared it with the input (unless `--no-verify` is asked for: a
  program that checks on its own, such as an archiver, need not pay for it
  twice).
- `x` does, in order: validate the format; refuse a declared size above
  `--max-output` **before** decoding; decode with that size as the cap;
  check the size **and** the hash; and only then write.
- Writing creates the file without following links, always as a temporary
  in the same directory (`.pmpa-tmp-PID-N`) that takes the output's name
  only once it is complete **and on the disk** (`fsync`; `FlushFileBuffers`
  on Windows), and on Unix the directory is flushed after the name is
  given: after a power cut the output is either whole or not there, never
  empty or partial under its name. (Windows has no call to flush a
  directory: the name is left to the file system's journal, so a power
  cut just after a run may lose a name, never give it a partial file.) If
  only that last flush fails, the run fails (rc 1) with `written, but its
  directory could not be flushed to the disk`: the output is in place and
  whole, and a rerun needs `-f`. A run
  cut short (Ctrl-C, a kill, a full disk) never leaves a truncated file
  under the output's name. Without `-f` the name is only taken if it is
  still free; with `-f` the temporary is renamed on top: what was there is
  only replaced by something that verified. Nothing that fails deletes a
  file this run did not write. (On a file system without hard links, such
  as FAT, it is written in place when there is no `-f`.)

## Interrupted runs

- **Ctrl-C, `kill`, a closed terminal, a closed pipe**: SIGINT, SIGTERM,
  SIGHUP and SIGPIPE (`pmpa x ... | head`; on Windows Ctrl-C, Ctrl-Break
  and closing the console) delete the temporaries the run is still
  writing, and it ends as the signal would have ended it (exit status 130
  for SIGINT, 143 for SIGTERM, 129 for SIGHUP, 141 for SIGPIPE;
  `STATUS_CONTROL_C_EXIT` on Windows). Outputs already written stay:
  each one verified. A signal ignored by whoever started `pmpa` (`nohup`, a
  background job of a script) stays ignored.
- **`kill -9`, a crash, a power cut**: nothing can run then, so a
  `.pmpa-tmp-PID-N` may stay. The next run that writes in that directory
  names them on stderr (`found 2 leftover temporaries of an interrupted
  run: ...; --clean-temps deletes them`), once per directory, and deletes
  nothing unless `--clean-temps` is given. Either way only names of PMPA's
  own pattern count, only regular files (a link or a directory with that
  name is left alone), only older than an hour, and never one whose process
  (the PID in its name) is still running. With `-n` they are only named.
  The notice is a warning on stderr, shown even with `-q`. The PID is
  checked in this machine's process table (`kill(pid, 0)`; `OpenProcess`
  on Windows): in a directory shared with another machine or container
  (NFS, a bind mount) another run's temporary cannot be told alive, and
  the hour of age is the only guard, so do not use `--clean-temps` there
  while another machine may be writing.
- **What flushing costs**: measured by PJA (on 151 photos, `-th 8`, a SATA
  SSD: 4 to 7% longer; on tmpfs under 1%); PMPA writes the same way. It is
  on by default; `--no-sync` turns it off for a run whose outputs can be
  made again: a power cut may then leave an output empty or missing. The
  temporary and the handlers above work the same either way.
- **The flush beside the work** (PJA's committer): `a` and `x` hand each
  file's write, flush and rename to a thread of their own and go on with
  the next file; the file's line comes out once its write is done, in the
  same order, and the run ends only when every write has. At most 8 writes
  wait (their bytes in memory). Not with `--no-sync` (nothing to wait for),
  `-n`, or `--stats` (which times the write in the file's own stages);
  `PMPA_SYNC_INLINE=1` writes in the file's own thread.

## Choices, and why

These are PJA's, where they were agreed and measured; PMPA keeps them so
that the family's commands behave the same.

- **An existing output is refused without `-f`.** Otherwise
  `pmpa a -o a.pmpa b.mp3` silently replaces `a.pmpa`.
- **`-o` behaves like the destination of `cp`**: an existing directory or a
  path ending in `/` is a directory, anything else a name. **With more than
  one input, a destination that is not a directory is an error**: without
  that guard, `pmpa a *.mp3 -o one.pmpa` would write every input over the
  same file and the last one would win.
- **Two inputs with the same output in one run: the second fails**, with or
  without `-f` (`a.mp3` and `a.mp2`, `d1/s.mp3` and `d2/s.mp3` with
  `--output-dir`, the same file twice), naming the input that took it; so
  does an output that is another input of the run. For `a` it is always the
  later input; for `x`, whose names come from inside the `.pmpa`, whichever
  finishes second.
- **On Unix a backslash is part of the name**, not a separator:
  `a\x.mp3` gives `a\x.pmpa`.
- **Values with `=` or a space, never glued**: `-th 4` or `--threads=4`. A
  glued `-th4` is refused naming the right spelling.
- **There is no bare `-t`.** `-th` is two letters; with no `-t`, it can never
  be read as `-t -h`.
- **`a` and `x` are filters**: `a` refuses a `.pmpa`, `x` anything that is not
  one. There is no mode that does both; shell globs separate them.
- **The output keeps the original's extension**, as it was written:
  `song.MP3` comes back as `song.MP3` (the `.pmpa` keeps it, with a check).
  The name is the `.pmpa`'s own. When there is none to keep (an extension
  the format does not take: more than 15 characters, or anything but
  letters, digits, `_` and `-`), the first frame's layer decides: `.mp1`,
  `.mp2` or `.mp3`.
- **`a` refuses what it does not understand**, naming why: a file with no
  MPEG audio frame is `not MPEG audio PMPA takes (no MPEG audio frames)`.
  PMPA is not a general compressor.
- **Never larger than the original by more than 52 bytes** (37 and the
  extension): a file the codec does not make smaller is stored as it is,
  and `a` and `list` say so.
- **On Windows, `pmpa` expands `*` and `?` itself**, because neither `cmd`
  nor PowerShell does it for a program: `pmpa a music\*.mp3` takes every
  file that matches, in order of name, folders left out. Only the name part
  is a pattern. A pattern that matches nothing fails as `no file matches`,
  and the other inputs still go through. Elsewhere the shell expands them.
- **A write the system refuses is reported in its own words**, with the
  error number: `could not write it: Not a directory (Io(20))`.

Tested by `pas/tests/cli.sh` (114 cells: round trips, existing outputs,
links, damage, `--keep-corrupt`, `--max-output`, threads, every usage error;
the signals and the disk flushes, held at their `fsync` with `strace`;
leftovers and `--clean-temps`; `--no-verify`; `t`, `info`, `report` and
its privacy, `bench`, `selftest`, `--cpu` on every path here, `--stats`,
`--json`, and the end of a run that meets a bug).
