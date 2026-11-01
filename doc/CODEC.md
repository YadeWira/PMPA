# PMPA codec

How PMPA reads an MPEG audio file and what it does with it, layer by
layer, with what was measured along the way.

## The parser (`pas/pmpampeg.pas`)

The parser cuts the whole file into consecutive segments: frames, tags
(ID3v2 anywhere, ID3v1, APE and Lyrics3 v2 at the end) and raw bytes. The
segments tile the file, so a mistake by the parser only costs compression,
never exactness.

A frame is believed only as part of a run: 3 frames in a row of the same
stream (version, layer, sample rate, free format or not), or fewer that end
the audio or meet an ID3v2 tag. Once a run is believed, its frames are taken
for as long as they are of the same stream and fit. A frame the file cuts
short is raw. A free-format frame's length is the distance to the next
header of the same stream, tried candidate by candidate until one makes a
run.

Checked on 01/11/2026 against the 42 files of the local sample corpus that
`file` calls MPEG audio, or that have an MPEG audio extension (31.6 MB),
with ffprobe's packet count as the reference:

- 13 files: the same frames as ffprobe, or one more, which is the
  LAME/Xing frame that ffmpeg does not count as audio.
- 10 files: one frame fewer, and that frame is the one the file cuts short
  (1 to 62 bytes left), which ffprobe counts and PMPA keeps as raw.
- 1 file (a game's, with data chunks between its frames): one frame fewer,
  not yet explained.
- 18 files with no frames by either count: databases and other files with
  an `.mp1`, `.mp3` or `.bnd` name.
- The raw bytes inside the files with frames are not frames: a container's
  header before the audio (324 and 14,427 bytes), 835 zeros of padding
  after an ID3v2 tag, the game file's data chunks.

Of the 31.6 MB, 31.35 MB are frames and 0.25 MB raw.

## The stream, version 1 (`pas/pmpacodec.pas`)

```
version     1 B      1
length      varint   the original's length
segments    arithmetic-coded, to the end
```

The segments are the parser's, in order, until the original's length:

- the **kind**: 3 binary decisions, in the context of the kind before;
- a **frame**: its 32-bit header, each bit in the context of the same bit of
  the header before and of whether the bits so far all matched it; a
  free-format frame then gives its length without padding (the same as the
  last one, or 16 bits); then the frame's other bytes;
- **anything else**: its length (its bit length in 6 decisions, then the
  bits below the top one), then the bytes.

Bytes are coded bit by bit in the context of the bits of the byte so far:
alone inside frames (order 0), with the byte before elsewhere (order 1).
Order 1 inside frames made the samples 7.9% *larger* (65,536 contexts to
learn on data close to noise); order 0 makes them 95.11% of their size.

This version is a scaffold: it knows where the frames are and what their
headers say, not what is inside them. Measured on 01/11/2026:

| set | files | size | `.pmpa` |
|---|---|---|---|
| synthetic samples (`tests/`, codec streams only) | 41 | 723,039 B | 95.11% |
| the local corpus's files with MPEG audio | 24 | 24.8 MB | 96.74% |

Every file came back byte for byte. The 18 corpus files with no MPEG audio
frame were refused.
