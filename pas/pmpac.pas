{ PMPA's hot loop in C (pmpal3c.c, compiled to pmpal3c.o before this unit:
  pas/build_c.sh). A program that uses this unit codes stream version 6's
  Layer III values and Layer I and II samples in C; one that does not codes them in Pascal: the same
  streams, which the suite checks (and PMPA_NOC=1 leaves them to Pascal in
  a program that has the C).

  The C takes no memory and calls no library: it gets the tables here, and
  the counters, mixer, APM and coder's state from pmpacodec for each
  granule; two callbacks carry bytes in and out of pmpaarith's coder.
  Before anything, the C's structs are compared with pmpacodec's records:
  laid out otherwise, the C is not used. }
unit pmpac;

{$I pmpa.inc}
{$ifopt R-}{$fatal pmpac: range checks ($R+) are mandatory}{$endif}
{$ifopt Q-}{$fatal pmpac: overflow checks ($Q+) are mandatory}{$endif}

interface

{ whether the C is in use: its layout matched, and PMPA_NOC is not 1 }
function CInUse: Boolean;
{ the C compiler pmpal3c.c was built with: "gcc 14.2.0", "clang 19.1.7" }
function CCompilerName: string;

implementation

uses SysUtils, pmpaarith, pmpamodel, pmpacodec;

{$L pmpal3c.o}

type
  TTablesC = record
    putFn: Pointer;
    getFn: Pointer;
    stretchT: PSmallInt;
    recip: PLongInt;
    reciprocal: PLongInt;
  end;

procedure pmpac_tables(constref t: TTablesC); cdecl; external;
function pmpac_values(var s: TValuesC): LongInt; cdecl; external;
function pmpac_layout(k: LongInt): LongInt; cdecl; external;
function pmpac_samples(var s: TSamplesC): LongInt; cdecl; external;
function pmpac_compiler: PAnsiChar; cdecl; external;

{ n bytes of the encoder's output, as TArithEncoder.Encode writes them }
procedure Put(ctx: Pointer; b: PByte; n: SizeInt); cdecl;
var e: ^TArithEncoder; i: SizeInt;
begin
  e := ctx;
  if e^.live <> nil then
    for i := 0 to n - 1 do e^.live.Put(b[i])
  else
  begin
    if e^.n + n > Length(e^.d) then SetLength(e^.d, 2 * Length(e^.d) + n + 4096);
    Move(b^, e^.d[e^.n], n);
  end;
  Inc(e^.n, n);
end;

{ byte p of a stream still being written by another thread }
function Get(live: Pointer; p: SizeInt): Cardinal; cdecl;
begin
  Result := TLiveStream(live).Get(p);
end;

function LayoutOk: Boolean;
var a: TValuesC; e: TEncC; d: TDecC; sm: TSamplesC;
begin
  Result :=
    (pmpac_layout(0) = SizeOf(TValuesC)) and (pmpac_layout(1) = PtrUInt(@a.dg) - PtrUInt(@a)) and
    (pmpac_layout(2) = PtrUInt(@a.vt) - PtrUInt(@a)) and (pmpac_layout(3) = PtrUInt(@a.dec) - PtrUInt(@a)) and
    (pmpac_layout(4) = SizeOf(TEncC)) and (pmpac_layout(5) = PtrUInt(@e.buf) - PtrUInt(@e)) and
    (pmpac_layout(6) = SizeOf(TDecC)) and (pmpac_layout(7) = PtrUInt(@d.live) - PtrUInt(@d)) and
    (pmpac_layout(8) = SizeOf(TTablesC)) and (pmpac_layout(9) = SizeOf(TCounter)) and
    (SizeOf(TCounter) = SizeOf(TAdaptiveBit)) and
    (pmpac_layout(10) = SizeOf(TSamplesC)) and (pmpac_layout(11) = PtrUInt(@sm.vt) - PtrUInt(@sm)) and
    (pmpac_layout(12) = PtrUInt(@sm.dec) - PtrUInt(@sm));
end;

var
  t: TTablesC;
  inUse: Boolean = False;

function CInUse: Boolean;
begin
  Result := inUse;
end;

function CCompilerName: string;
begin
  Result := StrPas(pmpac_compiler);
end;

initialization
  t.putFn := @Put; t.getFn := @Get;
  t.stretchT := @STRETCH_T[0]; t.recip := @RECIP[0]; t.reciprocal := @RECIPROCAL[0];
  pmpac_tables(t);
  if LayoutOk and (GetEnvironmentVariable('PMPA_NOC') <> '1') then
  begin
    ValuesC := @pmpac_values;
    SamplesC := @pmpac_samples;
    inUse := True;
  end;
end.
