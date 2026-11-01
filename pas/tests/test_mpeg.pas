{ pmpampeg: the header against the standard's tables, every possible header,
  runs built in memory, and the samples: each one cut into segments that
  tile it exactly, the clean ones into frames only, and the odd ones as
  tests/odd's construction (scripts/mksamples.py) says they must be.

    test_mpeg <tests dir> }
program test_mpeg;
{$I ../pmpa.inc}
uses SysUtils, Classes, pmpampeg;

var cells, failures: Integer;

procedure Check(ok: Boolean; const what: string);
begin
  Inc(cells);
  if ok then Writeln('  ', what:66, '  ok')
  else begin Inc(failures); Writeln('  ', what:66, '  FAIL'); end;
end;

function LoadFile(const name: string): TBytes;
var f: TFileStream;
begin
  Result := nil;
  f := TFileStream.Create(name, fmOpenRead or fmShareDenyNone);
  try
    SetLength(Result, f.Size);
    if f.Size > 0 then f.ReadBuffer(Result[0], f.Size);
  finally
    f.Free;
  end;
end;

{ the header's frame length, -1 if it is not valid }
function Len(h: UInt32): Integer;
var hd: TMpegHeader;
begin
  if DecodeHeader(h, hd) then Result := hd.frameBytes else Result := -1;
end;

procedure TestHeaders;
var hd: TMpegHeader; h: UInt32; valid, tooShort: Int64; minLen: Integer;
begin
  Writeln('headers');
  Check(Len($FFFB9064) = 417, 'MPEG-1 L3 128k 44.1 kHz: 417 B');
  Check(Len($FFFB9264) = 418, 'the same with padding: 418 B');
  Check(Len($FFFDA404) = 576, 'MPEG-1 L2 192k 48 kHz: 576 B');
  Check(Len($FFFFC808) = 576, 'MPEG-1 L1 384k 32 kHz: 576 B');
  Check(Len($FFFFCA08) = 580, 'the same with padding: one 4-byte slot more');
  Check(Len($FFF38004) = 208, 'MPEG-2 L3 64k 22.05 kHz: 208 B');
  Check(Len($FFE31804) = 72, 'MPEG-2.5 L3 8k 8 kHz: 72 B');
  Check(Len($FFF71804) = 96, 'MPEG-2 L1 32k 16 kHz: 96 B');
  DecodeHeader($FFFB9064, hd);
  Check((hd.ver = mvMpeg1) and (hd.layer = 3) and not hd.hasCrc and (hd.bitrate = 128)
        and (hd.sampleRate = 44100) and (hd.channels = 2) and (hd.mode = 1)
        and (hd.samplesPerFrame = 1152) and (hd.sideInfoBytes = 32), 'every field of FFFB9064');
  DecodeHeader($FFFA90C4, hd);
  Check(hd.hasCrc and (hd.channels = 1) and (hd.sideInfoBytes = 17), 'MPEG-1 L3 mono, CRC: 17 B of side info');
  DecodeHeader($FFF380C4, hd);
  Check((hd.sideInfoBytes = 9) and (hd.samplesPerFrame = 576), 'MPEG-2 L3 mono: 9 B of side info, 576 samples');
  DecodeHeader($FFFD04C4, hd);
  Check((hd.bitrate = 0) and (hd.frameBytes = 0) and (FrameLength(hd, 600) = 600), 'free format: the length is given');
  DecodeHeader($FFFD06C4, hd);
  Check(FrameLength(hd, 600) = 601, 'free format with padding');
  DecodeHeader($FFFF0608, hd);
  Check(FrameLength(hd, 600) = 604, 'free format Layer I: the padding is 4 bytes');
  Check(Len($FFEB9064) = -1, 'version 01 is reserved');
  Check(Len($FFF99064) = -1, 'layer 00 is reserved');
  Check(Len($FFFBF064) = -1, 'bitrate index 15 is forbidden');
  Check(Len($FFFB9C64) = -1, 'sample rate index 3 is reserved');
  Check(Len($FFFB9066) = -1, 'emphasis 2 is reserved');
  Check(Len($FFE51804) = -1, 'MPEG-2.5 has no Layer II');
  Check(Len($FFDB9064) = -1, 'no sync word');

  { every header with a sync word: 7 version/layer pairs x 2 x 15 bitrates
    x 3 rates x 3 emphases x 256 (padding, private, mode, extension,
    copyright, original) = 483,840 are valid, and none of the
    fixed-length ones is shorter than its header, CRC and side info }
  valid := 0; tooShort := 0;
  for h := 0 to $1FFFFF do
    if DecodeHeader(UInt32($FFE00000) or UInt32(h), hd) then
    begin
      Inc(valid);
      minLen := 4 + hd.sideInfoBytes;
      if hd.hasCrc then Inc(minLen, 2);
      if (hd.bitrate > 0) and (hd.frameBytes < minLen) then Inc(tooShort);
    end;
  Check(valid = 483840, 'valid headers: ' + IntToStr(valid));
  Check(tooShort = 0, 'every fixed length holds its header and side info');
end;

{ n frames of the header h with zero bodies, then extra bytes }
function Frames(h: UInt32; n, extra: Integer; fill: Byte): TBytes;
var i, j, l: Integer;
begin
  Result := nil;
  l := Len(h);
  SetLength(Result, n * l + extra);
  FillChar(Result[0], Length(Result), 0);
  for i := 0 to n - 1 do
    for j := 0 to 3 do
      Result[i * l + j] := (h shr (24 - 8 * j)) and $FF;
  for i := n * l to High(Result) do Result[i] := fill;
end;

function Describe(const S: TMpegScan): string;
var i: Integer;
begin
  Result := Format('%d frames, raw %d', [S.frames, S.rawBytes]);
  for i := 0 to S.count - 1 do
    if not (S.segments[i].kind in [skRaw, skFrame]) then
      Result := Result + ' ' + SegmentKindName(S.segments[i].kind);
end;

{ the segments are in order, each where the one before ends, and cover the
  file; the frames are frames }
function Tiles(const data: TBytes; const S: TMpegScan): Boolean;
var i: Integer; pos: Int64; hd: TMpegHeader;
begin
  Result := False;
  pos := 0;
  for i := 0 to S.count - 1 do
  begin
    if (S.segments[i].offset <> pos) or (S.segments[i].length <= 0) then Exit;
    if S.segments[i].kind = skFrame then
      if not DecodeHeader(HeaderAt(data, pos), hd) then Exit;
    Inc(pos, S.segments[i].length);
  end;
  Result := pos = Length(data);
end;

procedure TestRuns;
var S: TMpegScan; d: TBytes;
begin
  Writeln('runs');
  ScanMpeg(nil, S);
  Check(S.count = 0, 'nothing: no segments');
  d := Frames($FFFB9064, 5, 0, 0); ScanMpeg(d, S);
  Check(Tiles(d, S) and (S.frames = 5) and (S.rawBytes = 0), '5 frames');
  d := Frames($FFFB9064, 2, 0, 0); ScanMpeg(d, S);
  Check(Tiles(d, S) and (S.frames = 2) and (S.rawBytes = 0), '2 frames that end the file');
  d := Frames($FFFB9064, 2, 100, $55); ScanMpeg(d, S);
  Check(Tiles(d, S) and (S.frames = 0) and (S.rawBytes = Length(d)), '2 frames and then bytes: not believed');
  d := Frames($FFFB9064, 3, 100, $55); ScanMpeg(d, S);
  Check(Tiles(d, S) and (S.frames = 3) and (S.rawBytes = 100), '3 frames and then bytes: believed');
  d := Frames($FFFB9064, 4, 100, 0); d[2 * 417 + 1] := 0; ScanMpeg(d, S);
  Check(Tiles(d, S) and (S.frames = 0), 'a broken third header: 2 + 2 frames, neither believed');
  d := Frames($FFFB9064, 8, 0, 0); d[3 * 417 + 1] := 0; ScanMpeg(d, S);
  Check(Tiles(d, S) and (S.frames = 7) and (S.rawBytes = 417), 'a broken fourth header of 8: that frame is raw');
  d := Frames($FFFB9064, 6, 0, 0); SetLength(d, Length(d) - 10); ScanMpeg(d, S);
  Check(Tiles(d, S) and (S.frames = 5) and (S.rawBytes = 407), 'the last frame cut short is raw');
end;

procedure TestSamples(const dir: string);
const
  ODD: array[0..13, 0..1] of string = (
    ('ape_lyrics_id3v1.mp3', '41 frames, raw 0 lyrics3 ape id3v1'),
    ('ape_no_header.mp3', '41 frames, raw 0 ape'),
    ('concat_44k_22k.mp3', '83 frames, raw 0'),
    ('concat_with_id3v2.mp3', '83 frames, raw 0 id3v2'),
    ('cut_short.mp3', '40 frames, raw 218'),
    ('empty_ish.mp3', '0 frames, raw 2'),
    ('id3v24_footer_padding.mp3', '41 frames, raw 64 id3v2'),
    ('id3v2_id3v1.mp3', '41 frames, raw 0 id3v2 id3v1'),
    ('junk_after.mp3', '41 frames, raw 1000'),
    ('junk_before.mp3', '41 frames, raw 1000'),
    ('junk_between.mp3', '40 frames, raw 1418'),
    ('not_mpeg.bin', '0 frames, raw 20000'),
    ('one_frame.mp3', '1 frames, raw 0'),
    ('two_id3v2.mp3', '41 frames, raw 0 id3v2 id3v2'));
var
  sub: string; sr: TSearchRec; data: TBytes; S: TMpegScan; i, n, nClean: Integer;
  ok, tagsOk: Boolean; found: string;
begin
  Writeln('samples');
  nClean := 0;
  for sub in ['mp1', 'mp2', 'mp3'] do
    if FindFirst(IncludeTrailingPathDelimiter(dir) + sub + PathDelim + '*', faAnyFile, sr) = 0 then
    begin
      repeat
        if (sr.Attr and faDirectory) <> 0 then Continue;
        data := LoadFile(IncludeTrailingPathDelimiter(dir) + sub + PathDelim + sr.Name);
        ScanMpeg(data, S);
        { the only tag an encoder writes here is an ID3v2 at the start }
        tagsOk := True;
        for i := 0 to S.count - 1 do
          if not ((S.segments[i].kind = skFrame) or ((S.segments[i].kind = skID3v2) and (i = 0))) then
            tagsOk := False;
        ok := Tiles(data, S) and (S.frames > 0) and (S.rawBytes = 0) and tagsOk;
        Check(ok, sub + '/' + sr.Name + ': ' + Describe(S));
        Inc(nClean);
      until FindNext(sr) <> 0;
      FindClose(sr);
    end;
  Check(nClean >= 29, 'clean samples: ' + IntToStr(nClean));

  n := 0;
  for i := 0 to High(ODD) do
  begin
    if not FileExists(IncludeTrailingPathDelimiter(dir) + 'odd' + PathDelim + ODD[i, 0]) then
    begin
      Check(False, 'odd/' + ODD[i, 0] + ' is missing');
      Continue;
    end;
    data := LoadFile(IncludeTrailingPathDelimiter(dir) + 'odd' + PathDelim + ODD[i, 0]);
    ScanMpeg(data, S);
    found := Describe(S);
    Check(Tiles(data, S) and (found = ODD[i, 1]), 'odd/' + ODD[i, 0] + ': ' + found);
    Inc(n);
  end;
  Check(n = Length(ODD), 'odd samples: ' + IntToStr(n));
end;

begin
  cells := 0; failures := 0;
  if ParamCount < 1 then
  begin
    Writeln('usage: test_mpeg <tests dir>');
    Halt(2);
  end;
  TestHeaders;
  TestRuns;
  TestSamples(ParamStr(1));
  Writeln(cells, ' cells, ', failures, ' failures');
  if (failures > 0) or (cells < 70) then Halt(1);
end.
