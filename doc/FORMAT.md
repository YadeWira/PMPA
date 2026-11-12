# The .pmpa format

**A `.pmpa` is ONE compressed file**: an MPEG audio file (MP1, MP2 or MP3) as the codec stream
(`doc/CODEC.md`), together with the size, hash and extension of the
original. Dispatch is by magic, never by extension. The design is PJA's
`.pja` (version 4), from which `pas/pmpaformat.pas` comes (by way of PRA).

What the `.pmpa` adds over the bare codec stream, and why:

| | why |
|---|---|
| **BLAKE3-128 hash of the original** | A damaged stream can decode to **another valid file** without any error. The hash gives it away. |
| **declared original size** | Lets a bomb be rejected **before decoding**, and is the decoder's cap: the output cannot exceed it. |
| **the original's extension** | So that `song.MP3` comes back as `song.MP3`. Only the extension: the name is the `.pmpa`'s own. With a check of its own, since the hash covers the content only. |

The codec verifies its own stream when compressing, so what the hash
protects against is damage **after** writing: the disk, the network, a hand.

## Compatibility

As in the whole family: what a published release wrote is read by every
release after it. The formats (this container and the codec's stream) are
not frozen yet: a later release may write a new stream version, which the
releases before it refuse cleanly (`FutureVersion`). They freeze in a 0.9.x
release; `doc/STABILITY.md` has what is fixed and since when.

## 1. Layout

```
HEADER - 8 B
  magic        4 B   "PMPA"
  version      1 B   1
  flags        1 B   bit 0: stored (the payload is the original itself); the rest 0
  reserved     2 B   0

DESCRIPTOR - 24 B, then the extension field (5 to 20 B)
  orig_size    u64 LE   the original's length
  hash         16 B     BLAKE3-128 of the original
  ext_len      1 B      0 to 15
  ext          ext_len  the original's extension, without the dot, as it was
                        written: letters, digits, '_' and '-' only
  ext_check    4 B      the first 4 bytes of BLAKE3 of ext_len and ext

PAYLOAD - the rest: the codec stream, or with the stored flag the original
```

A file the codec does not make smaller, or whose stream does not come
back, is stored as it is: 37
bytes more than the original, plus the extension (at most 52 in all). Its
descriptor is stricter: `orig_size` has to be the payload's length exactly.

## 2. Order of operations

**On extract** (`pmpapack.Unpack`), and it is the order that gives the
safety:

1. validate the header: magic, version, known flags, reserved bytes zero;
2. validate the descriptor: `orig_size` between 1 and 65,536 times the
   payload's length (`ValidateDescriptor`), a payload of at least 6 bytes
   (the smallest codec stream), the extension's length, characters and
   check;
3. refuse if `orig_size` is above the user's cap (`--max-output`);
4. decode, with `orig_size` as the decoder's cap (`DecodeFile` refuses a
   stream that declares more, and every segment that would run past it);
5. check that the result is `orig_size` bytes long and has the hash;
6. only then write it under its name (`pmpafs.WriteVerified`).

**On compress** (`pmpapack.Pack`): the codec compresses and verifies; the
original is hashed; the writer validates the descriptor with the same
function the reader uses. What is written can be opened, and what is
refused on opening cannot be written.

A file with no MPEG audio frame is refused
(`not MPEG audio PMPA takes (no MPEG audio frames)`): PMPA is not a general
compressor, and does not store files it does not understand.

## 3. Hostile cases

Every row is in `pas/tests/test_format.pas` (219 checks).

| case | result |
|---|---|
| 0 to 7 bytes; a header without a whole descriptor or extension field | `ShortFile` |
| a wrong magic, garbage, zeros | `NotPmpa` |
| version 2 or higher | `FutureVersion(n)` |
| version 0 | `OldVersion(0)` |
| any flag but bit 0 | `UnknownFlag` |
| the stored flag on a codec stream | `BadOrigSize` |
| a reserved byte other than 0 | `ReservedNotZero` |
| `orig_size` 0, or above 2^63 - 1 | `BadOrigSize` |
| `orig_size` above 65,536 x the payload | `RatioExceeded`, by dividing: no overflow |
| a payload below 6 bytes | `PayloadOutOfRange` |
| any bit of the extension or its check; a bad character; more than 15 | `BadExtension`, in the writer and the reader |
| `Pack` given `../x` or 16 characters | leaves it out: the file is named by its content |
| one bit of the hash | `HashMismatch`, with what was decoded, for `--keep-corrupt` |
