{ Layer 3: what an MPEG audio file is made of.

  The parser does not decode any audio: it finds the frames and the tags and
  cuts the whole file into consecutive segments,

      raw      bytes it does not recognise          kept as bytes
      frame    one MPEG audio frame (Layer I, II or III; MPEG-1, 2 or 2.5)
      id3v2    an ID3v2 tag, at the start or between frames
      id3v1    the 128-byte ID3v1 tag at the end
      ape      an APEv2 (or v1) tag at the end
      lyrics3  a Lyrics3 v2 tag at the end

  which tile the file exactly: rebuilding it is concatenating the segments
  again. That is what makes a parser's mistake harmless for exactness: a
  frame taken for raw bytes, or raw bytes taken for a frame, only costs
  compression, never a byte of the original.

  A frame is only believed when it is part of a run: MIN_RUN frames in a row,
  each starting where the one before ends, with the same version, layer and
  sample rate; or fewer that end exactly at the end of the audio or at an
  ID3v2 tag. A sync word in random bytes (one in 2048 positions) almost never
  starts such a run. A frame the file cuts short is raw bytes.

  Free format (bitrate index 0) has no length in its header: the length is
  the distance to the next header of the same stream, minus the padding, and
  every frame of the run then has that length plus its own padding. }
unit pmpampeg;

{$I pmpa.inc}
{$ifopt R-}{$fatal pmpampeg: range checks ($R+) are mandatory}{$endif}
{$ifopt Q-}{$fatal pmpampeg: overflow checks ($Q+) are mandatory}{$endif}

interface

uses SysUtils;

type
  TMpegVersion = (mvMpeg1, mvMpeg2, mvMpeg25);

  TMpegHeader = record
    raw: UInt32;
    version: TMpegVersion;
    layer: Integer;            { 1, 2 or 3 }
    hasCrc: Boolean;           { a 16-bit CRC follows the header }
    bitrateIndex: Integer;     { 0 = free format }
    rateIndex: Integer;
    padding: Integer;          { 0 or 1 slot }
    privateBit: Integer;
    mode: Integer;             { 0 stereo, 1 joint stereo, 2 dual channel, 3 mono }
    modeExt: Integer;
    copyright, original: Integer;
    emphasis: Integer;
    bitrate: Integer;          { kbit/s; 0 for free format }
    sampleRate: Integer;       { Hz }
    channels: Integer;
    samplesPerFrame: Integer;
    slotBytes: Integer;        { 4 for Layer I, else 1 }
    sideInfoBytes: Integer;    { Layer III only, else 0 }
    frameBytes: Integer;       { the whole frame; 0 for free format }
  end;

  { new kinds go at the end: the stream keeps their number }
  TSegmentKind = (skRaw, skFrame, skID3v2, skID3v1, skAPE, skLyrics3);

  TSegment = record
    kind: TSegmentKind;
    offset, length: Int64;
  end;

  TMpegScan = record
    segments: array of TSegment;
    count: Integer;
    frames: Int64;             { segments of kind skFrame }
    frameBytes: Int64;
    rawBytes: Int64;
    procedure Clear;
    procedure Add(kind: TSegmentKind; offset, len: Int64);
  end;

const
  MPEG_MIN_RUN = 3;
  { the longest free-format frame searched for: 640 kbit/s Layer III at
    8 kHz is 5760 bytes }
  MPEG_MAX_FREE = 8192;

{ false for a header with any reserved or forbidden field; frameBytes is 0
  for free format }
function DecodeHeader(h: UInt32; out hd: TMpegHeader): Boolean;
{ the big-endian 32 bits at pos; the caller checks that pos + 4 <= length }
function HeaderAt(const data: TBytes; pos: Int64): UInt32;
{ the length of a frame of hd's stream: hd.frameBytes, or, for free format,
  freeBytes (the length without padding) plus the padding }
function FrameLength(const hd: TMpegHeader; freeBytes: Integer): Integer;
{ two headers of the same stream: version, layer, sample rate and free
  format or not }
function SameStream(const a, b: TMpegHeader): Boolean;
{ the length of the ID3v2 tag at pos that fits before limit, or 0 }
function ID3v2Length(const data: TBytes; pos, limit: Int64): Int64;

procedure ScanMpeg(const data: TBytes; out S: TMpegScan);

function SegmentKindName(k: TSegmentKind): string;
function VersionName(v: TMpegVersion): string;

implementation

const
  BITRATES: array[0..4, 0..14] of Integer = (
    (0, 32, 64, 96, 128, 160, 192, 224, 256, 288, 320, 352, 384, 416, 448),  { MPEG-1 Layer I }
    (0, 32, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320, 384),     { MPEG-1 Layer II }
    (0, 32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320),      { MPEG-1 Layer III }
    (0, 32, 48, 56, 64, 80, 96, 112, 128, 144, 160, 176, 192, 224, 256),     { MPEG-2/2.5 Layer I }
    (0, 8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160));         { MPEG-2/2.5 Layer II, III }
  RATES: array[TMpegVersion, 0..2] of Integer = (
    (44100, 48000, 32000), (22050, 24000, 16000), (11025, 12000, 8000));

procedure TMpegScan.Clear;
begin
  segments := nil; count := 0; frames := 0; frameBytes := 0; rawBytes := 0;
end;

procedure TMpegScan.Add(kind: TSegmentKind; offset, len: Int64);
begin
  if len <= 0 then Exit;
  case kind of
    skFrame: begin Inc(frames); Inc(frameBytes, len); end;
    skRaw: Inc(rawBytes, len);
  end;
  { consecutive raw bytes are one segment }
  if (kind = skRaw) and (count > 0) and (segments[count - 1].kind = skRaw)
     and (segments[count - 1].offset + segments[count - 1].length = offset) then
  begin
    Inc(segments[count - 1].length, len);
    Exit;
  end;
  if count = Length(segments) then
    SetLength(segments, 2 * count + 16);
  segments[count].kind := kind;
  segments[count].offset := offset;
  segments[count].length := len;
  Inc(count);
end;

function DecodeHeader(h: UInt32; out hd: TMpegHeader): Boolean;
var v, row: Integer; slots: Int64;
begin
  hd := Default(TMpegHeader);
  Result := False;
  if (h shr 21) <> $7FF then Exit;
  v := (h shr 19) and 3;
  case v of
    0: hd.version := mvMpeg25;
    2: hd.version := mvMpeg2;
    3: hd.version := mvMpeg1;
  else Exit;                                       { 1 is reserved }
  end;
  case (h shr 17) and 3 of
    1: hd.layer := 3;
    2: hd.layer := 2;
    3: hd.layer := 1;
  else Exit;                                       { 0 is reserved }
  end;
  { MPEG-2.5 is Layer III only }
  if (hd.version = mvMpeg25) and (hd.layer <> 3) then Exit;
  hd.hasCrc := ((h shr 16) and 1) = 0;
  hd.bitrateIndex := (h shr 12) and 15;
  if hd.bitrateIndex = 15 then Exit;
  hd.rateIndex := (h shr 10) and 3;
  if hd.rateIndex = 3 then Exit;
  hd.padding := (h shr 9) and 1;
  hd.privateBit := (h shr 8) and 1;
  hd.mode := (h shr 6) and 3;
  hd.modeExt := (h shr 4) and 3;
  hd.copyright := (h shr 3) and 1;
  hd.original := (h shr 2) and 1;
  hd.emphasis := h and 3;
  if hd.emphasis = 2 then Exit;                    { reserved }
  hd.raw := h;

  if hd.version = mvMpeg1 then row := hd.layer - 1
  else if hd.layer = 1 then row := 3
  else row := 4;
  hd.bitrate := BITRATES[row, hd.bitrateIndex];
  hd.sampleRate := RATES[hd.version, hd.rateIndex];
  if hd.mode = 3 then hd.channels := 1 else hd.channels := 2;

  case hd.layer of
    1: begin hd.samplesPerFrame := 384; hd.slotBytes := 4; end;
    2: begin hd.samplesPerFrame := 1152; hd.slotBytes := 1; end;
  else
    hd.slotBytes := 1;
    if hd.version = mvMpeg1 then
    begin
      hd.samplesPerFrame := 1152;
      if hd.channels = 1 then hd.sideInfoBytes := 17 else hd.sideInfoBytes := 32;
    end
    else
    begin
      hd.samplesPerFrame := 576;
      if hd.channels = 1 then hd.sideInfoBytes := 9 else hd.sideInfoBytes := 17;
    end;
  end;

  if hd.bitrate > 0 then
  begin
    { slots per frame = samples / 8 * bitrate / rate, in slots of 32 bits
      for Layer I and of 8 bits for the others }
    slots := Int64(hd.samplesPerFrame) div 8 * hd.bitrate * 1000
             div hd.sampleRate div hd.slotBytes;
    hd.frameBytes := Integer((slots + hd.padding) * hd.slotBytes);
  end;
  Result := True;
end;

function HeaderAt(const data: TBytes; pos: Int64): UInt32;
begin
  Result := (UInt32(data[pos]) shl 24) or (UInt32(data[pos + 1]) shl 16)
            or (UInt32(data[pos + 2]) shl 8) or UInt32(data[pos + 3]);
end;

function FrameLength(const hd: TMpegHeader; freeBytes: Integer): Integer;
begin
  if hd.bitrateIndex <> 0 then Result := hd.frameBytes
  else Result := freeBytes + hd.padding * hd.slotBytes;
end;

function SameStream(const a, b: TMpegHeader): Boolean;
begin
  Result := (a.version = b.version) and (a.layer = b.layer)
            and (a.rateIndex = b.rateIndex)
            and ((a.bitrateIndex = 0) = (b.bitrateIndex = 0));
end;

{ the smallest a frame can be: its header, CRC and side information }
function MinFrame(const hd: TMpegHeader): Integer;
begin
  Result := 4 + hd.sideInfoBytes;
  if hd.hasCrc then Inc(Result, 2);
end;

function ID3v2Length(const data: TBytes; pos, limit: Int64): Int64;
var i: Integer; size: Int64;
begin
  Result := 0;
  if (pos < 0) or (pos + 10 > limit) then Exit;
  if (data[pos] <> Ord('I')) or (data[pos + 1] <> Ord('D')) or (data[pos + 2] <> Ord('3')) then Exit;
  if (data[pos + 3] < 2) or (data[pos + 3] > 4) or (data[pos + 4] = $FF) then Exit;
  size := 0;
  for i := 6 to 9 do
  begin
    if data[pos + i] >= $80 then Exit;             { a syncsafe integer }
    size := size shl 7 or data[pos + i];
  end;
  Inc(size, 10);
  { ID3v2.4's footer }
  if (data[pos + 3] = 4) and ((data[pos + 5] and $10) <> 0) then Inc(size, 10);
  if pos + size <= limit then Result := size;
end;

function BytesAre(const data: TBytes; pos: Int64; const s: string): Boolean;
var i: Integer;
begin
  Result := False;
  if (pos < 0) or (pos + Length(s) > Length(data)) then Exit;
  for i := 1 to Length(s) do
    if data[pos + i - 1] <> Ord(s[i]) then Exit;
  Result := True;
end;

function LE32(const data: TBytes; pos: Int64): Int64;
begin
  Result := Int64(data[pos]) or (Int64(data[pos + 1]) shl 8)
            or (Int64(data[pos + 2]) shl 16) or (Int64(data[pos + 3]) shl 24);
end;

{ The tags at the end of the file, last first, peeled off one by one: an
  ID3v1 tag, an APE tag and a Lyrics3 v2 tag, in any order they nest.
  Returns where the audio ends; tails holds the segments, last first. }
function PeelTail(const data: TBytes; start: Int64; var tails: array of TSegment;
  out n: Integer): Int64;
var e, total, size, flags: Int64; i: Integer; found, haveV1: Boolean;
begin
  e := Length(data); n := 0; haveV1 := False;
  repeat
    found := False;
    if n > High(tails) then Break;
    if (not haveV1) and (e - start >= 128) and BytesAre(data, e - 128, 'TAG') then
    begin
      tails[n].kind := skID3v1; tails[n].offset := e - 128; tails[n].length := 128;
      Inc(n); Dec(e, 128); haveV1 := True; found := True;
    end
    else if (e - start >= 32) and BytesAre(data, e - 32, 'APETAGEX') then
    begin
      size := LE32(data, e - 20);                  { the items and the footer }
      flags := LE32(data, e - 12);
      total := size;
      if (flags and $80000000) <> 0 then Inc(total, 32);   { a header too }
      { a tag that says it has a header must have one }
      if (size >= 32) and (total <= e - start)
         and ((total = size) or BytesAre(data, e - total, 'APETAGEX')) then
      begin
        tails[n].kind := skAPE; tails[n].offset := e - total; tails[n].length := total;
        Inc(n); Dec(e, total); found := True;
      end;
    end
    else if (e - start >= 15 + 11) and BytesAre(data, e - 9, 'LYRICS200') then
    begin
      size := 0;
      for i := 0 to 5 do
        if (data[e - 15 + i] >= Ord('0')) and (data[e - 15 + i] <= Ord('9')) then
          size := size * 10 + data[e - 15 + i] - Ord('0')
        else
          size := -1000000;
      total := size + 15;
      if (size >= 11) and (total <= e - start) and BytesAre(data, e - total, 'LYRICSBEGIN') then
      begin
        tails[n].kind := skLyrics3; tails[n].offset := e - total; tails[n].length := total;
        Inc(n); Dec(e, total); found := True;
      end;
    end;
  until not found;
  Result := e;
end;

{ Whether a run of frames starts at pos, with the free-format length (if
  any) given: MIN_RUN frames of the same stream, each where the one before
  ends, or fewer that end at the end of the audio or at an ID3v2 tag. }
function RunStarts(const data: TBytes; pos, audioEnd: Int64; freeBytes: Integer): Boolean;
var first, hd: TMpegHeader; cur: Int64; len, n: Integer;
begin
  Result := False;
  if (pos + 4 > audioEnd) or not DecodeHeader(HeaderAt(data, pos), first) then Exit;
  n := 0; cur := pos;
  while (cur + 4 <= audioEnd) and (n < MPEG_MIN_RUN) do
  begin
    if not DecodeHeader(HeaderAt(data, cur), hd) or not SameStream(first, hd) then Break;
    len := FrameLength(hd, freeBytes);
    if (len < MinFrame(hd)) or (cur + len > audioEnd) then Break;
    Inc(n); Inc(cur, len);
  end;
  Result := (n >= MPEG_MIN_RUN)
            or ((n >= 1) and ((cur = audioEnd) or (ID3v2Length(data, cur, audioEnd) > 0)));
end;

procedure ScanMpeg(const data: TBytes; out S: TMpegScan);
var
  tails: array[0..7] of TSegment;
  nTails, i, freeBytes, d, len: Integer;
  pos, audioEnd, rawFrom, q, idLen: Int64;
  hd, h2: TMpegHeader;
  found: Boolean;
begin
  S.Clear;
  audioEnd := PeelTail(data, 0, tails, nTails);
  pos := 0; rawFrom := 0;
  while pos < audioEnd do
  begin
    idLen := ID3v2Length(data, pos, audioEnd);
    if idLen > 0 then
    begin
      S.Add(skRaw, rawFrom, pos - rawFrom);
      S.Add(skID3v2, pos, idLen);
      Inc(pos, idLen); rawFrom := pos;
      Continue;
    end;
    found := False; freeBytes := 0;
    if (data[pos] = $FF) and (pos + 4 <= audioEnd) and DecodeHeader(HeaderAt(data, pos), hd) then
    begin
      if hd.bitrateIndex <> 0 then
        found := RunStarts(data, pos, audioEnd, 0)
      else
      begin
        { free format: each later header of the same stream gives a length
          to try, until one makes a run }
        q := pos + MinFrame(hd);
        while (not found) and (q + 4 <= audioEnd) and (q - pos <= MPEG_MAX_FREE) do
        begin
          if (data[q] = $FF) and DecodeHeader(HeaderAt(data, q), h2) and SameStream(hd, h2) then
          begin
            d := Integer(q - pos) - hd.padding * hd.slotBytes;
            if (d >= MinFrame(hd)) and (d mod hd.slotBytes = 0) then
            begin
              found := RunStarts(data, pos, audioEnd, d);
              if found then freeBytes := d;
            end;
          end;
          Inc(q);
        end;
      end;
    end;
    if not found then
    begin
      Inc(pos);
      Continue;
    end;
    S.Add(skRaw, rawFrom, pos - rawFrom);
    { the run is believed: its frames are taken as long as they are of the
      same stream and fit }
    while (pos + 4 <= audioEnd) and DecodeHeader(HeaderAt(data, pos), h2) and SameStream(hd, h2) do
    begin
      len := FrameLength(h2, freeBytes);
      if (len < MinFrame(h2)) or (pos + len > audioEnd) then Break;
      S.Add(skFrame, pos, len);
      Inc(pos, len);
    end;
    rawFrom := pos;
  end;
  S.Add(skRaw, rawFrom, audioEnd - rawFrom);
  for i := nTails - 1 downto 0 do
    S.Add(tails[i].kind, tails[i].offset, tails[i].length);
end;

function SegmentKindName(k: TSegmentKind): string;
begin
  case k of
    skRaw: Result := 'raw';
    skFrame: Result := 'frame';
    skID3v2: Result := 'id3v2';
    skID3v1: Result := 'id3v1';
    skAPE: Result := 'ape';
    skLyrics3: Result := 'lyrics3';
  else Result := '?';
  end;
end;

function VersionName(v: TMpegVersion): string;
begin
  case v of
    mvMpeg1: Result := 'MPEG-1';
    mvMpeg2: Result := 'MPEG-2';
  else Result := 'MPEG-2.5';
  end;
end;

end.
