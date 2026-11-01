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

## The stream, version 6: the same models, faster

Version 6 codes what version 5 does, faster:

- Layer III's values: each context's hash is made once a value, not once
  a decision, and the decisions of one value (15 there can be: zero, bit
  length, the bits below the top one) share a line of 16 counters, the
  line the context's hash picks. Two of version 5's ten contexts are left
  out (the coarse position with the neighbours, and the magnitude
  estimate, which still picks the APM's context): without them the files
  were a little smaller. Without four, 0.13 points bigger on the corpus's
  Layer III; that was not worth the 15% it saved.
- Layer I and II's samples: the contexts' hashes once a sample, each
  decision mixed in by one multiplication.
- Compressing a file with 2 threads or more verifies on a second thread,
  decoding the stream as it comes out (`TLiveStream`), instead of after.
  The stream is the same either way (`test_codec` checks it).

Measured on 01/11/2026, one file (the corpus's 6.5 MB Layer III file), on a
machine with other work running:

| | version 5 | version 6 |
|---|---|---|
| compress, 1 thread | 25.5 s | 18.1 s |
| compress, 2 threads | (the same as 1) | 10.3 s |
| extract | 12.2 s | 9.8 s |

And with `scripts/measure.sh`, 8 threads, one file a thread:

| set | files | version 5 | version 6 |
|---|---|---|---|
| the corpus's MPEG files | 24 | 82.75%; 34.3 s / 14.3 s | 82.78%; 31.3 s / 10.5 s |
| of them, Layer III | 11 | 84.04% | 84.07% |
| Layer II from samples.ffmpeg.org | 53 | 72.08% | 72.13% |

Most of the time is still the mixing (counters, mixer, APM) and the
contexts made for each value, in Pascal: packMP3 does the 6.5 MB file in
2 s. The family's way is the model's hot loop in C, as PJA's.

## Layer III's values in C (`pas/pmpal3c.c`)

The hot loop of stream version 6's Layer III model (each granule's values:
their contexts, the mixing, the APM, the arithmetic coding) is also written
in C, the family's way (PJA's version 7 model). It writes the same streams
as the Pascal: `run_tests.sh` (gcc) and every CI platform (clang, MinGW-w64
gcc on Windows x86) compare the two (`PMPA_NOC=1` takes the Pascal path in
a program that has the C). The C takes no memory and calls no library:
`pas/pmpac.pas` hands it the tables once, `pmpacodec` the counters, mixer,
APM and coder's state for each granule, and two callbacks carry bytes in
and out of the coder; the structs' layout is checked against the Pascal
records before the C is used.

Measured on 01/11/2026 (clang 19, the same machine and load as before):

| | Pascal | C |
|---|---|---|
| a 6.5 MB MP3, compress, 1 thread | 18.1 s | 12.1 s |
| the same, 2 threads | 10.3 s | 6.1 s |
| the same, extract | 9.8 s | 4.7 s |
| the corpus's 24 MPEG files, 8 threads, compress / extract | 31.3 s / 10.5 s | 22.5 s / 6.3 s |

Layer I and II's samples followed (`pmpac_samples`), the same way: on
the 56 Layer I and II streams from samples.ffmpeg.org, 8 threads, compress
20.6 s -> 13.3 s and extract 10.9 s -> 6.9 s; one 2 MB MP2 extracts in
1.6 s instead of 2.8 s. The suite also checks that the C is in use where
it is linked (a layout that does not match would leave every comparison
comparing the Pascal with itself).

## Speed, without touching the format (01/11/2026)

What is left is the models' arithmetic itself: decoding the first 400 KB
of the 6.5 MB MP3 is 2.58 million decisions, about 376 instructions each
in C (8 counters looked up and updated, a mixer of 9 inputs trained, an
APM, the coder), and that is two thirds of the run. Measured with
callgrind (instructions, which other work on the machine does not move):

- `squash` by a table instead of its interpolation: 2.230 to 2.194
  billion instructions (1.6%). Kept.
- The mixer's dot product and training in SSE4.1 (the same integers, four
  lanes at once): with 9 lanes the calls cost more than they saved, best
  of three 5.29 s against 4.96 s without. Dropped.
- The command takes the files largest first (their lines still come out
  in the order of the inputs), so that a big file does not start last: the
  56 Layer I and II streams from samples.ffmpeg.org, 8 threads, compress
  13.3 s -> 8.5 s, extract 6.9 s -> 4.5 s. The corpus (whose time is its
  6.5 MB file on one thread) does not move beyond the noise of other work.

More would change the format: fewer contexts for the commonest decisions
(four fewer cost 0.13 points on Layer III), cheaper hashes, or a file cut
into bands coded on their own (PRA's way), which costs a little of the
model's learning at each cut.

## The stream, version 7: bands

Version 7 codes what version 6 does, in bands: a file is cut, at a
segment's start, into bands of 2 MiB or more (`BandBytes`), each coded
with a model and an arithmetic coder of its own, so that the bands of a
file are coded and decoded at once on as many threads. The cut depends on
the file alone: the stream is the same whatever the threads (`test_codec`
checks it with bands of 4 KB, and decoding on 1 and on 4 threads).

```
version     1 B      7
length      varint   the original's length
bands       varint   how many
            then, for each: where it starts in the file (from the band
            before; the first at 0), varint; its bytes' length, varint
            then their bytes, one band after the other
```

A run of Layer III frames ends at a band's end: the next band starts its
own slot stream, and the frames at its start whose main data the bit
reservoir puts in the band before are not mapped, their slots coded as
filler in the band that holds them. No band reads or writes a byte of
another's (the bytes before a band are not even a context: another thread
may not have decoded them yet), and each band is decoded from a copy of
its own bytes, so that what its coder reads past its end is zeros, as it
was for the encoder. The encoder only reads the file: the bands share it.

A file of one band is verified as before, on a second thread as it is
written; one of several is coded on up to `-th` threads, then decoded on as
many and compared.

Measured on 01/11/2026 (clang 19; the machine had other work running, a
load of 14 to 74):

| | version 6 | version 7 |
|---|---|---|
| the corpus's Layer III files | 84.07% | 84.12% |
| Layer II from samples.ffmpeg.org | 72.13% | 72.17% |
| a 6.5 MB MP3 (4 bands), compress on 1 / 2 / 4 threads | 12.1 / 6.1 s | 12.1 / 6.6 / 3.6 s |
| the same, extract on 1 / 2 / 4 threads | 4.7 s | 5.2 / 3.0 / 1.6 s |

With more files than threads each file gets one thread, as before, and
the bands of a file are coded one after the other.

Tried and dropped (01/11/2026): the command taking the files of two bands
or more one after another, each on every thread, before the others. On the
corpus, alternating rounds with the version without it at a low load:
compress 19.6 s against 19.4 to 20.0, extract 7.4 to 8.1 s against 5.7 s.
A file of 3 or 4 bands keeps 3 or 4 of 8 threads busy, where all the
files at once kept all 8. Doing better needs one pool of bands for every
file, across the command, packing and the codec.

## The stream, version 8: album covers through PJA (`pas/pmpaid3.pas`)

An ID3v2 tag keeps a picture in an APIC frame (v2.3, v2.4) or a PIC frame
(v2.2). `pmpaid3` finds those whose bytes are a JPEG (by their first
bytes: the MIME type may say `image/jpg`, or `JPG` in v2.2), past an
extended header, a frame's group byte and data length, with the
unsynchronisation of the tag (v2.2, v2.3) or of the frame (v2.4) undone,
and says where their raw bytes are in the file. Unsynchronisation is done
again in one of two ways (a 0 after each FF before a byte of E0 or more,
or a 0; or after each FF); a picture is kept only if one of them gives the
file's very bytes. Compressed and encrypted frames are left alone.

Version 8 codes an ID3v2 tag as its parts in order: how many pictures;
for each, the bytes before it (as before), its raw length, the way, and
the stream of the vendored PJA 0.6.2 (`vendor/pja`: `pjacodec.Compress`
with its version 7 model, verified; its length, then its bytes at even
odds, being compressed already); then the bytes after the last one. A
picture PJA does not take, or does not make smaller, stays bytes, as
everything else in the tag does (PNG and other pictures, text, padding).

PNG covers wait for a release of PPA with a stream that no longer changes
(its author's advice: until then they are bytes).

What covers are, measured on 01/11/2026: the local corpus has none. Of
300 MP3 files taken from archive.org (an original file of each of 300
items of its netlabels, open-source audio, LibriVox and music
collections, the first MB of each), 276 have an ID3v2 tag and 62 a
picture: 56 JPEG (about 185 KB each), 6 PNG (about 390 KB), nothing else;
14 say `image/jpg`; 4 tags are unsynchronised. `tests/covers` holds each
way a tag can keep one, made by `scripts/mksamples.py`.

| set | files | size | version 7 (0.1.0) | version 8 |
|---|---|---|---|---|
| the 296 archive.org files PMPA takes (their first MB) | 296 | 299.4 MB | 81.31% | 80.38% |
| of them, the 53 whose JPEG cover PJA took | 53 | 54.8 MB | 84.82% | 79.84% |

Only their first MB was taken, where a cover weighs more than in a whole
file: in a 5 to 10 MB MP3, a 200 KB cover is 2 to 4% of it, and PJA takes
about a quarter off it.

Against packMP3 3.0f, which recompresses JPEG covers too (with packJPG),
on the 55 of those files whose cover is a JPEG (`packMP3 a -p`, covers on;
it fails on 4 of them, cut at 1 MB, which count at their own size):
packMP3 82.49%, PMPA 0.1.0 84.51%, PMPA 0.2.0 (version 8) 79.60%; on the 51
packMP3 takes, 81.37%, 84.48% and 79.38%.
