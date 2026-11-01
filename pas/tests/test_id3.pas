{ pmpaid3 on tests/covers (scripts/mksamples.py): the JPEG pictures each
  tag holds, how their bytes are in the file, and that the unsynchronised
  form each one's mode gives is the file's bytes; then the codec: every
  file comes back, and version 8 (the pictures through PJA) is smaller than
  version 7 wherever there is a picture PJA takes.

    test_id3 <tests/covers> }
program test_id3;
{$I ../pmpa.inc}
uses {$ifdef UNIX} cthreads, {$endif} SysUtils, Classes, pmpampeg, pmpaid3, pmpacodec, pmpac;

const
  { file, pictures found, their modes (one digit each) }
  COVERS: array[0..11, 0..2] of string = (
    ('v22_pic.mp3', '1', '0'),
    ('v23_compressed_frame.mp3', '0', ''),
    ('v23_extended_header.mp3', '1', '0'),
    ('v23_jpeg_cut_short.mp3', '1', '0'),
    ('v23_jpeg.mp3', '1', '0'),
    ('v23_jpg_mime_utf16.mp3', '1', '0'),
    ('v23_png.mp3', '0', ''),
    ('v23_progressive.mp3', '1', '0'),
    ('v23_tag_unsync_every_ff.mp3', '1', '2'),
    ('v23_tag_unsync.mp3', '1', '1'),
    ('v23_two_pictures.mp3', '2', '00'),
    ('v24_frame_unsync.mp3', '1', '1'));

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

function Same(const a, b: TBytes): Boolean;
begin
  Result := (Length(a) = Length(b)) and ((Length(a) = 0) or CompareMem(@a[0], @b[0], Length(a)));
end;

var
  i, k, j: Integer; d, s7, s8, back, raw: TBytes; S: TMpegScan; p: TPictures;
  modes: string; ok: Boolean;
begin
  cells := 0; failures := 0;
  if ParamCount < 1 then begin Writeln('usage: test_id3 <tests/covers>'); Halt(2); end;
  Writeln('pictures');
  for i := 0 to High(COVERS) do
  begin
    d := LoadFile(IncludeTrailingPathDelimiter(ParamStr(1)) + COVERS[i, 0]);
    ScanMpeg(d, S);
    p := nil;
    for k := 0 to S.count - 1 do
      if S.segments[k].kind = skID3v2 then p := FindPictures(d, S.segments[k].offset, S.segments[k].length);
    modes := '';
    ok := True;
    for k := 0 to High(p) do
    begin
      modes := modes + IntToStr(p[k].mode);
      { a JPEG, and its raw form the file's bytes }
      if (Length(p[k].jpeg) < 3) or (p[k].jpeg[0] <> $FF) or (p[k].jpeg[1] <> $D8) then ok := False;
      raw := Unsync(p[k].jpeg, p[k].mode);
      if Length(raw) <> p[k].rawLen then ok := False
      else for j := 0 to High(raw) do if raw[j] <> d[p[k].rawStart + j] then ok := False;
    end;
    Check(ok and (IntToStr(Length(p)) = COVERS[i, 1]) and (modes = COVERS[i, 2]),
      Format('%s: %d pictures, modes %s', [COVERS[i, 0], Length(p), modes]));
  end;

  Writeln('the codec');
  for i := 0 to High(COVERS) do
  begin
    d := LoadFile(IncludeTrailingPathDelimiter(ParamStr(1)) + COVERS[i, 0]);
    s7 := EncodeAs(d, 7);
    ok := (EncodeFile(d, s8) = esOk) and (DecodeFile(s8, Length(d), back) = dsOk) and Same(d, back);
    if COVERS[i, 1] <> '0' then ok := ok and (Length(s8) < Length(s7))
    else ok := ok and (Length(s8) <= Length(s7) + 1);
    Check(ok, Format('%s back; version 7 %d B, version 8 %d B', [COVERS[i, 0], Length(s7), Length(s8)]));
  end;
  { a damaged picture stream: an error or other bytes, never a crash }
  d := LoadFile(IncludeTrailingPathDelimiter(ParamStr(1)) + 'v23_jpeg.mp3');
  EncodeFile(d, s8);
  ok := True;
  for k := 0 to 199 do
  begin
    back := Copy(s8, 0, Length(s8));
    j := 20 + (k * 7919) mod (Length(back) - 20);
    back[j] := back[j] xor (1 shl (k mod 8));
    try
      DecodeFile(back, Length(d), raw);
    except
      ok := False;
    end;
  end;
  Check(ok, '200 bits flipped in a stream with a picture: no crash');

  Writeln(cells, ' cells, ', failures, ' failures');
  if (failures > 0) or (cells < 25) then Halt(1);
end.
