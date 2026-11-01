{ pmpacodec: every sample is encoded, and the stream must come back (the
  encoder checks it; here it is decoded again on its own and compared), with
  the same bytes in the checked and the fast build (the last line, "streams",
  is a BLAKE3 digest run_tests.sh compares between them). Damaged
  streams must fail or decode to something else, never crash.

    test_codec <dir>... }
program test_codec;
{$I ../pmpa.inc}
uses SysUtils, Classes, pmpablake3, pmpacodec;

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
  files: TStringList; sr: TSearchRec; i, k, bit, nOk, nRefused: Integer;
  d, s, back, bad: TBytes; st: TEncodeStatus; ds: TDecodeStatus;
  inBytes, outBytes: Int64; digest: TBlake3; h: THash16; hex: string;
  seed: Cardinal; survived: Boolean;
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
  SetLength(bad, 10); FillChar(bad[0], 10, 0); bad[0] := 2;
  Check(DecodeFile(bad, 100, back) = dsFutureVersion, 'version 2');
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
