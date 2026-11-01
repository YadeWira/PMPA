{ pmpal12 on every Layer I and II frame of the files given: the fields read
  and written back give the same bits; a frame's CRC is the one computed
  over its header, allocation and scfsi.

    test_l12 [-q] <file or dir>... }
program test_l12;
{$I ../pmpa.inc}
uses SysUtils, Classes, Math, pmpampeg, pmpal3, pmpal12;

var
  cells, failures: Integer; quiet: Boolean;
  frames, parsed, back, crcs, crcOk, ancBits, fieldBits: Int64;
  notes: TStringList;
  whys: array[0..3] of Int64;

procedure Check(ok: Boolean; const what: string);
begin
  Inc(cells);
  if ok then begin if not quiet then Writeln('  ', what:66, '  ok'); end
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

procedure OneFile(const name: string);
var
  d: TBytes; S: TMpegScan; i, j, first, n, nParsed: Integer; hd: TMpegHeader; f: TL12Frame;
  w: TBitWriter; pos: Int64; same: Boolean;
begin
  d := LoadFile(name);
  ScanMpeg(d, S);
  n := 0; nParsed := 0;
  for i := 0 to S.count - 1 do
  begin
    if S.segments[i].kind <> skFrame then Continue;
    pos := S.segments[i].offset;
    if not DecodeHeader(HeaderAt(d, pos), hd) or (hd.layer = 3) then Continue;
    Inc(frames); Inc(n);
    if not ParseL12(d, pos, S.segments[i].length, hd, f) then
    begin
      Inc(whys[f.why]);
      if notes.Count < 10 then notes.Add(Format('%s frame %d: not parsed (%d)', [ExtractFileName(name), n, f.why]));
      Continue;
    end;
    Inc(parsed); Inc(nParsed);
    first := 4 + 2 * Ord(hd.hasCrc);
    Inc(fieldBits, f.endBit - first * 8);
    Inc(ancBits, S.segments[i].length * 8 - f.endBit);
    w.Init(S.segments[i].length);
    WriteL12(f, w);
    same := w.pos = f.endBit - first * 8;
    if same then
      for j := 0 to Integer(w.pos) - 1 do
        if ((w.d[j shr 3] shr (7 - (j and 7))) and 1)
           <> ((d[pos + first + (j shr 3)] shr (7 - (j and 7))) and 1) then same := False;
    if same then Inc(back);
    if hd.hasCrc then
    begin
      Inc(crcs);
      if MpegCrc(HeaderAt(d, pos), d, pos + 6, f.crcBits) = (d[pos + 4] shl 8) or d[pos + 5] then Inc(crcOk)
      else if notes.Count < 10 then notes.Add(Format('%s frame %d: CRC differs', [ExtractFileName(name), n]));
    end;
  end;
  if (n > 0) and not quiet then
    Writeln(Format('    %s: %d of %d frames parsed', [ExtractFileName(name), nParsed, n]));
end;

var files: TStringList; i: Integer; sr: TSearchRec; a: string;
begin
  cells := 0; failures := 0; quiet := False;
  frames := 0; parsed := 0; back := 0; crcs := 0; crcOk := 0; ancBits := 0; fieldBits := 0;
  notes := TStringList.Create;
  files := TStringList.Create;
  for i := 1 to ParamCount do
  begin
    a := ParamStr(i);
    if a = '-q' then begin quiet := True; Continue; end;
    if DirectoryExists(a) then
    begin
      if FindFirst(IncludeTrailingPathDelimiter(a) + '*', faAnyFile, sr) = 0 then
      begin
        repeat
          if (sr.Attr and faDirectory) = 0 then files.Add(IncludeTrailingPathDelimiter(a) + sr.Name);
        until FindNext(sr) <> 0;
        FindClose(sr);
      end;
    end
    else files.Add(a);
  end;
  files.Sort;
  for i := 0 to files.Count - 1 do OneFile(files[i]);
  for i := 0 to notes.Count - 1 do Writeln('    ', notes[i]);
  Writeln(Format('not parsed: allocation %d, grouped code word %d, frame too short %d', [whys[1], whys[2], whys[3]]));
  Check(parsed = back, Format('parsed frames written back give their bits: %d of %d', [back, parsed]));
  Check(crcs = crcOk, Format('CRC of %d protected frames: %d match', [crcs, crcOk]));
  Writeln(Format('Layer I/II frames %d, parsed %d (%.2f%%); fields %d bits, ancillary %d bits',
    [frames, parsed, 100 * parsed / Max(1, frames), fieldBits, ancBits]));
  Writeln(cells, ' cells, ', failures, ' failures');
  if failures > 0 then Halt(1);
end.
