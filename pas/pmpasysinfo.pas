{ What the command says about itself and the machine: its version and
  commit, the compilers, the target, the system, the processor's features
  and the SIMD path the models take (--version, report, bench, selftest),
  and --cpu, which chooses that path. PJA's pjasysinfo, adapted.

  The paths: PMPA's mixer (pmpamodel) has plain code and, on x86-64, an
  SSE4.1 copy; the covers' JPEG model (PJA's, vendor/pja) plain code,
  SSE4.1 and an AVX2 copy of version 7's loop (pjav7c.c). Every path gives
  the same bits (selftest checks it); only the speed changes. Which one
  runs is pmpamodel's UseSse41 and PJA's GetSimd/SetSimd, set at start from
  cpuid (PMPA_NOASM=1, PJA_NOASM=1 and PJA_NOAVX2=1 turn them off), and
  here by --cpu: sse41 is both models' SSE4.1, avx2 that and PJA's AVX2.
  The C hot loops (pmpal3c.c) have no SIMD copy: they run on every path
  (PMPA_NOC=1 leaves them to Pascal). }
unit pmpasysinfo;

{$I pmpa.inc}
{$ifopt R-}{$fatal pmpasysinfo: range checks ($R+) are mandatory}{$endif}
{$ifopt Q-}{$fatal pmpasysinfo: overflow checks ($Q+) are mandatory}{$endif}

interface

uses SysUtils, pmpainfo;

type
  TCpuPath = (cpPlain, cpSse41, cpAvx2);

const
  CPU_PATH_NAMES: array[TCpuPath] of string = ('plain', 'sse41', 'avx2');
  ISSUES_URL = 'https://github.com/YadeWira/PMPA/issues';

var
  { set by the program, which is compiled every time: a unit's .ppu would
    keep an old commit }
  BuildCommit: string = '';
  BuildDate: string = '';

function ParseCpuPath(const s: string; out p: TCpuPath): Boolean;
{ the processor has it (the SIMD code is in every x86-64 build) }
function CpuPathSupported(p: TCpuPath): Boolean;
{ whether the C hot loops run: "on", or why not }
function CLoops: string;
{ the paths CpuPathSupported says yes to, by name: "plain sse41" }
function SupportedPaths: string;
function CurrentCpuPath: TCpuPath;
{ False, and nothing changed, for a path CpuPathSupported says no to.
  Only while no file is being worked on. }
function SetCpuPath(p: TCpuPath): Boolean;

{ "x86_64-linux" }
function TargetName: string;
function FpcVersion: string;
function CCompiler: string;
{ the processor's name, as it gives it ('' when it does not) }
function CpuName: string;
{ the features the paths need, as the processor has them: "sse4.1 avx2" }
function CpuFeatures: string;
{ the system, as it names itself: "Linux 6.12.1 x86_64", "Windows 10.0.19045" }
function SystemName: string;
{ the processors this process may use, and the threads by default }
function DefaultThreads: Integer;

{ everything above, as fields of n }
procedure DescribeSystem(n: TInfoNode);
{ one block of text, "name: value" a line, for --version, report and bench;
  withVersion: the first line PMPA's version }
function SystemText(withVersion: Boolean): string;

implementation

uses
  {$ifdef UNIX} BaseUnix, {$endif}
  {$ifdef MSWINDOWS} Windows, {$endif}
  Classes, pmpacodec, pmpacpu, pmpamodel, pmpac, pjamodel, pjav7;

{$ifdef CPUX86_64}
{$asmmode intel}
procedure CpuId(leaf, sub: LongWord; out a, b, c, d: LongWord);
var ra, rb, rc, rd: LongWord;
begin
  asm
    push rbx
    mov eax, leaf
    mov ecx, sub
    cpuid
    mov ra, eax
    mov rb, ebx
    mov rc, ecx
    mov rd, edx
    pop rbx
  end ['rax', 'rcx', 'rdx'];
  a := ra; b := rb; c := rc; d := rd;
end;

function XGetBv0: LongWord;
var r: LongWord;
begin
  asm
    xor ecx, ecx
    xgetbv
    mov r, eax
  end ['rax', 'rcx', 'rdx'];
  Result := r;
end;
{$endif}

function HasSse41: Boolean;
{$ifdef CPUX86_64} var a, b, c, d: LongWord; {$endif}
begin
  Result := False;
  {$ifdef CPUX86_64}
  CpuId(1, 0, a, b, c, d);
  Result := c and (1 shl 19) <> 0;
  {$endif}
end;

{ AVX2, and the system saving the 256-bit registers }
function HasAvx2: Boolean;
{$ifdef CPUX86_64} var a, b, c, d, top: LongWord; {$endif}
begin
  Result := False;
  {$ifdef CPUX86_64}
  CpuId(0, 0, top, b, c, d);
  if top < 7 then Exit;
  CpuId(1, 0, a, b, c, d);
  if (c and (1 shl 27) = 0) or (c and (1 shl 28) = 0) then Exit;
  if XGetBv0 and 6 <> 6 then Exit;
  CpuId(7, 0, a, b, c, d);
  Result := b and (1 shl 5) <> 0;
  {$endif}
end;

function CpuName: string;
{$ifdef CPUX86_64} var b, c, d, top: LongWord; leaf: LongWord; i: Integer; regs: array[0..3] of LongWord;
                   raw: array[0..47] of Char; {$endif}
{$ifdef LINUX} var f: TStringList; k: Integer; {$endif}
begin
  Result := '';
  {$ifdef CPUX86_64}
  CpuId($80000000, 0, top, b, c, d);
  if top >= $80000004 then begin
    for leaf := $80000002 to $80000004 do begin
      CpuId(leaf, 0, regs[0], regs[1], regs[2], regs[3]);
      for i := 0 to 3 do Move(regs[i], raw[(leaf - $80000002) * 16 + i * 4], 4);
    end;
    for i := 0 to 47 do
      if raw[i] = #0 then Break
      else if raw[i] in [#32..#126] then Result := Result + raw[i];
    Result := Trim(Result);
  end;
  {$endif}
  {$ifdef LINUX}
  if Result = '' then begin
    f := TStringList.Create;
    try
      try
        f.LoadFromFile('/proc/cpuinfo');
        for k := 0 to f.Count - 1 do
          if (Pos('model name', f[k]) = 1) or (Pos('Model', f[k]) = 1) or (Pos('Hardware', f[k]) = 1) then begin
            Result := Trim(Copy(f[k], Pos(':', f[k]) + 1, MaxInt));
            if Result <> '' then Break;
          end;
      except
        Result := '';
      end;
    finally
      f.Free;
    end;
  end;
  {$endif}
end;

function CpuFeatures: string;
begin
  Result := '';
  {$ifdef CPUX86_64}
  Result := 'sse2';
  if HasSse41 then Result := Result + ' sse4.1';
  if HasAvx2 then Result := Result + ' avx2';
  {$else}
  {$ifdef CPUI386} Result := 'x86 (32-bit: the plain path only)'; {$endif}
  {$endif}
  if Result = '' then Result := 'none the paths use';
end;

function ParseCpuPath(const s: string; out p: TCpuPath): Boolean;
var q: TCpuPath;
begin
  for q := Low(TCpuPath) to High(TCpuPath) do
    if LowerCase(s) = CPU_PATH_NAMES[q] then begin p := q; Exit(True); end;
  p := cpPlain;
  Result := False;
end;

function CpuPathSupported(p: TCpuPath): Boolean;
begin
  case p of
    cpPlain: Result := True;
    cpSse41: Result := {$ifdef CPUX86_64} HasSse41 {$else} False {$endif};
    { AVX2 changes the covers' model alone: PMPA's own has no AVX2 copy }
    cpAvx2: Result := {$ifdef CPUX86_64} HasSse41 and HasAvx2 {$else} False {$endif};
  else
    Result := False;
  end;
end;

function CLoops: string;
begin
  if CInUse then Result := 'on (Layer III values, Layer I and II samples)'
  else if SysUtils.GetEnvironmentVariable('PMPA_NOC') = '1' then Result := 'off (PMPA_NOC=1: Pascal)'
  else Result := 'off (layout check failed: Pascal)';
end;

function SupportedPaths: string;
var p: TCpuPath;
begin
  Result := '';
  for p := Low(TCpuPath) to High(TCpuPath) do
    if CpuPathSupported(p) then begin
      if Result <> '' then Result := Result + ' ';
      Result := Result + CPU_PATH_NAMES[p];
    end;
end;

function CurrentCpuPath: TCpuPath;
var sse41, avx2: Boolean;
begin
  GetSimd(sse41, avx2);
  if avx2 then Result := cpAvx2
  else if sse41 or UseSse41 then Result := cpSse41
  else Result := cpPlain;
end;

function SetCpuPath(p: TCpuPath): Boolean;
begin
  if not CpuPathSupported(p) then Exit(False);
  UseSse41 := p >= cpSse41;
  SetSimd(p >= cpSse41, p = cpAvx2);
  V7Retable;
  Result := True;
end;

{ the SIMD copies of the covers' C model in this build: "sse41 avx2", or
  none (a compiler without them) }
function CSimdCopies: string;
begin
  {$ifndef CPUX86_64} Exit('none used (the plain path only)'); {$endif}
  Result := '';
  if V7Paths and 1 <> 0 then Result := 'sse41';
  if V7Paths and 2 <> 0 then begin
    if Result <> '' then Result := Result + ' ';
    Result := Result + 'avx2';
  end;
  if Result = '' then Result := 'none (the covers'' C model runs plain on every path)';
end;

function TargetName: string;
begin
  Result := LowerCase({$I %FPCTARGETCPU%} + '-' + {$I %FPCTARGETOS%});
end;

function FpcVersion: string;
begin
  Result := {$I %FPCVERSION%};
end;

function CCompiler: string;
begin
  Result := CCompilerName;
end;

{$ifdef MSWINDOWS}
type
  { RTL_OSVERSIONINFOW is OSVERSIONINFOW }
  TRtlGetVersion = function(var v: TOSVersionInfoW): LongInt; stdcall;
{$endif}

function SystemName: string;
{$ifdef UNIX} var u: UtsName; {$endif}
{$ifdef MSWINDOWS} var v: TOSVersionInfoA; w: TOSVersionInfoW; get: TRtlGetVersion; {$endif}
begin
  Result := '';
  {$ifdef UNIX}
  if fpUname(u) = 0 then
    Result := StrPas(PChar(@u.sysname[0])) + ' ' + StrPas(PChar(@u.release[0])) + ' ' + StrPas(PChar(@u.machine[0]));
  {$endif}
  {$ifdef MSWINDOWS}
  FillChar(v, SizeOf(v), 0);
  v.dwOSVersionInfoSize := SizeOf(v);
  FillChar(w, SizeOf(w), 0);
  w.dwOSVersionInfoSize := SizeOf(w);
  { GetVersionEx says 6.2 on any Windows past 8 to a program without a
    manifest: ntdll's RtlGetVersion tells the truth (on XP too) }
  get := TRtlGetVersion(GetProcAddress(GetModuleHandle('ntdll.dll'), 'RtlGetVersion'));
  if (@get <> nil) and (get(w) = 0) then begin
    v.dwMajorVersion := w.dwMajorVersion; v.dwMinorVersion := w.dwMinorVersion; v.dwBuildNumber := w.dwBuildNumber;
  end;
  if (w.dwMajorVersion <> 0) or GetVersionExA(@v) then
    Result := 'Windows ' + IntToStr(v.dwMajorVersion) + '.' + IntToStr(v.dwMinorVersion) + ' build ' +
              IntToStr(v.dwBuildNumber)
  else Result := 'Windows';
  {$endif}
  if Result = '' then Result := {$I %FPCTARGETOS%};
end;

function DefaultThreads: Integer;
begin
  Result := CpuCount;
  if Result > 8 then Result := 8;
  if Result < 1 then Result := 1;
end;

procedure DescribeSystem(n: TInfoNode);
begin
  n.Str('pmpa', PMPA_VERSION);
  n.Str('commit', BuildCommit);
  n.Str('built', BuildDate);
  n.Str('fpc', FpcVersion);
  n.Str('c_compiler', CCompiler);
  n.Str('target', TargetName);
  n.Str('system', SystemName);
  n.Str('cpu', CpuName);
  n.Str('cpu_features', CpuFeatures);
  n.Str('cpu_path', CPU_PATH_NAMES[CurrentCpuPath]);
  n.Str('cpu_paths_supported', SupportedPaths);
  n.Num('stream_version', STREAM_VERSION);
  n.Str('c_loops', CLoops);
  n.Str('covers_c_simd_copies', CSimdCopies);
  n.Num('processors', CpuCount);
  n.Num('default_threads', DefaultThreads);
end;

function SystemText(withVersion: Boolean): string;
var n: TInfoNode; sl: TStringList; k: Integer;
begin
  Result := '';
  n := TInfoNode.Create(ikObject);
  sl := TStringList.Create;
  try
    DescribeSystem(n);
    n.Render(sl);
    for k := 0 to sl.Count - 1 do
      if withVersion or (k > 0) then Result := Result + sl[k] + LineEnding;
  finally
    sl.Free;
    n.Free;
  end;
end;

end.
