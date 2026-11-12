{ pmpa selftest (doc/CLI.md): the samples inside the binary
  (pmpaselftest.inc, written by pas/tests/gen_selftest.pas: the start of a
  Layer I, a Layer II and a Layer III file, one whose ID3v2 tag holds a
  JPEG that goes through PJA, and the Layer III one again as stream
  version 7, 0.1.0's) compressed and extracted on every SIMD path this
  machine and this build have (pmpasysinfo), with one thread and with two
  (two decode the stream while it is encoded). Each .pmpa has to be the
  very bytes the include holds, on every path, and each has to come back
  as its sample; the older version's is only extracted. PJA's
  pjaselftest, adapted. }
unit pmpaselftest;

{$I pmpa.inc}
{$ifopt R-}{$fatal pmpaselftest: range checks ($R+) are mandatory}{$endif}
{$ifopt Q-}{$fatal pmpaselftest: overflow checks ($Q+) are mandatory}{$endif}

interface

uses pmpasysinfo;

{ Prints a line per path and a summary (only failures and the summary with
  quiet). 0 when every check passed, 1 if not. onePath: only `only` (--cpu),
  which the caller has checked this machine has. }
function RunSelftest(quiet: Boolean; onePath: Boolean = False; only: TCpuPath = cpPlain): Integer;

implementation

uses SysUtils, pmpablake3, pmpapack, pmpainfo;

{$I pmpaselftest.inc}

function SameBytes(const a, b: TBytes): Boolean;
begin
  Result := (Length(a) = Length(b)) and ((Length(a) = 0) or CompareMem(@a[0], @b[0], Length(a)));
end;

function RunSelftest(quiet: Boolean; onePath: Boolean; only: TCpuPath): Integer;
const THREAD_COUNTS: array[0..1] of Integer = (1, 2);
var was, p: TCpuPath; k, t, checks, failed, pathFailed, paths: Integer; data, want, got, back: TBytes;
    r: TPackResult; h: THash16; why, names: string;
begin
  was := CurrentCpuPath;
  checks := 0; failed := 0; paths := 0; names := '';
  if not quiet then begin
    if onePath then
      Writeln('pmpa selftest: ', SELFTEST_COUNT, ' samples inside the binary, on the SIMD path ',
              CPU_PATH_NAMES[only], ' (--cpu), with 1 and 2 threads')
    else
      Writeln('pmpa selftest: ', SELFTEST_COUNT, ' samples inside the binary, on every SIMD path here (',
              SupportedPaths, '), with 1 and 2 threads');
    for k := 0 to SELFTEST_COUNT - 1 do begin
      SelftestSample(k, data, want);
      Writeln('  ', SELFTEST_NAMES[k], ': ', Length(data), ' B -> ', Length(want), ' B, .pmpa blake3-128 ',
              HexBytes(Blake3_128(want)));
    end;
  end;
  try
    for p := Low(TCpuPath) to High(TCpuPath) do begin
      if not CpuPathSupported(p) or (onePath and (p <> only)) then Continue;
      Inc(paths);
      if names <> '' then names := names + ' ';
      names := names + CPU_PATH_NAMES[p];
      SetCpuPath(p);
      pathFailed := 0;
      for k := 0 to SELFTEST_COUNT - 1 do begin
        SelftestSample(k, data, want);
        for t := 0 to High(THREAD_COUNTS) do begin
          Inc(checks);
          why := '';
          if SELFTEST_CURRENT[k] then begin
            r := Pack(data, got, SELFTEST_EXTS[k], THREAD_COUNTS[t], True);
            if not r.Ok then why := 'compress failed: ' + r.Text
            else if not SameBytes(got, want) then
              why := 'a different .pmpa: ' + IntToStr(Length(got)) + ' B, blake3-128 ' + HexBytes(Blake3_128(got));
          end else got := want;
          if why = '' then begin
            r := Unpack(got, QWord(Length(data)), back, h, THREAD_COUNTS[t]);
            if not r.Ok then why := 'extract failed: ' + r.Text
            else if not SameBytes(back, data) then why := 'extracted to other bytes';
          end;
          if why <> '' then begin
            Inc(failed); Inc(pathFailed);
            Writeln(StdErr, 'pmpa: selftest: ', SELFTEST_NAMES[k], ' on ', CPU_PATH_NAMES[p], ' with ',
                    THREAD_COUNTS[t], ' thread(s): ', why);
          end;
        end;
      end;
      if not quiet then begin
        if pathFailed = 0 then Writeln('  path ', CPU_PATH_NAMES[p], ': ok')
        else Writeln('  path ', CPU_PATH_NAMES[p], ': ', pathFailed, ' FAILED');
      end;
    end;
  finally
    SetCpuPath(was);
  end;
  if failed = 0 then begin
    Writeln('selftest: ', checks, ' of ', checks, ' checks passed on ', paths, ' path(s) (', names,
            '): every .pmpa the expected bytes, every sample back');
    Result := 0;
  end else begin
    Writeln(StdErr, 'pmpa: selftest: ', failed, ' of ', checks, ' checks FAILED. This is a bug in PMPA: please run',
            ' pmpa report and open an issue at ', ISSUES_URL);
    Result := 1;
  end;
end;

end.
