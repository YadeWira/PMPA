{ Writes pas/pmpaselftest.inc: the samples of `pmpa selftest` and the .pmpa
  each one has to give. The samples are the start of synthetic files in
  tests/ (scripts/mksamples.py made them): a Layer I, a Layer II and a
  Layer III file with CRCs, a Layer III file whose ID3v2 tag holds a JPEG
  (through PJA), the Layer III one again as stream version 7 (0.1.0's,
  before the covers), and the cover one as stream version 8, the very
  .pmpa 0.3.x wrote (pas/tests/selftest_v8.pmpa, its covers through PJA
  0.6.3): the last two selftest only extracts.

    gen_selftest <tests dir> <out .inc>

  run_tests.sh writes it again and compares: a stream change that is not
  in the include fails there. }
program gen_selftest;
{$I ../pmpa.inc}
uses {$ifdef UNIX} cthreads, {$endif} SysUtils, Classes, pmpablake3, pmpampeg, pmpaformat, pmpacodec, pmpapack, pmpac;

type
  TSample = record
    name, path, ext: string;
    cut: Integer;        { bytes kept after the first frame; 0: all }
    ver: Integer;        { the stream version; 0: what Pack writes }
    fixed: string;       { a .pmpa kept as an older release wrote it ('' none) }
  end;

const
  SAMPLES: array[0..5] of TSample = (
    (name: 'l1_64k_32k_mono_crc.mp1'; path: 'mp1/l1_64k_32k_mono_crc.mp1'; ext: 'mp1'; cut: 3072; ver: 0; fixed: ''),
    (name: 'l2_64k_32k_mono_crc.mp2'; path: 'mp2/l2_64k_32k_mono_crc.mp2'; ext: 'mp2'; cut: 3072; ver: 0; fixed: ''),
    (name: 'l3_mpeg25_32k_12k_crc.mp3'; path: 'mp3/l3_mpeg25_32k_12k_crc.mp3'; ext: 'mp3'; cut: 3072; ver: 0; fixed: ''),
    (name: 'v23_tag_unsync_every_ff.mp3'; path: 'covers/v23_tag_unsync_every_ff.mp3'; ext: 'mp3'; cut: 3072; ver: 0; fixed: ''),
    (name: 'l3_mpeg25_32k_12k_crc.mp3 (version 7)'; path: 'mp3/l3_mpeg25_32k_12k_crc.mp3'; ext: 'mp3'; cut: 3072; ver: 7; fixed: ''),
    (name: 'v23_tag_unsync_every_ff.mp3 (version 8)'; path: 'covers/v23_tag_unsync_every_ff.mp3'; ext: 'mp3'; cut: 3072; ver: 8;
     fixed: '../pas/tests/selftest_v8.pmpa'));

function LoadFile(const f: string): TBytes;
var s: TFileStream;
begin
  Result := nil;
  s := TFileStream.Create(f, fmOpenRead or fmShareDenyNone);
  try
    SetLength(Result, s.Size);
    if s.Size > 0 then s.ReadBuffer(Result[0], s.Size);
  finally
    s.Free;
  end;
end;

{ the file up to `cut` bytes past where its first frame starts }
function CutFile(const d: TBytes; n: Integer): TBytes;
var S: TMpegScan; i: Integer; first, len: Int64;
begin
  ScanMpeg(d, S);
  first := 0;
  for i := 0 to S.count - 1 do
    if S.segments[i].kind = skFrame then begin first := S.segments[i].offset; Break; end;
  len := first + n;
  if (n = 0) or (len > Length(d)) then len := Length(d);
  Result := Copy(d, 0, len);
end;

procedure Emit(o: TStringList; const name: string; const b: TBytes);
var i: Integer; line: string;
begin
  o.Add(Format('  %s: array[0..%d] of Byte = (', [name, High(b)]));
  line := '   ';
  for i := 0 to High(b) do begin
    line := line + ' $' + IntToHex(b[i], 2);
    if i < High(b) then line := line + ',';
    if (i mod 20 = 19) or (i = High(b)) then begin o.Add(line); line := '   '; end;
  end;
  o.Add('  );');
end;

var
  o: TStringList; k: Integer; d, s, p: TBytes; r: TPackResult; f: TPmpaResult; names, exts, vers: string;
begin
  if ParamCount < 2 then begin Writeln('usage: gen_selftest <tests dir> <out .inc>'); Halt(2); end;
  o := TStringList.Create;
  o.Add('{ Written by pas/tests/gen_selftest.pas: do not edit. The samples of `pmpa');
  o.Add('  selftest` (the start of synthetic files in tests/) and the .pmpa of each. }');
  o.Add('const');
  names := ''; exts := ''; vers := '';
  for k := 0 to High(SAMPLES) do begin
    d := CutFile(LoadFile(IncludeTrailingPathDelimiter(ParamStr(1)) + SAMPLES[k].path), SAMPLES[k].cut);
    if SAMPLES[k].ver = 0 then begin
      r := Pack(d, p, SAMPLES[k].ext, 1);
      if not r.Ok or r.stored then begin Writeln('gen_selftest: ', SAMPLES[k].name, ': ', r.Text); Halt(1); end;
    end else if SAMPLES[k].fixed <> '' then
      p := LoadFile(IncludeTrailingPathDelimiter(ParamStr(1)) + SAMPLES[k].fixed)
    else begin
      s := EncodeAs(d, SAMPLES[k].ver);
      f := WritePmpa(s, Blake3_128(d), Length(d), p, False, SAMPLES[k].ext);
      if not f.Ok then begin Writeln('gen_selftest: ', SAMPLES[k].name, ': ', f.Text); Halt(1); end;
    end;
    Emit(o, 'SELFTEST_IN_' + IntToStr(k), d);
    Emit(o, 'SELFTEST_PMPA_' + IntToStr(k), p);
    if k > 0 then begin names := names + ', '; exts := exts + ', '; vers := vers + ', '; end;
    names := names + '''' + SAMPLES[k].name + '''';
    exts := exts + '''' + SAMPLES[k].ext + '''';
    if SAMPLES[k].ver = 0 then vers := vers + 'True' else vers := vers + 'False';
    Writeln(SAMPLES[k].name, ': ', Length(d), ' B -> ', Length(p), ' B');
  end;
  o.Add(Format('  SELFTEST_COUNT = %d;', [Length(SAMPLES)]));
  o.Add('  SELFTEST_NAMES: array[0..SELFTEST_COUNT - 1] of string = (' + names + ');');
  o.Add('  SELFTEST_EXTS: array[0..SELFTEST_COUNT - 1] of string = (' + exts + ');');
  o.Add('  { False: an older stream version, only extracted }');
  o.Add('  SELFTEST_CURRENT: array[0..SELFTEST_COUNT - 1] of Boolean = (' + vers + ');');
  o.Add('');
  o.Add('procedure SelftestSample(k: Integer; out data, expect: TBytes);');
  o.Add('begin');
  o.Add('  data := nil; expect := nil;');
  o.Add('  case k of');
  for k := 0 to High(SAMPLES) do begin
    o.Add(Format('    %d: begin', [k]));
    o.Add(Format('      SetLength(data, Length(SELFTEST_IN_%d)); Move(SELFTEST_IN_%d[0], data[0], Length(data));', [k, k]));
    o.Add(Format('      SetLength(expect, Length(SELFTEST_PMPA_%d)); Move(SELFTEST_PMPA_%d[0], expect[0], Length(expect));', [k, k]));
    o.Add('    end;');
  end;
  o.Add('  end;');
  o.Add('end;');
  o.SaveToFile(ParamStr(2));
  o.Free;
end.
