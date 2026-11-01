# The `pmpa` command

```
pmpa a [options] FILE...     compress:  song.mp3 -> song.pmpa
pmpa x [options] FILE...     extract:   song.pmpa -> song.mp3 (the original's extension)
pmpa list FILE...            what each .pmpa holds: original size, stored size, hash
```

| switch | what it does |
|---|---|
| `-o PATH` | output name with one input; a directory if it exists or ends in `/` |
| `--output-dir=DIR` | output directory, and nothing else |
| `-f`, `--force` | replace an existing output, only with something that verified |
| `-th N`, `--threads=N` | threads; by default the processors, up to 8, one file each. The `.pmpa` is the same whatever the threads. Each file's lines still come out in the order of the inputs |
| `--max-output=SIZE` | `x`: refuse a declared original above SIZE (`256M` by default, `K`/`M`/`G`, `0` = no limit) |
| `--keep-corrupt` | `x`: an output that does not verify stays as `NAME.corrupt` |
| `-n`, `--dry-run` | do everything but write |
| `-q`, `--quiet` | only errors |
| `--` | everything after it is a file, even if it starts with a dash |

Exit status: 0 when every file went through, 1 when any failed (each with
its line on stderr), 2 for a usage error. All warnings and errors go to
stderr.

## Nothing written that did not verify

- `a` writes the `.pmpa` only after the codec has decompressed its own stream
  and compared it with the input.
- `x` does, in order: validate the format; refuse a declared size above
  `--max-output` **before** decoding; decode with that size as the cap;
  check the size **and** the hash; and only then write.
- Writing creates the file without following links. With `-f`, it goes to a
  temporary file and is renamed on top: what was there is only replaced by
  something that verified. Nothing that fails deletes a file this run did not
  write.

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

Tested by `pas/tests/cli.sh` (47 cells: round trips, existing outputs,
links, damage, `--keep-corrupt`, `--max-output`, threads, every usage error).
