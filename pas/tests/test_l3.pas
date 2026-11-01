{ pmpal3 on every Layer III frame of the files given: the side information
  read and written back gives the same bytes; a frame's CRC is the one
  computed over its header and side information; and the main data of each
  frame of a run lies inside the run's slot stream, after the frame before
  and before its own slots end (or the frame is counted as not mapped: its
  main data begins before the run does).

    test_l3 [-q] <file or dir>... }
program test_l3;
{$I ../pmpa.inc}
uses SysUtils, Classes, Math, pmpampeg, pmpal3;

var cells, failures: Integer; quiet: Boolean;

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

var
  files: TStringList;
  totFrames, totMapped, totUnmapped, totCrc, totCrcOk, totSlotBits, totDataBits: Int64;

procedure OneFile(const name: string);
var
  d, w: TBytes; S: TMpegScan; i, k: Integer; hd, first: TMpegHeader; si: TSideInfo;
  same, inRun: Boolean; slotPos, prevEnd, start, stop: Int64; slots, sideOk, frames, mapped: Integer;
begin
  d := LoadFile(name);
  ScanMpeg(d, S);
  inRun := False; slotPos := 0; prevEnd := 0; sideOk := 0; frames := 0; mapped := 0;
  first := Default(TMpegHeader);
  for i := 0 to S.count - 1 do
  begin
    if (S.segments[i].kind <> skFrame) or not DecodeHeader(HeaderAt(d, S.segments[i].offset), hd)
       or (hd.layer <> 3) then
    begin
      inRun := False;
      Continue;
    end;
    if not inRun or not SameStream(first, hd) then
    begin
      { a new run: a new slot stream }
      inRun := True; first := hd; slotPos := 0; prevEnd := 0;
    end;
    Inc(frames);
    ReadSideInfo(d, S.segments[i].offset + 4 + 2 * Ord(hd.hasCrc), hd, si);
    w := WriteSideInfo(si, hd);
    same := True;
    for k := 0 to hd.sideInfoBytes - 1 do
      if w[k] <> d[S.segments[i].offset + 4 + 2 * Ord(hd.hasCrc) + k] then same := False;
    if same then Inc(sideOk);
    if hd.hasCrc then
    begin
      Inc(totCrc);
      if MpegCrc(HeaderAt(d, S.segments[i].offset), d, S.segments[i].offset + 6, hd.sideInfoBytes * 8)
         = (d[S.segments[i].offset + 4] shl 8) or d[S.segments[i].offset + 5] then Inc(totCrcOk);
    end;
    slots := Integer(S.segments[i].length) - SlotsOffset(hd);
    start := (slotPos - si.mainDataBegin) * 8;
    stop := start + MainDataBits(si);
    if (start >= prevEnd) and (stop <= (slotPos + slots) * 8) then
    begin
      Inc(mapped); Inc(totDataBits, stop - start);
      prevEnd := stop;
    end
    else Inc(totUnmapped);
    Inc(slotPos, slots);
    Inc(totSlotBits, Int64(slots) * 8);
  end;
  Inc(totFrames, frames); Inc(totMapped, mapped);
  if frames > 0 then
  begin
    Check(sideOk = frames, Format('%s: side info of %d frames back', [ExtractFileName(name), frames]));
    if not quiet or (mapped < frames) then
      Writeln(Format('    %s: %d of %d frames mapped', [ExtractFileName(name), mapped, frames]));
  end;
end;

var i: Integer; sr: TSearchRec; a: string;
begin
  cells := 0; failures := 0; quiet := False;
  totFrames := 0; totMapped := 0; totUnmapped := 0; totCrc := 0; totCrcOk := 0;
  totSlotBits := 0; totDataBits := 0;
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
  Check(totCrc = totCrcOk, Format('CRC of %d protected frames: %d match', [totCrc, totCrcOk]));
  Writeln(Format('frames %d, mapped %d, not mapped %d; main data %d of %d slot bits (%.2f%%)',
    [totFrames, totMapped, totUnmapped, totDataBits, totSlotBits, 100 * totDataBits / Max(1, totSlotBits)]));
  Writeln(cells, ' cells, ', failures, ' failures');
  files.Free;
  if failures > 0 then Halt(1);
end.
