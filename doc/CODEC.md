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

## The stream, version 2: Layer III's structure (`pas/pmpal3.pas`)

Version 2 codes a Layer III frame by what it is. The decoder reads version
1 streams too (`test_codec` makes them and decodes them).

- The **side information**, field by field, each in the context of the
  bits of the field so far, of the same field in the granule before (the
  same channel's, in this frame or the last), and of whether the bits so
  far all matched it.
- The **CRC**, when there is one, as one decision: it is the one the header
  and side information give. When it is not, its 16 bits follow.
- The **slots**, as part of the run's slot stream (the slots of a run of
  frames laid end to end, in which the bit reservoir places each frame's
  main data): the filler up to where the frame's main data starts, then
  its main data. A decision after each frame says whether the run goes on;
  when it does not, the rest of the slot stream is filler.
- A frame whose main data does not fit (it starts before the run, or
  overlaps the frame before) leaves its slots to the filler.

The slot stream's bits are still coded as bytes are in version 1: in the
context of the bits of their byte so far (order 0), main data and filler
apart. With 12 bits of history instead, the samples came out at 96.57%
(4,096 contexts to learn on data close to noise).

Every Layer III frame of the samples and the corpus (55,388 frames) gives
its side information back bit for bit, all 65 CRCs match, and the main data
of every frame is where the reservoir says, but one: the frame after the
junk in `tests/odd/junk_between.mp3`, whose reservoir points into the junk.

Measured on 01/11/2026:

| set | files | size | version 1 | version 2 |
|---|---|---|---|---|
| synthetic samples (codec streams only) | 41 | 723,039 B | 95.11% | 93.73% |
| the local corpus's files with MPEG audio | 24 | 24.8 MB | 96.74% | 94.42% |

## The stream, version 3: Layer III's values (`pas/pmpahuff.pas`)

Each granule's main data is its scalefactors (part 2, whose length the side
information gives) and its Huffman-coded values (part 3). Version 3 decodes
the values and codes them instead of their bits:

- the scalefactors, as bits (as in version 2);
- one decision: the values are modelled (they decode, and coded again give
  the same bits), or the granule's bits follow as they are;
- how many count1 quadruples (8 bits, in the context of the last granule's);
- each value: whether it is 0; if not, "greater than k" for k = 1, 2, ...
  up to what its table allows; above 15 in a table with linbits, the
  escape's bit length and bits; then the sign. The contexts are what the
  table allows, the two values before, the same value in the granule
  before (same channel) and where in the granule the value is;
- the tail: what the bits hold after the last whole quadruple (a quadruple
  cut short, or stuffing after the 576th value), as bits. The decoder knows
  its length: what the values come to, taken from part 3's.

The Huffman tables are ISO/IEC 11172-3's (Annex B, table B.7): `test_l3`
checks that each is a complete prefix code and that every band table
covers 576 values. Region 1 of a block with window switching starts after
8 long bands, or 3 short bands in each window: 36 values in MPEG-1, 54 in
MPEG-2, 108 at 8 kHz (72 for short blocks).

Every granule of the samples (3,576) and of the corpus (204,850) decodes
regularly and, coded again, gives its bits back; 596 granules of one corpus
file and 38 of the shine sample carry a tail (1,049,048 and 11,116 bits).

Measured on 01/11/2026 (8 threads; with other work running):

| set | files | size | version 2 | version 3 |
|---|---|---|---|---|
| synthetic samples (codec streams only) | 41 | 723,039 B | 93.73% | 92.45% |
| the corpus's MPEG files | 24 | 24.8 MB | 94.42% | 90.99% |
| of them, Layer III | 10 | | | 73.5% to 93.1% |
| of them, Layer II (not modelled yet) | 13 | | | 94.5% to 98.2% |

The corpus takes 5.8 s to compress and 5.4 s to extract.
