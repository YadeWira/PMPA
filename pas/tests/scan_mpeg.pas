{ Prints how pmpampeg cuts each file given: its segments with -v, else one
  line per file (frames, frame bytes, raw bytes, tags), and a total. A tool
  for looking at real files, not a test. }
program scan_mpeg;
{$I ../pmpa.inc}
uses SysUtils, Classes, pmpampeg;

function LoadFile(const name: string): TBytes;
var f: TFileStream;
begin
  f := TFileStream.Create(name, fmOpenRead or fmShareDenyNone);
  try
    SetLength(Result, f.Size);
    if f.Size > 0 then f.ReadBuffer(Result[0], f.Size);
  finally
    f.Free;
  end;
end;

var
  S: TMpegScan; data: TBytes; i, j, first: Integer; verbose: Boolean;
  hd: TMpegHeader; tags: string;
  totFiles, totBytes, totFrames, totFrameBytes, totRaw: Int64;
begin
  verbose := (ParamCount > 0) and (ParamStr(1) = '-v');
  if verbose then first := 2 else first := 1;
  totFiles := 0; totBytes := 0; totFrames := 0; totFrameBytes := 0; totRaw := 0;
  for i := first to ParamCount do
  begin
    data := LoadFile(ParamStr(i));
    ScanMpeg(data, S);
    tags := '';
    for j := 0 to S.count - 1 do
    begin
      if not (S.segments[j].kind in [skRaw, skFrame]) then
        tags := tags + ' ' + SegmentKindName(S.segments[j].kind);
      if verbose and ((S.segments[j].kind <> skFrame) or (j < 3)) then
      begin
        Write('  ', S.segments[j].offset:10, ' ', S.segments[j].length:9, ' ', SegmentKindName(S.segments[j].kind));
        if (S.segments[j].kind = skFrame) and DecodeHeader(HeaderAt(data, S.segments[j].offset), hd) then
          Write(' ', VersionName(hd.version), ' L', hd.layer, ' ', hd.bitrate, 'k ', hd.sampleRate, ' Hz mode ', hd.mode,
            ' crc ', hd.hasCrc);
        Writeln;
      end;
    end;
    Writeln(ParamStr(i), ': ', Length(data), ' B, ', S.frames, ' frames (', S.frameBytes, ' B), raw ', S.rawBytes, ' B', tags);
    Inc(totFiles); Inc(totBytes, Length(data)); Inc(totFrames, S.frames);
    Inc(totFrameBytes, S.frameBytes); Inc(totRaw, S.rawBytes);
  end;
  Writeln('total: ', totFiles, ' files, ', totBytes, ' B, ', totFrames, ' frames (', totFrameBytes, ' B), raw ', totRaw, ' B');
end.
