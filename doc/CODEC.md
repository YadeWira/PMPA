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
| the local corpus's files with MPEG audio | 24 | 31.4 MB | 97.02% |

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
| the local corpus's files with MPEG audio | 24 | 31.4 MB | 97.02% | 94.18% |

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
| the corpus's MPEG files | 24 | 31.4 MB | 94.18% | 90.39% |

**A correction (01/11/2026):** the corpus figures first published for
versions 1 to 3 (96.74%, 94.42%, 90.99% of "24.8 MB") left out a 6.5 MB
file: its name has a space, and the awk that added up `pmpa list`'s
output read the wrong columns. The figures above are measured again, from
the files' sizes; `scripts/measure.sh` now measures that way, and checks
that every file comes back.

## The stream, version 4: a model that mixes (`pas/pmpamodel.pas`)

Version 4 codes Layer III's values, scalefactors and part2_3_length anew.
`pas/pmpamodel.pas` comes from PJA by way of PRA: hashed counters, a
logistic mixer (with SSE4.1 assembly; `PMPA_NOASM=1` takes the Pascal
path, and `run_tests.sh` checks that both make the same streams) and an
APM, all in 32-bit integers.

- **part2_3_length is not sent** for a granule whose values are modelled:
  it is its scalefactors' bits, plus its values coded again, plus its tail,
  whose length is sent (one decision when there is none). The side
  information is written, and the CRC coded, once the frame's granules
  are. A decision says whether the frame's main data is where its side
  information puts it; the decoder checks every granule against the slot
  stream as it goes.
- **Scalefactors** are values: each bit mixes its place in the block
  kind's layout, the same place in the last granule of that kind and
  channel, the scalefactor sent before it, and the other channel's.
- **Values**: zero or not, the bit length (up to 4: values to 15), the bits
  below the top one, the linbits escape above 15; each decision mixes ten
  contexts (the two values before; the same value's neighbourhood in the
  granule before; the position, fine and coarse; the other channel's
  value; the change of global gain; the change of the value's quantization
  step (global gain, scalefactor, preemphasis, subblock gain); the step
  itself; how far the region's end is; a magnitude estimate from all the
  neighbours), then an APM in the context of the decision, the table and
  the estimate.
- **Signs** in the context of the other channel's sign at that place and
  of the value before's: they were 1 bit each, they are 0.98.
- **The count1 quadruples** in the context of where the last granule's
  values ended.

Measured with `scripts/measure.sh` on 01/11/2026 (8 threads, other work
running), and with packMP3 3.0f (`-nc`) on the same Layer III files:

| set | files | size | version 3 | version 4 | packMP3 3.0f |
|---|---|---|---|---|---|
| synthetic samples (codec streams only) | 41 | 723,039 B | 92.45% | 82.0% | |
| the corpus's MPEG files | 24 | 31.4 MB | 90.39% | 87.03% | |
| of them, Layer III | 11 | 24.2 MB | 88.4% | 84.04% | 84.36% (it stores one of them as it is) |
| of them, Layer II (not modelled yet) | 13 | 7.2 MB | | 97.15% | |

Where version 4's bits go on those 11 Layer III files (`pas/tests/bitcosts.pas`,
built with `-dPMPA_COSTS`): magnitudes 37.8% of the input, zero flags
20.9%, signs 19.9%, scalefactors 2.3%, the rest of the side information
2.4%, everything else under 1%.

**Speed is the price for now:** the corpus takes 31 s to compress (which
decodes to verify) and 13 s to extract on 8 threads, one file a thread;
packMP3 does a 6.5 MB file in 2 s. Every decision mixes ten counters.

## The stream, version 5: Layer I and II (`pas/pmpal12.pas`)

After its header (and CRC) a Layer I or II frame is its bit allocation,
Layer II's scfsi, its scale factors and its samples, then ancillary data.
Every field has a fixed length once the allocation is known, so
`pmpal12` writes back exactly what it reads. Layer II's allocation tables
(ISO/IEC 11172-3 B.2a to B.2d, 13818-3 B.1) are chosen by the bitrate per
channel and the sample rate (by the frame's length, in free format).

A grouped code word above what its levels allow (3 levels in 5 bits can
say up to 26, and some encoders write 27 to 31) is kept as it is: 280
frames of the real streams below have one. Parsing fails only when the
fields do not fit in the frame, or an allocation is not in the table; such
a frame is coded as bytes, after a decision that says so.

Version 5 codes, by mixing (`pmpamodel`):

- the **allocation**, subband by subband, in the context of the last
  frame's allocation in that subband, the subband before and the other
  channel;
- the **scfsi** and the **scale factors** that scfsi sends, by the last
  frame's, the one before in this subband and frame, the subband before
  and the other channel;
- the **samples**, subband by subband in time order, centred on their
  middle level: zero or not, the sign, the bit length of the magnitude and
  the bits below its top one. The contexts are the two samples before
  (the last frame's at the start) on a signed log scale, their linear
  prediction 2 x[i-1] - x[i-2], their magnitudes and the subband, the other
  channel's sample at the same time, and the scale factor; the mixer's
  weights are chosen by the quantization class and the decision;
- the **CRC** as one decision, and the **ancillary data** as bits.

The signs and the prediction are what pays: with magnitudes only as
contexts the 10 files below were 83.27% of their size, with the signed
samples before and the prediction 76.50%.

The local corpus has 13 Layer II files and no Layer I. The streams below
come from samples.ffmpeg.org (not part of this repository): its MPEG-1 and
MPEG-2 programs, transport streams, VCD and SVCD captures and AVI files
with MPEG audio, the audio taken out with `ffmpeg -c copy` (the encoders'
frames as they are), and its three Layer I streams. A stream labelled MP2
that holds AC-3 (a sample of a bug report) is left out, and of two copies
of one stream, one.

Measured with `scripts/measure.sh` on 01/11/2026 (8 threads, other work
running); packMP2 0.8 on the same files (`u`, then `c -O`; a file it
cannot take counts at its own size: one):

| set | files | size | version 4 | version 5 | packMP2, zpaq 5 | packMP2, zstd 9 |
|---|---|---|---|---|---|---|
| Layer II from samples.ffmpeg.org | 53 | 42.9 MB | | 72.08% | 76.95% | 87.07% |
| Layer I from samples.ffmpeg.org | 3 | 1.1 MB | | 51.57% | | |
| the local corpus's Layer II files | 13 | 7.2 MB | 97.15% | 78.37% | | |
| the local corpus's MPEG files | 24 | 31.4 MB | 87.03% | 82.75% | | |

`test_l12` reads and writes back every Layer I and II frame of those
streams and the corpus (99,598 of 99,599: the one left is cut short in a
transport stream), and every CRC matches.
