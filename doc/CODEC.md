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
