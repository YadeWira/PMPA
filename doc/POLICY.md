# Limits and why

Every limit lives in `pas/pmpalimits.pas`. The codec applies them when
writing a stream, and the decoder applies the same ones before decoding:
a stream the writer makes is a stream the reader accepts.

| limit | value | why |
|---|---|---|
| `MIN_PAYLOAD` | 6 bytes | The smallest codec stream: the version byte, the original's length and the arithmetic coder's 4 closing bytes. No `.pmpa` payload of a codec stream can be smaller. |
| `MAX_EXPANSION_RATIO` | 65,536 | How many times its payload a declared original may be, checked before decoding. A last-resort cap, PJA's: not measured on MPEG audio yet. |
| `MAX_FREE_FRAME` | 64 KiB | A free-format frame's length as the stream gives it (16 bits). The parser looks for free-format frames up to 8 KiB (`MPEG_MAX_FREE`): 640 kbit/s Layer III at 8 kHz is 5,760 bytes. |
| `--max-output` | 256 MiB by default | The user's own cap on what `x` decodes. |
| input | 2 GiB | The command reads each file whole into memory. |

## What the parser promises

The parser cuts a file into segments that tile it (`pas/pmpampeg.pas`):
frames, tags and raw bytes; rebuilding the file is joining them again. So
the parser can be wrong about a file without losing a byte: the worst it can
do is make compression worse. A frame is believed only in a run (3 frames in
a row of the same stream, or fewer that end the audio), so a sync word in
other bytes stays raw.

The decoder trusts nothing in the stream: a header that is not a valid MPEG
header, a kind that does not exist, or a segment that would run past the
declared length is a damaged stream.
