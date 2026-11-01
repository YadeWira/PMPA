{ pmpal3 on every Layer III frame of the files given: the side information
  read and written back gives the same bytes; a frame's CRC is the one
  computed over its header and side information; and the main data of each
  frame of a run lies inside the run's slot stream, after the frame before
  and before its own slots end (or the frame is counted as not mapped: its
  main data begins before the run does).

    test_l3 [-q] <file or dir>... }
program test_l3;
{$I ../pmpa.inc}
uses SysUtils, Classes, Math, pmpampeg, pmpal3, pmpahuff;

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
  totGranules, totRegular, totBack, totPart2Over, totHuffBits, totRegularBits, totTails, totTailBits: Int64;
  irregular: TStringList;

procedure OneFile(const name: string);
var
  d, w: TBytes; S: TMpegScan; i, k: Integer; hd, first: TMpegHeader; si: TSideInfo;
  same, inRun: Boolean; slotPos, prevEnd, start, stop, b: Int64; slots, sideOk, frames, mapped: Integer;
  slotBuf: TBytes; g, c, p2, p3, quads, tail, j: Integer; vals: TGranuleValues; bw: TBitWriter; back: Boolean;
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
      slotBuf := nil;
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
    SetLength(slotBuf, slotPos + slots);
    Move(d[S.segments[i].offset + SlotsOffset(hd)], slotBuf[slotPos], slots);
    start := (slotPos - si.mainDataBegin) * 8;
    stop := start + MainDataBits(si);
    if (start >= prevEnd) and (stop <= (slotPos + slots) * 8) then
    begin
      Inc(mapped); Inc(totDataBits, stop - start);
      prevEnd := stop;
      { each granule: its scalefactors, then its Huffman bits, decoded and
        coded again }
      b := start;
      for g := 0 to si.nGr - 1 do
        for c := 0 to si.nCh - 1 do
        begin
          Inc(totGranules);
          p2 := Part2Bits(si, g, c, hd);
          p3 := si.gr[g, c].part23 - p2;
          Inc(totHuffBits, Max(p3, 0));
          if p3 < 0 then Inc(totPart2Over)
          else if DecodeValues(slotBuf, b + p2, p3, si.gr[g, c], hd, vals, quads, tail) then
          begin
            Inc(totRegular); Inc(totRegularBits, p3);
            bw.Init(p3 div 8 + 1);
            back := EncodeValues(vals, quads, si.gr[g, c], hd, bw) and (bw.pos = p3 - tail);
            if back then
              for j := 0 to p3 - tail - 1 do
                if ((bw.d[j shr 3] shr (7 - (j and 7))) and 1)
                   <> ((slotBuf[(b + p2 + j) shr 3] shr (7 - ((b + p2 + j) and 7))) and 1) then
                  back := False;
            if back then Inc(totBack);
            if tail > 0 then Inc(totTails);
            Inc(totTailBits, tail);
          end
          else if irregular.Count < 12 then
            irregular.Add(Format('%s frame %d gr %d ch %d: bt %d ws %d mixed %d tables %d %d %d bv %d part2 %d part3 %d',
              [ExtractFileName(name), frames, g, c, si.gr[g, c].blockType, si.gr[g, c].winSwitch, si.gr[g, c].mixed,
               si.gr[g, c].table[0], si.gr[g, c].table[1], si.gr[g, c].table[2], si.gr[g, c].bigValues, p2, p3]));
          Inc(b, si.gr[g, c].part23);
        end;
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

var i, r, k, n1, n2: Integer; sr: TSearchRec; a: string; v: TMpegVersion; same: Boolean;
begin
  cells := 0; failures := 0; quiet := False;
  totFrames := 0; totMapped := 0; totUnmapped := 0; totCrc := 0; totCrcOk := 0;
  totSlotBits := 0; totDataBits := 0;
  totGranules := 0; totRegular := 0; totBack := 0; totPart2Over := 0; totHuffBits := 0; totRegularBits := 0; totTails := 0; totTailBits := 0;
  irregular := TStringList.Create;
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
  Check(TablesComplete, 'every Huffman table is a complete prefix code');
  same := True;
  for v := Low(TMpegVersion) to High(TMpegVersion) do
    for r := 0 to 2 do
    begin
      n1 := 0; n2 := 0;
      for k := 0 to 21 do Inc(n1, SFB_LONG[v, r, k]);
      for k := 0 to 12 do Inc(n2, SFB_SHORT[v, r, k]);
      if (n1 <> 576) or (n2 <> 192) then same := False;
    end;
  Check(same, 'every band table covers 576 values (192 a short window)');
  Check(totRegular = totBack, Format('regular granules coded again give their bits back: %d of %d', [totBack, totRegular]));
  for i := 0 to irregular.Count - 1 do Writeln('    irregular: ', irregular[i]);
  Writeln(Format('granules with a tail %d, %d bits', [totTails, totTailBits]));
  Writeln(Format('granules %d: regular %d (%.2f%%, %.2f%% of the Huffman bits), part2 longer than part23 %d',
    [totGranules, totRegular, 100 * totRegular / Max(1, totGranules), 100 * totRegularBits / Max(1, totHuffBits), totPart2Over]));
  Writeln(Format('frames %d, mapped %d, not mapped %d; main data %d of %d slot bits (%.2f%%)',
    [totFrames, totMapped, totUnmapped, totDataBits, totSlotBits, 100 * totDataBits / Max(1, totSlotBits)]));
  Writeln(cells, ' cells, ', failures, ' failures');
  files.Free;
  if failures > 0 then Halt(1);
end.
