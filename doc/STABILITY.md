# What does not change

PMPA's formats are not frozen yet. They will be in a 0.9.x release, once
they are mature, as PJA's were in its 0.9.0, and this page will then say
which release. Until then a release may write a new stream version, but
**what a published release wrote is read by every release after it**: a
`.pmpa` made by 0.1.0 or 0.2.0 opens in this one and in every later one.
1.0.0 comes when PMPA has a 7-Zip method ID of its own (below).

What may change at any time: speed, the encoder's choices (a later release
may write other, smaller bytes for the same file), and the files PMPA takes
(more, never fewer).

## The `.pmpa` file

`doc/FORMAT.md`. Magic `PMPA`, version 1 (written since 0.1.0); the stored
flag; the descriptor with the original's size, BLAKE3-128 and extension.
Flags past the stored flag, and versions past 1, are refused
(`UnknownFlag`, `FutureVersion`) before anything is decoded.

## The codec stream

`doc/CODEC.md`. Its first byte is its version:

| version | written by | read by |
|---|---|---|
| 1 to 6 | development builds before 0.1.0, never published | every release (`pas/tests/test_codec.pas` decodes each) |
| 7 | 0.1.0 (bands of 2 MiB, C hot loops) | every release since 0.1.0 |
| 8 | 0.2.0 and later (version 7, and the JPEG pictures in ID3v2 tags through PJA) | every release since 0.2.0 |
| 9 | 0.4.0 and later (version 8's layout, the pictures through PJA 0.9.8, which may write streams PJA 0.6 cannot read) | every release since 0.4.0 |

A version past its own is refused as `FutureVersion` before it is decoded,
never read as something else. A stream version that is published is never
changed: a new model, a new kind of segment or a new codec for the
pictures (PNG through PPA, for one) comes as a new version beside these.
`pmpa selftest` checks that this build writes its own stream for its
samples, and reads 0.1.0's version 7 and 0.3.x's version 8.

Stream versions 8 and 9 hold each picture as a PJA codec stream (versions 7, or
6 with 7 for a JPEG with JPEGs inside it), written by the PJA vendored
unmodified in `vendor/pja` (0.6.2 in PMPA 0.2.0, 0.6.3 in 0.3.0, 0.9.8 from
0.4.0: on 55 real covers 0.9.8 writes the very bytes 0.6.3 did, but for a
JPEG cut short it may write a stream 0.6.3 cannot read: hence version 9). PJA froze
those stream versions in its 0.9.0. A later PJA in `vendor/pja` that wrote
other streams would be a new PMPA stream version.

## The library and 7-Zip

Not there yet. When it comes (libpmpa, a 7-Zip codec in the same file, as
PJA's and PPA's), its methods take 7-Zip's experimental IDs `03 7F 20` to
`03 7F 2F`, the family's share for PMPA; 1.0.0 brings an ID of PMPA's own,
and archives written with the experimental ones keep opening.

## The zpaq-std codecs

Not there yet. Each one will have a name with a version while the format
changes (`pmpa1`, ...), never ending in z, o or 8; once published, a name
keeps its stream, what it takes and its ZPAQL decoder byte for byte,
forever.
