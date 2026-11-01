{ pmpacodec: every sample is encoded, and the stream must come back (the
  encoder checks it; here it is decoded again on its own and compared), with
  the same bytes in the checked and the fast build (the last line, "streams",
  is a BLAKE3 digest run_tests.sh compares between them). Damaged
  streams must fail or decode to something else, never crash.

    test_codec <dir>... }
program test_codec;
{$I ../pmpa.inc}
uses {$ifdef UNIX} cthreads, {$endif} SysUtils, Classes, pmpablake3, pmpampeg, pmpal3, pmpal12, pmpacodec, pmpac;

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
  files: TStringList; sr: TSearchRec; i, k, n, bit, nOk, nRefused: Integer;
  d, s, back, bad: TBytes; st: TEncodeStatus; ds: TDecodeStatus;
  inBytes, outBytes: Int64; digest: TBlake3; h: THash16; hex: string;
  seed: Cardinal; survived, ok, placed: Boolean; scan: TMpegScan; hd: TMpegHeader;
  fr: TL12Frame; q: TQClass; bw: TBitWriter;
begin
  cells := 0; failures := 0;
  files := TStringList.Create;
  for i := 1 to ParamCount do
    if FindFirst(IncludeTrailingPathDelimiter(ParamStr(i)) + '*', faAnyFile, sr) = 0 then
    begin
      repeat
        if (sr.Attr and faDirectory) = 0 then
          files.Add(IncludeTrailingPathDelimiter(ParamStr(i)) + sr.Name);
      until FindNext(sr) <> 0;
      FindClose(sr);
    end;
  files.Sort;

  { this program has the C (pmpac): it has to be in use, unless PMPA_NOC=1
    asks for the Pascal (or the comparison of the two would compare the
    Pascal with itself) }
  Check(CInUse = (GetEnvironmentVariable('PMPA_NOC') <> '1'), 'the C in use, unless PMPA_NOC=1');
  Writeln('round trips');
  digest.Init;
  nOk := 0; nRefused := 0; inBytes := 0; outBytes := 0;
  for i := 0 to files.Count - 1 do
  begin
    d := LoadFile(files[i]);
    st := EncodeFile(d, s);
    if st = esNotMpeg then
    begin
      Inc(nRefused);
      Check(Pos('not_mpeg', files[i]) + Pos('empty_ish', files[i]) > 0,
        ExtractFileName(files[i]) + ': refused, not MPEG');
      Continue;
    end;
    ds := DecodeFile(s, Length(d), back);
    Check((st = esOk) and (ds = dsOk) and Same(d, back),
      Format('%s: %d -> %d (%.2f%%)', [ExtractFileName(files[i]), Length(d), Length(s), 100 * Length(s) / Length(d)]));
    if st = esOk then
    begin
      Inc(nOk); Inc(inBytes, Length(d)); Inc(outBytes, Length(s));
      digest.Update(s[0], Length(s));
    end;
  end;
  Check(nOk >= 41, 'streams that came back: ' + IntToStr(nOk));

  Writeln('bands');
  { small bands, so that the samples are cut into many: each file comes
    back, the stream is the same whatever the threads, and it decodes the
    same on 1 thread and on 4 }
  BandBytes := 4096;
  survived := True; n := 0;
  for i := 0 to files.Count - 1 do
  begin
    d := LoadFile(files[i]);
    if EncodeFile(d, s, 1) <> esOk then Continue;
    Inc(n);
    if (EncodeFile(d, bad, 4) <> esOk) or not Same(s, bad) then survived := False;
    if (DecodeFile(s, Length(d), back, 1) <> dsOk) or not Same(d, back) then survived := False;
    if (DecodeFile(s, Length(d), back, 4) <> dsOk) or not Same(d, back) then survived := False;
  end;
  Check(survived and (n >= 41), Format('bands of 4 KB: %d files, the same on 1 and 4 threads', [n]));
  BandBytes := 1 shl 21;

  Writeln('verified on a second thread as it is written');
  survived := True; n := 0;
  for i := 0 to files.Count - 1 do
  begin
    d := LoadFile(files[i]);
    if EncodeFile(d, s) <> esOk then Continue;
    if (EncodeFile(d, back, 2) <> esOk) or not Same(s, back) then survived := False;
    Inc(n);
  end;
  Check(survived and (n >= 41), Format('the same stream as verified after: %d files', [n]));

  Writeln('what an encoder can get wrong comes back too');
  { a CRC that is not the one the frame gives: the 6th frame's of a
    CRC-protected Layer III file (160 kbit/s, 522 or 523 bytes a frame) }
  for i := 0 to files.Count - 1 do
    if ExtractFileName(files[i]) = 'l3_cbr160_stereo_crc.mp3' then
    begin
      d := LoadFile(files[i]);
      ScanMpeg(d, scan);
      Check((scan.count > 6) and (scan.segments[5].kind = skFrame) and ((d[scan.segments[5].offset + 1] and 1) = 0),
        'its 6th segment is a frame with a CRC');
      d[scan.segments[5].offset + 5] := d[scan.segments[5].offset + 5] xor $5A;
      st := EncodeFile(d, s);
      Check((st = esOk) and (DecodeFile(s, Length(d), back) = dsOk) and Same(d, back),
        'a wrong CRC in a Layer III frame');
    end;

  { a Layer II code word above what its levels allow (real encoders write
    a few): the 10th frame of a Layer II sample gets one, written by
    pmpal12 itself, and the file must come back }
  for i := 0 to files.Count - 1 do
    if ExtractFileName(files[i]) = 'l2_192k_48k_stereo.mp2' then
    begin
      d := LoadFile(files[i]);
      ScanMpeg(d, scan);
      DecodeHeader(HeaderAt(d, scan.segments[9].offset), hd);
      ok := ParseL12(d, scan.segments[9].offset, scan.segments[9].length, hd, fr);
      placed := False;
      if ok then
        for k := 0 to fr.sblimit - 1 do
          if not placed and (fr.alloc[0, k] <> 0) and (QClass(fr.table, k, fr.alloc[0, k]).levels > 0) then
          begin
            q := QClass(fr.table, k, fr.alloc[0, k]);
            fr.smp[0, k, 3] := q.levels * q.levels * q.levels;   { the first word above }
            fr.smp[0, k, 4] := -1; fr.smp[0, k, 5] := -1;
            bw.Init(scan.segments[9].length);
            WriteL12(fr, bw);
            for n := 0 to Integer(bw.pos - 1) shr 3 do d[scan.segments[9].offset + 4 + n] := bw.d[n];
            placed := True;
          end;
      Check(placed, 'a grouped code word above its levels, placed');
      ok := ParseL12(d, scan.segments[9].offset, scan.segments[9].length, hd, fr) and (fr.oddCodes = 1);
      st := EncodeFile(d, s);
      Check(ok and (st = esOk) and (DecodeFile(s, Length(d), back) = dsOk) and Same(d, back),
        '  it is read as one, and the file comes back');
    end;

  Writeln('earlier versions are still read');
  for k := 1 to STREAM_VERSION - 1 do
  begin
    survived := True; n := 0;
    for i := 0 to files.Count - 1 do
    begin
      d := LoadFile(files[i]);
      s := EncodeAs(d, k);
      if s = nil then Continue;
      Inc(n);
      if (s[0] <> k) or (DecodeFile(s, Length(d), back) <> dsOk) or not Same(d, back) then survived := False;
    end;
    Check(survived and (n >= 41), Format('version %d: %d files back', [k, n]));
  end;
  Check(nRefused = 2, 'files refused: ' + IntToStr(nRefused));

  Writeln('damaged streams');
  { one bit flipped at a time, in a few streams: dsOk with other bytes, or
    an error; never an exception }
  seed := 12345; survived := True;
  for i := 0 to files.Count - 1 do
  begin
    if i mod 7 <> 0 then Continue;
    d := LoadFile(files[i]);
    if EncodeFile(d, s) <> esOk then Continue;
    for k := 0 to 49 do
    begin
      bad := Copy(s, 0, Length(s));
      seed := Cardinal((QWord(seed) * 1103515245 + 12345) and $FFFFFFFF);
      bit := Integer((seed shr 8) mod Cardinal(Length(bad) * 8));
      bad[bit div 8] := bad[bit div 8] xor (1 shl (bit mod 8));
      try
        ds := DecodeFile(bad, Length(d), back);
        if (ds = dsOk) and (Length(back) > Length(d)) then survived := False;
      except
        survived := False;
      end;
    end;
  end;
  Check(survived, 'one flipped bit: an error or other bytes, never a crash');
  bad := nil;
  Check(DecodeFile(bad, 100, back) = dsEmpty, 'an empty stream');
  SetLength(bad, 10); FillChar(bad[0], 10, 0); bad[0] := STREAM_VERSION + 1;
  Check(DecodeFile(bad, 100, back) = dsFutureVersion, 'a later version');
  bad[0] := 1; bad[1] := 200; bad[2] := 1;
  Check(DecodeFile(bad, 100, back) = dsTooBig, 'a length above the cap');
  bad[1] := 0;
  Check(DecodeFile(bad, 100, back) = dsBadStream, 'a length of 0');

  h := digest.Final;
  hex := '';
  for k := 0 to 15 do hex := hex + LowerCase(IntToHex(h[k], 2));
  Writeln(cells, ' cells, ', failures, ' failures');
  Writeln(Format('total %d -> %d (%.2f%%)', [inBytes, outBytes, 100 * outBytes / inBytes]));
  Writeln('streams ', nOk, ' ', hex);
  files.Free;
  if (failures > 0) or (cells < 40) then Halt(1);
end.
