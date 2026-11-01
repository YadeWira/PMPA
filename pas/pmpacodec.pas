{ Layer 4: the codec stream. A whole file in, a stream out, and back.

  Stream (doc/CODEC.md):

      version     1 B      1 or 2 (both are read)
      length      varint   the original's length
      segments    arithmetic-coded, to the end

  The segments are pmpampeg's, in order, until the original's length:

      kind        3 binary decisions, in the context of the kind before
      frame       its 32-bit header, each bit in the context of the same bit
                  of the header before (and of whether the bits so far all
                  matched it); a free-format frame then gives its length
                  without padding (the same as the last one, or 16 bits);
                  then the frame's other bytes
      the rest    the length (its bit length, 6 decisions, then the bits
                  below the top one), then the bytes

  Version 2 codes a Layer III frame's other bytes by what they are
  (pmpal3): its side information field by field, each in the context of the
  same field of the granule before; its CRC as one decision, "the one the
  header and side information give", when it is; and its slots as part of
  the run's slot stream: the bits no frame's main data claims (filler) up
  to where this frame's main data starts, then its main data, bit by bit.
  After each Layer III frame a decision says whether the next segment is
  a frame of the same run; when it is not, the filler left at the end of
  the slot stream follows. A frame whose main data does not fit (it starts
  before the run, or overlaps the frame before) has its slots left to the
  filler: the decoder sees the same side information and decides the same.

  Other bytes are coded bit by bit in the context of the bits of the byte
  so far: alone inside frames (order 0), with the byte before elsewhere
  (order 1). Slot stream bits are coded in the context of the 12 bits
  before them, filler and main data apart.

  EncodeFile verifies: it decodes its own stream and compares it with the
  input. }
unit pmpacodec;

{$I pmpa.inc}
{$ifdef PMPA_FAST}
  {$R-}{$Q-}
{$else}
  {$ifopt R-}{$fatal pmpacodec: range checks ($R+) are mandatory}{$endif}
  {$ifopt Q-}{$fatal pmpacodec: overflow checks ($Q+) are mandatory}{$endif}
{$endif}

interface

uses SysUtils, pmpampeg, pmpal3, pmpahuff, pmpal12;

const
  STREAM_VERSION = 6;
  PMPA_VERSION = '0.1.0';

type
  TEncodeStatus = (
    esOk,
    esNotMpeg,         { no MPEG audio frame in the file: not PMPA's }
    esNotBack);        { the stream did not decode to the input: a bug, and
                         the caller stores the original instead }
  TDecodeStatus = (dsOk, dsEmpty, dsFutureVersion, dsBadStream, dsTooBig);

{ The stream of d, verified. }
function EncodeFile(const d: TBytes; out s: TBytes; threads: Integer = 1): TEncodeStatus;
{ The file of s, at most maxOut bytes. }
function DecodeFile(const s: TBytes; maxOut: Int64; out d: TBytes; threads: Integer = 1): TDecodeStatus;
function EncodeStatusName(st: TEncodeStatus): string;
type
  { pmpal3c.c's structs (pmpac.pas installs the C, after checking that these
    are laid out as its own) }
  TEncC = record
    x1, x2: Cardinal;
    ctx: Pointer;                     { the TArithEncoder }
    n: SizeInt;
    buf: array[0..4095] of Byte;
  end;
  TDecC = record
    x1, x2, x: Cardinal;
    d: PByte;
    len, p: SizeInt;
    live: Pointer;
  end;
  TValuesC = record
    v, pv, ov, steps, prevStep: PLongInt;
    cap, cls, lin: PShortInt;
    bigEnd, endAt, dg: LongInt;
    vt: Pointer; vtMask: Cardinal;
    w: PLongInt; inputs, rate: LongInt;
    apm: PLongInt; apmRate: LongInt;
    sign4, linLen, linLow: Pointer;
    decoding: LongInt;
    enc: ^TEncC;
    dec: ^TDecC;
  end;
  TValuesFn = function(var s: TValuesC): LongInt; cdecl;

var
  { stream version 6's Layer III values in C (pmpac.pas sets it); nil: in
    Pascal. The streams are the same either way. }
  ValuesC: TValuesFn = nil;

{ for the tests: the stream of d in an earlier version (1 to STREAM_VERSION),
  not verified; nil if d has no MPEG audio frame }
function EncodeAs(const d: TBytes; ver: Integer): TBytes;
function DecodeStatusName(st: TDecodeStatus): string;

{$ifdef PMPA_COSTS}
const
  COST_NAMES: array[0..32] of string = ('structure', 'other bytes', 'side info', 'filler',
    'scalefactors', 'raw granules', 'zero flags', 'magnitudes', 'signs', 'tails',
    ' si mdb', ' si private', ' si scfsi', ' si part23', ' si bigvalues', ' si gain',
    ' si sfcompress', ' si winswitch', ' si blocktype', ' si mixed', ' si table0',
    ' si table1', ' si table2', ' si subgain', ' si region0', ' si region1', ' si preflag',
    ' si sfscale', ' si count1tab', ' si crc', ' quads', ' tail length', 'L12 allocation');
var
  { what encoding cost, in bits, by part (the tools' build only) }
  Costs: array[0..32] of Double;
  { the tools' build: Layer III value contexts to leave out, a bit each }
  DropInput: Integer = 0;
{$endif}

implementation

uses {$ifdef PMPA_COSTS} Math, {$endif} pmpaarith, pmpamodel, pmpalimits;

const
  LIMIT_STRUCT = 127;   { the structure (kinds, headers, lengths) is steady }
  LIMIT_BYTES = 60;
  KIND_START = 6;       { the context of the first segment's kind }

const
  { the side information's fields, each with its own contexts }
  F_MDB = 0; F_PRIV = 1; F_SCFSI = 2; F_PART23 = 3; F_BIGV = 4; F_GAIN = 5;
  F_SFC = 6; F_WS = 7; F_BT = 8; F_MIX = 9; F_TAB = 10; { 10, 11, 12 }
  F_SUBG = 13; F_R0 = 14; F_R1 = 15; F_PRE = 16; F_SFS = 17; F_C1 = 18; F_CRC = 19;
  F_QUADS = 20; F_TAIL = 21; F_ODD = 22;
  N_FIELDS = 23;
  { the values' contexts: how many of each }
  N_CAP = 7;      { what the table allows: 1, 2, 3, 5, 7, 15, 15 and linbits }
  N_NB = 8;       { the two values before }
  N_PREV = 6;     { the same value in the granule before }
  N_POS = 6;      { where in the granule }
  { version 4 }
  V_TABLE_BITS = 20;
  V_INPUTS = 11;  { 10 counters and a bias }
  S_INPUTS = 5;
  EST_BUCKETS = 14;
  L_INPUTS = 7;   { Layer I and II: 6 counters and a bias }   { the scalefactors: 4 counters and a bias }
  { MPEG-1's preemphasis, added to a long band's scalefactor when preflag }
  PRETAB: array[0..21] of Integer = (0,0,0,0,0,0,0,0,0,0,0,1,1,1,1,2,2,3,3,3,2,0);
  V_LIMIT = 255;
  V_MIX_RATE = 6;
  HIST_BITS = 12;

type
  TModel = record
    decoding: Boolean;
    ver: Integer;           { the stream's version }
    enc: TArithEncoder;
    dec: TArithDecoder;
    kinds: array[0..KIND_START, 1..7] of TAdaptiveBit;
    header: array[0..31, 0..1, 0..1] of TAdaptiveBit;
    freeSame: TAdaptiveBit;
    freeBits: array[0..15] of TAdaptiveBit;
    lenBits: array[1..63] of TAdaptiveBit;       { a tree of 6 decisions }
    lenLow: array[0..62] of TAdaptiveBit;
    bytes: array[0..1, 0..255, 1..255] of TAdaptiveBit;   { [0, 0] for frames }
    { Layer III }
    fields: array[0..N_FIELDS - 1, 0..511, 0..1, 0..1] of TAdaptiveBit;
    crcOk, runGoesOn, mappedBit, tailNone: TAdaptiveBit;
    lastPart23: array[0..1] of Integer;
    slot: array[0..1, 0..(1 shl HIST_BITS) - 1] of TAdaptiveBit;   { [0] main data, [1] filler }
    { version 3: Layer III's Huffman-coded values }
    modelled: TAdaptiveBit;
    zero: array[0..N_CAP - 1, 0..N_NB - 1, 0..N_PREV - 1, 0..N_POS - 1] of TAdaptiveBit;
    gt: array[0..N_CAP - 1, 1..15, 0..N_NB - 1, 0..N_PREV - 1] of TAdaptiveBit;
    sign: TAdaptiveBit;
    sign4: array[0..2, 0..2, 0..3] of TAdaptiveBit;   { other channel's, value before's, magnitude }
    linLen: array[1..15] of TAdaptiveBit;      { a tree of 4 decisions }
    linLow: array[0..12] of TAdaptiveBit;
    c1Zero: array[0..N_NB - 1, 0..N_PREV - 1, 0..N_POS - 1] of TAdaptiveBit;
    prevVals: array[0..1] of TGranuleValues;
    lastQuads: array[0..1] of Integer;
    { version 4: the values' decisions, mixed }
    vt: TCounterTable;
    vmix: TMixer;
    lastGain: array[0..1] of Integer;
    curVals: array[0..1] of TGranuleValues;   { this granule's, for the other channel }
    smix: TMixer;
    vapm: TAPM;
    lastScf: array[0..1, 0..2, 0..63] of Integer;   { by channel, block kind, place }
    scf: array[0..1, 0..63] of Integer;             { the last granule's of each channel, whole }
    prevStep: array[0..1, 0..575] of Integer;
    { version 5: Layer I and II }
    lmix: TMixer;
    l12modelled, oddCode: TAdaptiveBit;
    lastL12: TL12Frame;
    hist: Integer;
    lastSlotBit: Int64;
    lastSi: TSideInfo;
    lastHeader: UInt32;
    lastFree: Integer;
    prevKind: Integer;
    procedure Init(isDecoding: Boolean);
    { codes bit b (encoding) or returns the decoded bit (decoding) }
    function Bit(b: Integer; var ab: TAdaptiveBit; limit: Integer): Integer; inline;
  end;
  PModel = ^TModel;

  { a run of Layer III frames of one stream, and its slot stream }
  TRun = record
    first: TMpegHeader;
    offs, cums: array of Int64;   { each frame's slots: where in the file, where in the slot stream }
    n, cursor: Integer;
    slotBytes: Int64;             { the slot stream's length so far }
    prevEnd: Int64;               { in bits: where the last mapped main data ended }
    procedure Start(const hd: TMpegHeader);
    procedure AddSlots(fileOffset, len: Int64);
  end;

procedure TModel.Init(isDecoding: Boolean);
var i, j, k, l: Integer;
begin
  decoding := isDecoding;
  for i := 0 to KIND_START do for j := 1 to 7 do kinds[i, j].Init;
  for i := 0 to 31 do for j := 0 to 1 do for k := 0 to 1 do header[i, j, k].Init;
  freeSame.Init;
  for i := 0 to 15 do freeBits[i].Init;
  for i := 1 to 63 do lenBits[i].Init;
  for i := 0 to 62 do lenLow[i].Init;
  for i := 0 to 1 do for j := 0 to 255 do for k := 1 to 255 do bytes[i, j, k].Init;
  for i := 0 to N_FIELDS - 1 do for j := 0 to 511 do for k := 0 to 1 do for l := 0 to 1 do
    fields[i, j, k, l].Init;
  crcOk.Init; runGoesOn.Init; mappedBit.Init; tailNone.Init;
  lastPart23[0] := 0; lastPart23[1] := 0;
  for i := 0 to 1 do for j := 0 to (1 shl HIST_BITS) - 1 do slot[i, j].Init;
  hist := 0; lastSlotBit := -2;
  modelled.Init; sign.Init;
  for i := 0 to 2 do for j := 0 to 2 do for k := 0 to 3 do sign4[i, j, k].Init;
  for i := 0 to N_CAP - 1 do for j := 0 to N_NB - 1 do for k := 0 to N_PREV - 1 do
  begin
    for l := 0 to N_POS - 1 do zero[i, j, k, l].Init;
    for l := 1 to 15 do gt[i, l, j, k].Init;
  end;
  for i := 1 to 15 do linLen[i].Init;
  for i := 0 to 12 do linLow[i].Init;
  for j := 0 to N_NB - 1 do for k := 0 to N_PREV - 1 do for l := 0 to N_POS - 1 do c1Zero[j, k, l].Init;
  FillChar(prevVals, SizeOf(prevVals), 0);
  lastQuads[0] := 0; lastQuads[1] := 0;
  vt.Init(V_TABLE_BITS);
  vmix.Init(V_INPUTS, 16 * EST_BUCKETS, V_MIX_RATE);
  smix.Init(S_INPUTS, 8, V_MIX_RATE);
  vapm.Init(16 * 8 * EST_BUCKETS, 7);
  FillChar(lastScf, SizeOf(lastScf), 0);
  FillChar(scf, SizeOf(scf), 0);
  FillChar(prevStep, SizeOf(prevStep), 0);
  lmix.Init(L_INPUTS, 32 + 4 * 32, V_MIX_RATE);
  l12modelled.Init; oddCode.Init;
  lastL12 := Default(TL12Frame);
  lastGain[0] := 0; lastGain[1] := 0;
  FillChar(curVals, SizeOf(curVals), 0);
  lastSi := Default(TSideInfo);
  lastHeader := 0; lastFree := 0; prevKind := KIND_START;
end;

{$ifdef PMPA_COSTS}
var CostPart: Integer = 0;
{$endif}

procedure Part(n: Integer); inline;
begin
  {$ifdef PMPA_COSTS} CostPart := n; {$endif}
end;

{ codes bit b (or decodes) at probability p16 = P(1) * 65536, 1..65535 }
function CodeP(var m: TModel; b, p16: Integer): Integer;
begin
  if m.decoding then Result := m.dec.Decode(p16)
  else begin
    m.enc.Encode(b, p16); Result := b;
    {$ifdef PMPA_COSTS}
    if b = 1 then Costs[CostPart] := Costs[CostPart] - Ln(p16 / 65536) / Ln(2)
    else Costs[CostPart] := Costs[CostPart] - Ln((65536 - p16) / 65536) / Ln(2);
    {$endif}
  end;
end;

function TModel.Bit(b: Integer; var ab: TAdaptiveBit; limit: Integer): Integer;
begin
  if decoding then Result := dec.Decode(ab.p)
  else begin
    enc.Encode(b, ab.p); Result := b;
    {$ifdef PMPA_COSTS}
    if b = 1 then Costs[CostPart] := Costs[CostPart] - Ln(Max(ab.p, 1) / 65536) / Ln(2)
    else Costs[CostPart] := Costs[CostPart] - Ln(Max(65536 - ab.p, 1) / 65536) / Ln(2);
    {$endif}
  end;
  ab.Update(Result, limit);
end;

procedure TRun.Start(const hd: TMpegHeader);
begin
  first := hd; n := 0; cursor := 0; slotBytes := 0; prevEnd := 0;
end;

procedure TRun.AddSlots(fileOffset, len: Int64);
begin
  if n = Length(offs) then
  begin
    SetLength(offs, 2 * n + 64);
    SetLength(cums, 2 * n + 64);
  end;
  offs[n] := fileOffset; cums[n] := slotBytes;
  Inc(n); Inc(slotBytes, len);
end;

{ ---------- the parts of a segment, the same code both ways ---------- }

function CodeKind(var m: TModel; kind: Integer): Integer;
var node, i: Integer;
begin
  node := 1;
  for i := 2 downto 0 do
    node := node * 2 + m.Bit((kind shr i) and 1, m.kinds[m.prevKind, node], LIMIT_STRUCT);
  Result := node - 8;
  if Result <= Ord(High(TSegmentKind)) then m.prevKind := Result;
end;

function CodeHeader(var m: TModel; h: UInt32): UInt32;
var i, b, same, last: Integer;
begin
  Result := 0; same := 1;
  for i := 31 downto 0 do
  begin
    last := (m.lastHeader shr i) and 1;
    b := m.Bit(Integer((h shr i) and 1), m.header[i, last, same], LIMIT_STRUCT);
    Result := Result or (UInt32(b) shl i);
    if b <> last then same := 0;
  end;
  m.lastHeader := Result;
end;

function CodeFree(var m: TModel; len: Integer): Integer;
var i, b: Integer;
begin
  b := 0;
  if not m.decoding then b := Ord(len = m.lastFree);
  if m.Bit(b, m.freeSame, LIMIT_STRUCT) = 1 then Exit(m.lastFree);
  Result := 0;
  for i := 15 downto 0 do
    Result := Result or (m.Bit((len shr i) and 1, m.freeBits[i], LIMIT_STRUCT) shl i);
  m.lastFree := Result;
end;

{ a length of at least 1: its bit length n (1 to 63), then its n - 1 low bits;
  -1 if a decoded bit length is 0 }
function CodeLength(var m: TModel; v: Int64): Int64;
var n, node, i: Integer;
begin
  n := 0;
  if not m.decoding then
    while (n < 63) and ((v shr n) > 0) do Inc(n);
  node := 1;
  for i := 5 downto 0 do
    node := node * 2 + m.Bit((n shr i) and 1, m.lenBits[node], LIMIT_STRUCT);
  n := node - 64;
  if n = 0 then Exit(-1);
  Result := 1;
  for i := n - 2 downto 0 do
    Result := Result * 2 + m.Bit(Integer((v shr i) and 1), m.lenLow[i], LIMIT_STRUCT);
end;

procedure CodeBytes(var m: TModel; var d: TBytes; first, len: Int64; cls: Integer);
var i: Int64; prev, node, k, x: Integer;
begin
  if first > 0 then prev := d[first - 1] else prev := 0;
  { a while loop: a 32-bit FreePascal has no Int64 loop counters }
  i := first;
  while i < first + len do
  begin
    x := d[i]; node := 1;
    for k := 7 downto 0 do
      node := node * 2 + m.Bit((x shr k) and 1, m.bytes[cls, prev * cls, node], LIMIT_BYTES);
    x := node - 256;
    d[i] := x;
    prev := x;
    Inc(i);
  end;
end;

{ ---------- Layer III ---------- }

{ a field of nbits, most significant bit first, each in the context of the
  bits so far (the top 8), of the same bit of prev and of whether the bits
  so far all matched prev }
function CodeField(var m: TModel; v, nbits, fid, prev: Integer): Integer;
var i, b, node, same, pb, ctx: Integer;
begin
  Part(10 + fid);
  Result := 0; node := 1; same := 1;
  for i := nbits - 1 downto 0 do
  begin
    pb := (prev shr i) and 1;
    if node < 256 then ctx := node else ctx := 256 + i;
    b := m.Bit((v shr i) and 1, m.fields[fid, ctx, pb, same], LIMIT_STRUCT);
    Result := Result * 2 + b;
    if node < 256 then node := node * 2 + b;
    if b <> pb then same := 0;
  end;
end;

procedure CodeSideInfo(var m: TModel; var si: TSideInfo; withPart23: Boolean);
var g, c, b, i: Integer; p: TGranuleInfo; last: TSideInfo;
begin
  last := m.lastSi;
  if si.lsf then
  begin
    si.mainDataBegin := CodeField(m, si.mainDataBegin, 8, F_MDB, last.mainDataBegin);
    si.privateBits := CodeField(m, si.privateBits, si.nCh, F_PRIV, last.privateBits);
  end
  else
  begin
    si.mainDataBegin := CodeField(m, si.mainDataBegin, 9, F_MDB, last.mainDataBegin);
    if si.nCh = 1 then si.privateBits := CodeField(m, si.privateBits, 5, F_PRIV, last.privateBits)
    else si.privateBits := CodeField(m, si.privateBits, 3, F_PRIV, last.privateBits);
    for c := 0 to si.nCh - 1 do
      for b := 0 to 3 do
        si.scfsi[c, b] := CodeField(m, si.scfsi[c, b], 1, F_SCFSI, last.scfsi[c, b]);
  end;
  for g := 0 to si.nGr - 1 do
    for c := 0 to si.nCh - 1 do
    begin
      { the same channel's granule before, in this frame or the last one }
      if g > 0 then p := si.gr[g - 1, c]
      else if (last.nGr > 0) and (c < last.nCh) then p := last.gr[last.nGr - 1, c]
      else p := Default(TGranuleInfo);
      with si.gr[g, c] do
      begin
        if withPart23 then part23 := CodeField(m, part23, 12, F_PART23, p.part23);
        bigValues := CodeField(m, bigValues, 9, F_BIGV, p.bigValues);
        globalGain := CodeField(m, globalGain, 8, F_GAIN, p.globalGain);
        if si.lsf then sfCompress := CodeField(m, sfCompress, 9, F_SFC, p.sfCompress)
        else sfCompress := CodeField(m, sfCompress, 4, F_SFC, p.sfCompress);
        winSwitch := CodeField(m, winSwitch, 1, F_WS, p.winSwitch);
        if winSwitch = 1 then
        begin
          blockType := CodeField(m, blockType, 2, F_BT, p.blockType);
          mixed := CodeField(m, mixed, 1, F_MIX, p.mixed);
          for i := 0 to 1 do table[i] := CodeField(m, table[i], 5, F_TAB + i, p.table[i]);
          for i := 0 to 2 do subGain[i] := CodeField(m, subGain[i], 3, F_SUBG, p.subGain[i]);
        end
        else
        begin
          for i := 0 to 2 do table[i] := CodeField(m, table[i], 5, F_TAB + i, p.table[i]);
          region0 := CodeField(m, region0, 4, F_R0, p.region0);
          region1 := CodeField(m, region1, 3, F_R1, p.region1);
        end;
        if not si.lsf then preflag := CodeField(m, preflag, 1, F_PRE, p.preflag);
        sfScale := CodeField(m, sfScale, 1, F_SFS, p.sfScale);
        count1Table := CodeField(m, count1Table, 1, F_C1, p.count1Table);
      end;
    end;
  m.lastSi := si;
end;

{ the byte of the file that holds byte idx of the slot stream }
function SlotByte(var run: TRun; idx: Int64): Int64;
var k: Integer;
begin
  k := run.cursor;
  while (k > 0) and (run.cums[k] > idx) do Dec(k);
  while (k + 1 < run.n) and (run.cums[k + 1] <= idx) do Inc(k);
  run.cursor := k;
  Result := run.offs[k] + idx - run.cums[k];
end;

{ n bits of the slot stream from bit a, packed from bit 0 of the result }
function GetSlotBits(const d: TBytes; var run: TRun; a: Int64; n: Integer): TBytes;
var j: Integer; bit: Int64;
begin
  Result := nil;
  SetLength(Result, n div 8 + 1);
  for j := 0 to n - 1 do
  begin
    bit := a + j;
    if ((d[SlotByte(run, bit shr 3)] shr (7 - Integer(bit and 7))) and 1) <> 0 then
      Result[j shr 3] := Result[j shr 3] or (1 shl (7 - (j and 7)));
  end;
end;

{ the first n bits of src into the slot stream from bit a (whose bits are 0) }
procedure PutSlotBits(var d: TBytes; var run: TRun; a: Int64; const src: TBytes; n: Integer);
var j: Integer; bit, at: Int64;
begin
  for j := 0 to n - 1 do
    if ((src[j shr 3] shr (7 - (j and 7))) and 1) <> 0 then
    begin
      bit := a + j;
      at := SlotByte(run, bit shr 3);
      d[at] := d[at] or (1 shl (7 - Integer(bit and 7)));
    end;
end;

{ the bits [a, b) of the run's slot stream, in the file's bytes }
procedure CodeSlotBits(var m: TModel; var d: TBytes; var run: TRun; a, b: Int64; cls: Integer);
var bit, idx, at: Int64; sh, v: Integer;
begin
  bit := a;
  while bit < b do
  begin
    idx := bit shr 3;
    at := SlotByte(run, idx);
    sh := 7 - Integer(bit and 7);
    v := (d[at] shr sh) and 1;
    { the bits of this slot-stream byte so far, as an order-0 byte model;
      afresh where the bits coded here jump (values modelled in between) }
    if (sh = 7) or (bit <> m.lastSlotBit + 1) then m.hist := 1;
    m.lastSlotBit := bit;
    v := m.Bit(v, m.slot[cls, m.hist], LIMIT_BYTES);
    if m.decoding and (v = 1) then d[at] := d[at] or (1 shl sh);
    m.hist := m.hist * 2 + v;
    Inc(bit);
  end;
end;

function NbBucket(n: Integer): Integer; inline;
begin
  if n < 3 then Result := n
  else if n < 5 then Result := 3
  else if n < 8 then Result := 4
  else if n < 13 then Result := 5
  else if n < 24 then Result := 6
  else Result := 7;
end;

function PrevBucket(n: Integer): Integer; inline;
begin
  if n < 3 then Result := n
  else if n < 5 then Result := 3
  else if n < 9 then Result := 4
  else Result := 5;
end;

function PosBucket(i: Integer): Integer; inline;
begin
  if i < 12 then Result := 0
  else if i < 36 then Result := 1
  else if i < 96 then Result := 2
  else if i < 192 then Result := 3
  else if i < 320 then Result := 4
  else Result := 5;
end;

{ a granule's values (one channel), the big values with their table's
  limit, the count1 values, zeros after; False if a table is one no
  stream uses (4, 14) }
function CodeValues(var m: TModel; var v: TGranuleValues; const gi: TGranuleInfo;
  const hd: TMpegHeader; quads, c: Integer): Boolean;
var
  r1, r2, i, t, cap, cls, lin, a, k, nb, pp, ps, e, n, node, bit: Integer;
begin
  Result := False;
  Regions(gi, hd, r1, r2);
  for i := 0 to 575 do
  begin
    if i < 2 * gi.bigValues then
    begin
      if i < r1 then t := gi.table[0]
      else if i < r2 then t := gi.table[1]
      else t := gi.table[2];
      if HUFF_OFFSET[t] = -2 then Exit;
      if HUFF_OFFSET[t] = -1 then begin v[i] := 0; Continue; end;
      lin := LINBITS[t];
      if lin > 0 then begin cap := 15; cls := 6; end
      else begin
        cap := HUFF_SIZE[t] - 1;
        case cap of 1: cls := 0; 2: cls := 1; 3: cls := 2; 5: cls := 3; 7: cls := 4; else cls := 5; end;
      end;
      nb := 0;
      if i > 0 then nb := 2 * Abs(v[i - 1]);
      if i > 1 then Inc(nb, Abs(v[i - 2]));
      nb := NbBucket(nb);
      pp := PrevBucket(Abs(m.prevVals[c][i]));
      ps := PosBucket(i);
      a := Abs(v[i]);
      Part(6);
      if m.Bit(Ord(a <> 0), m.zero[cls, nb, pp, ps], LIMIT_BYTES) = 0 then
      begin
        v[i] := 0;
        Continue;
      end;
      Part(7);
      k := 1;
      while (k < cap) and (m.Bit(Ord(a > k), m.gt[cls, k, nb, pp], LIMIT_BYTES) = 1) do Inc(k);
      if (lin > 0) and (k = 15) then
      begin
        { the escape: a - 15, its bit length and the bits below the top one }
        e := a - 15;
        n := 0;
        if not m.decoding then
          while (e shr n) > 0 do Inc(n);
        node := 1;
        for bit := 3 downto 0 do
          node := node * 2 + m.Bit((n shr bit) and 1, m.linLen[node], LIMIT_STRUCT);
        n := node - 16;
        if n > lin then Exit;
        if n = 0 then e := 0
        else
        begin
          e := 1;
          for bit := n - 2 downto 0 do
            e := e * 2 + m.Bit((a - 15) shr bit and 1, m.linLow[bit], LIMIT_BYTES);
        end;
        k := 15 + e;
      end;
      Part(8);
      if m.Bit(Ord(v[i] < 0), m.sign, LIMIT_BYTES) = 1 then v[i] := -k else v[i] := k;
    end
    else if i < 2 * gi.bigValues + 4 * quads then
    begin
      nb := 0;
      if i > 0 then nb := 2 * Abs(v[i - 1]);
      if i > 1 then Inc(nb, Abs(v[i - 2]));
      nb := NbBucket(nb);
      pp := PrevBucket(Abs(m.prevVals[c][i]));
      Part(6);
      if m.Bit(Ord(v[i] <> 0), m.c1Zero[nb, pp, PosBucket(i)], LIMIT_BYTES) = 0 then v[i] := 0
      else
      begin
        Part(8);
        if m.Bit(Ord(v[i] < 0), m.sign, LIMIT_BYTES) = 1 then v[i] := -1 else v[i] := 1;
      end;
    end
    else v[i] := 0;
  end;
  m.prevVals[c] := v;
  Result := True;
end;

{ one decision of a value, version 4: the counters of hs mixed, with the
  mixer's weights of `sel` }
function Decide(var m: TModel; var mx: TMixer; b: Integer; const hs: array of Cardinal; sel: Integer): Integer;
var j, p: Integer; cp: array[0..10] of PCounter;
begin
  for j := 0 to High(hs) do
  begin
    cp[j] := m.vt.At(hs[j]);
    mx.Add(St16(cp[j]^.p));
  end;
  mx.Add(256);
  p := mx.Mix(sel) * 16;
  if p < 1 then p := 1 else if p > 65535 then p := 65535;
  Result := CodeP(m, b, p);
  mx.Update(Result);
  for j := 0 to High(hs) do CounterUpdate(cp[j]^, Result, V_LIMIT);
end;

function Cap15(n: Integer): Integer; inline;
begin
  if n > 15 then Result := 15 else Result := n;
end;

{ 0, 1, 2, 3, 4-5, 6-7, 8-11, 12-15, 16-23, 24-31, 32-47, 48-63, 64-95, 96+ }
function EstBucket(n: Integer): Integer; inline;
var b: Integer;
begin
  if n < 4 then Exit(n);
  b := BitLen(n);                       { 3 for 4..7 }
  Result := 2 * b - 2 + ((n shr (b - 2)) and 1);
  if Result > 13 then Result := 13;
end;

{ 0 for 0, 1 for positive, 2 for negative }
function Sgn3(n: Integer): Integer; inline;
begin
  if n = 0 then Result := 0 else if n > 0 then Result := 1 else Result := 2;
end;

function Min3(n: Integer): Integer; inline;
begin
  if n > 3 then Result := 3 else Result := n;
end;

function Min7(n: Integer): Integer; inline;
begin
  if n > 7 then Result := 7 else Result := n;
end;

{ Decide, then refined by the APM in context actx; the two averaged }
function DecideApm(var m: TModel; b: Integer; const hs: array of Cardinal; sel, actx: Integer): Integer;
var j, p, pa: Integer; cp: array[0..10] of PCounter;
begin
  for j := 0 to High(hs) do
  begin
    cp[j] := m.vt.At(hs[j]);
    m.vmix.Add(St16(cp[j]^.p));
  end;
  m.vmix.Add(256);
  p := m.vmix.Mix(sel);
  pa := m.vapm.Refine(p, actx);
  p := (p + 3 * pa) * 4;
  if p < 1 then p := 1 else if p > 65535 then p := 65535;
  Result := CodeP(m, b, p);
  m.vmix.Update(Result);
  m.vapm.Update(Result);
  for j := 0 to High(hs) do CounterUpdate(cp[j]^, Result, V_LIMIT);
end;

{ n bytes of the encoder's output, as TArithEncoder.Encode writes them }
procedure PutEncoded(var e: TArithEncoder; b: PByte; n: SizeInt);
var i: SizeInt;
begin
  if e.live <> nil then
    for i := 0 to n - 1 do e.live.Put(b[i])
  else
  begin
    if e.n + n > Length(e.d) then SetLength(e.d, 2 * Length(e.d) + n + 4096);
    Move(b^, e.d[e.n], n);
  end;
  Inc(e.n, n);
end;

{ version 6's values through pmpal3c.c: the same as CodeValues4, which
  prepares what C needs and keeps what comes after }
function CodeValuesC(var m: TModel; var v: TGranuleValues; const gi: TGranuleInfo;
  const hd: TMpegHeader; quads, c: Integer; const steps: array of Integer): Boolean;
var
  r1, r2, i, t, cap: Integer; capA, clsA, linA: array[0..575] of ShortInt;
  a: TValuesC; e: TEncC; dc: TDecC; ok: LongInt;
begin
  Result := False;
  Regions(gi, hd, r1, r2);
  for i := 0 to 575 do
  begin
    capA[i] := 1; clsA[i] := 7; linA[i] := 0;      { count1 }
    if i < 2 * gi.bigValues then
    begin
      if i < r1 then t := gi.table[0]
      else if i < r2 then t := gi.table[1]
      else t := gi.table[2];
      if HUFF_OFFSET[t] = -2 then Exit;
      if HUFF_OFFSET[t] = -1 then clsA[i] := -1
      else if LINBITS[t] > 0 then begin capA[i] := 15; clsA[i] := 6; linA[i] := LINBITS[t]; end
      else
      begin
        cap := HUFF_SIZE[t] - 1;
        capA[i] := cap;
        case cap of 1: clsA[i] := 0; 2: clsA[i] := 1; 3: clsA[i] := 2; 5: clsA[i] := 3; 7: clsA[i] := 4; else clsA[i] := 5; end;
      end;
    end;
  end;
  a := Default(TValuesC);
  a.v := @v[0]; a.pv := @m.prevVals[c][0];
  if c = 1 then a.ov := @m.curVals[0][0] else a.ov := nil;
  a.steps := @steps[0]; a.prevStep := @m.prevStep[c, 0];
  a.cap := @capA[0]; a.cls := @clsA[0]; a.lin := @linA[0];
  a.bigEnd := 2 * gi.bigValues; a.endAt := 2 * gi.bigValues + 4 * quads;
  a.dg := gi.globalGain - m.lastGain[c];
  if a.dg < -4 then a.dg := -4 else if a.dg > 4 then a.dg := 4;
  Inc(a.dg, 4);
  a.vt := @m.vt.c[0]; a.vtMask := Cardinal(m.vt.mask);
  a.w := @m.vmix.w[0]; a.inputs := m.vmix.inputs; a.rate := m.vmix.rate;
  a.apm := @m.vapm.t[0]; a.apmRate := m.vapm.rate;
  a.sign4 := @m.sign4[0, 0, 0]; a.linLen := @m.linLen[1]; a.linLow := @m.linLow[0];
  a.decoding := Ord(m.decoding);
  if m.decoding then
  begin
    dc.x1 := m.dec.x1; dc.x2 := m.dec.x2; dc.x := m.dec.x;
    if Length(m.dec.d) > 0 then dc.d := @m.dec.d[0] else dc.d := nil;
    dc.len := Length(m.dec.d); dc.p := m.dec.p; dc.live := Pointer(m.dec.live);
    a.dec := @dc;
    ok := ValuesC(a);
    m.dec.x1 := dc.x1; m.dec.x2 := dc.x2; m.dec.x := dc.x; m.dec.p := dc.p;
  end
  else
  begin
    e.x1 := m.enc.x1; e.x2 := m.enc.x2; e.ctx := @m.enc; e.n := 0;
    a.enc := @e;
    ok := ValuesC(a);
    m.enc.x1 := e.x1; m.enc.x2 := e.x2;
    if e.n > 0 then PutEncoded(m.enc, @e.buf[0], e.n);
  end;
  if ok = 0 then Exit;
  m.prevVals[c] := v;
  m.curVals[c] := v;
  m.lastGain[c] := gi.globalGain;
  for i := 0 to 575 do m.prevStep[c, i] := steps[i];
  Result := True;
end;

{ version 4's values: each decision (zero or not, greater than k) mixes six
  contexts: the two values before; the same value's neighbourhood in the
  granule before; the position; the other channel's value in this
  granule; the change of global gain; the position coarsely with the
  neighbours. }
function CodeValues4(var m: TModel; var v: TGranuleValues; const gi: TGranuleInfo;
  const hd: TMpegHeader; quads, c, nCh: Integer): Boolean;
var
  r1, r2, i, t, cap, cls, lin, a, k, e, n, node, bit, n1, n2, pn, p0, oc, dg, pos, nbb: Integer;
  hs: array[0..9] of Cardinal; base, hs6: array[0..7] of Cardinal; pv, ov: ^TGranuleValues;
  dist, est, maxL, L: Integer;
  place, win: TValuePlaces; mult, sf, step, ds, sa, so, sb: Integer; steps: array[0..575] of Integer;

  { one decision: `id` (0 zero, 1-3 the bit length, 4-9 the bits below
    the top one), `prefix` the bits decided so far }
  function D(id, prefix, bitv: Integer): Integer;
  var key, slot, j{$ifdef PMPA_COSTS}, k2{$endif}: Integer;
  begin
    if m.ver >= 6 then
    begin
      { version 6: each context's decisions of one value share a line of
        16 counters (the 15 there can be), from hashes made once a value }
      case id of
        0..5: slot := id;
        6: slot := 6 + prefix - 2;
        7: slot := 8;
        8: slot := 9 + prefix - 2;
      else slot := 11 + prefix - 4;
      end;
      for j := 0 to 7 do hs6[j] := (base[j] and $FFFFFFF0) or Cardinal(slot);
      {$ifdef PMPA_COSTS}
      for k2 := 0 to 7 do if (DropInput shr k2) and 1 = 1 then hs6[k2] := Cardinal(slot);
      {$endif}
      if id = 0 then Part(6) else Part(7);
      Exit(DecideApm(m, bitv, hs6, id * 8 + cls, (id * 8 + cls) * EST_BUCKETS + est));
    end;
    key := id * 8 + prefix;
    hs[0] := Hash4(1, key * 8 + cls, n1, n2);
    hs[1] := Hash4(2, key * 8 + cls, pn, nbb);
    hs[2] := Hash3(3, key * 8 + cls, pos);
    hs[3] := Hash4(4, key * 8 + cls, oc, Min3(n1));
    hs[4] := Hash4(5, key * 8 + cls, dg * 16 + Min7(p0), Min3(n1));
    hs[5] := Hash4(6, key * 8 + cls, pos shr 2, Min3(n1) * 4 + Min3(p0));
    hs[6] := Hash4(7, key * 8 + cls, ds, Min3(p0) * 4 + Min3(n1));
    hs[7] := Hash4(8, key * 8 + cls, sa, pos shr 3);
    hs[8] := Hash4(9, key * 8 + cls, dist, Min3(n1) * 4 + Min3(p0));
    hs[9] := Hash3(14, key * 8 + cls, est);
    if id = 0 then Part(6) else Part(7);
    Result := DecideApm(m, bitv, hs, id * 8 + cls, (id * 8 + cls) * EST_BUCKETS + est);
  end;

begin
  Result := False;
  Regions(gi, hd, r1, r2);
  pv := @m.prevVals[c];
  if (c = 1) then ov := @m.curVals[0] else ov := nil;
  dg := gi.globalGain - m.lastGain[c];
  if dg < -4 then dg := -4 else if dg > 4 then dg := 4;
  Inc(dg, 4);
  { each value's quantization step, in quarters of the scale's log2: the
    global gain less the band's scalefactor (and the window's gain) }
  ValuePlaces(gi, hd, place, win);
  if gi.sfScale = 0 then mult := 2 else mult := 4;
  for i := 0 to 575 do
  begin
    if place[i] >= 0 then sf := m.scf[c, place[i]] else sf := 0;
    if (gi.preflag = 1) and ((gi.winSwitch = 0) or (gi.blockType <> 2)) and (place[i] >= 0) then
      Inc(sf, PRETAB[place[i]]);
    step := gi.globalGain - mult * sf;
    if (gi.winSwitch = 1) and (gi.blockType = 2) then Dec(step, 8 * gi.subGain[win[i]]);
    steps[i] := step;
  end;
  {$ifndef PMPA_COSTS}
  if (m.ver >= 6) and Assigned(ValuesC) then
    Exit(CodeValuesC(m, v, gi, hd, quads, c, steps));
  {$endif}
  for i := 0 to 575 do
  begin
    if i >= 2 * gi.bigValues + 4 * quads then begin v[i] := 0; Continue; end;
    if i < 2 * gi.bigValues then
    begin
      if i < r1 then t := gi.table[0]
      else if i < r2 then t := gi.table[1]
      else t := gi.table[2];
      if HUFF_OFFSET[t] = -2 then Exit;
      if HUFF_OFFSET[t] = -1 then begin v[i] := 0; Continue; end;
      lin := LINBITS[t];
      if lin > 0 then begin cap := 15; cls := 6; end
      else begin
        cap := HUFF_SIZE[t] - 1;
        case cap of 1: cls := 0; 2: cls := 1; 3: cls := 2; 5: cls := 3; 7: cls := 4; else cls := 5; end;
      end;
    end
    else begin cap := 1; cls := 7; lin := 0; end;      { count1 }
    n1 := 0; n2 := 0;
    if i > 0 then n1 := Cap15(Abs(v[i - 1]));
    if i > 1 then n2 := Cap15(Abs(v[i - 2]));
    p0 := Cap15(Abs(pv^[i]));
    pn := 2 * p0;
    if i > 0 then Inc(pn, Cap15(Abs(pv^[i - 1])));
    if i < 575 then Inc(pn, Cap15(Abs(pv^[i + 1])));
    if pn > 31 then pn := 31;
    if ov <> nil then oc := Cap15(Abs(ov^[i])) else oc := 16;
    pos := i shr 2;
    nbb := NbBucket(2 * n1 + n2);
    ds := steps[i] - m.prevStep[c, i];
    if ds < -8 then ds := -8 else if ds > 8 then ds := 8;
    Inc(ds, 8);
    sa := steps[i] div 4;
    if sa < 0 then sa := 0 else if sa > 63 then sa := 63;
    { how far the region's end is: the big values', or the count1 part's }
    if i < 2 * gi.bigValues then dist := 2 * gi.bigValues - i else dist := 2 * gi.bigValues + 4 * quads - i;
    dist := BitLen(dist);
    { the magnitude the neighbours suggest, on a log scale: the two values
      before, the same place and its neighbours in the granule before, the
      other channel }
    est := 4 * n1 + 2 * n2 + 3 * p0;
    if i > 0 then Inc(est, Cap15(Abs(pv^[i - 1])));
    if i < 575 then Inc(est, Cap15(Abs(pv^[i + 1])));
    if oc < 16 then Inc(est, 2 * oc);
    est := EstBucket(est);
    a := Abs(v[i]);
    if m.ver >= 6 then
    begin
      { version 3 to 5's contexts but the coarse position with the
        neighbours and the magnitude estimate (the estimate still picks
        the APM's context): without those two the files were a little
        smaller; without four, 0.13 points bigger (measured 01/11/2026) }
      base[0] := Hash4(1, cls, n1, n2);
      base[1] := Hash4(2, cls, pn, nbb);
      base[2] := Hash3(3, cls, pos);
      base[3] := Hash4(4, cls, oc, Min3(n1));
      base[4] := Hash4(5, cls, dg * 16 + Min7(p0), Min3(n1));
      base[5] := Hash4(7, cls, ds, Min3(p0) * 4 + Min3(n1));
      base[6] := Hash4(8, cls, sa, pos shr 3);
      base[7] := Hash4(9, cls, dist, Min3(n1) * 4 + Min3(p0));
    end;
    { zero or not; the bit length (1 to 4: up to 15) as "longer than L";
      the bits below the top one, each knowing those above it }
    if D(0, 0, Ord(a > 0)) = 0 then k := 0
    else
    begin
      maxL := BitLen(cap);
      L := 1;
      while (L < maxL) and (D(L, 0, Ord(BitLen(Cap15(a)) > L)) = 1) do Inc(L);
      k := 1;
      for bit := L - 2 downto 0 do
        k := k * 2 + D(4 + (L - 2) * (L - 1) div 2 + (L - 2 - bit), k, (Cap15(a) shr bit) and 1);
      if k > cap then Exit;
    end;
    if (lin > 0) and (k = 15) then
    begin
      Part(7);
      e := a - 15;
      n := 0;
      if not m.decoding then
        while (e shr n) > 0 do Inc(n);
      node := 1;
      for bit := 3 downto 0 do
        node := node * 2 + m.Bit((n shr bit) and 1, m.linLen[node], LIMIT_STRUCT);
      n := node - 16;
      if n > lin then Exit;
      if n = 0 then e := 0
      else
      begin
        e := 1;
        for bit := n - 2 downto 0 do
          e := e * 2 + m.Bit((a - 15) shr bit and 1, m.linLow[bit], LIMIT_BYTES);
      end;
      k := 15 + e;
    end;
    if k = 0 then v[i] := 0
    else
    begin
      { the sign, by the other channel's at this place and the value
        before's (each none, + or -) and the magnitude }
      Part(8);
      if ov = nil then so := 0 else so := Sgn3(ov^[i]);
      if i > 0 then sb := Sgn3(v[i - 1]) else sb := 0;
      if m.Bit(Ord(v[i] < 0), m.sign4[so, sb, Min3(k)], LIMIT_BYTES) = 1 then v[i] := -k else v[i] := k;
    end;
  end;
  m.prevVals[c] := v;
  m.curVals[c] := v;
  m.lastGain[c] := gi.globalGain;
  for i := 0 to 575 do m.prevStep[c, i] := steps[i];
  Result := True;
end;



{ one scalefactor of `width` bits, most significant first: each bit mixes
  its place, the same place in the last granule of this kind and channel
  (ps), the scalefactor sent before it (pq) and the other channel's at the
  same place (po) }
function CodeScf(var m: TModel; v, width, kind, place, ps, pq, po: Integer): Integer;
var bit, node: Integer; hs: array[0..3] of Cardinal;
begin
  node := 1;
  for bit := width - 1 downto 0 do
  begin
    hs[0] := Hash4(10, kind * 64 + place, width, node);
    hs[1] := Hash4(11, width * 1024 + node, ps + 1, kind);
    hs[2] := Hash4(12, kind * 64 + place, node, pq + 1);
    hs[3] := Hash4(13, width * 1024 + node, po + 1, ps + 1);
    node := node * 2 + Decide(m, m.smix, (v shr bit) and 1, hs, Min7(width));
  end;
  Result := node - (1 shl width);
end;

{ version 4's scalefactors: read from (or written to) the slot stream at bit
  b, p2 bits, and coded as values; m.scf[c] becomes the granule's whole set
  (what scfsi did not send is the granule before's) }
procedure CodeScalefactors(var m: TModel; var d: TBytes; var run: TRun; const si: TSideInfo;
  g, c: Integer; b: Int64; p2: Integer; const hd: TMpegHeader);
var
  L: TScfLayout; bits: TBytes; r: TBitReader; w: TBitWriter; j, val, pq, po: Integer;
  full: array[0..63] of Integer;
begin
  ScfLayout(si, g, c, hd, L);
  for j := 0 to 63 do full[j] := m.scf[c, j];
  if not m.decoding then
  begin
    bits := GetSlotBits(d, run, b, p2);
    r.Init(bits, 0, Length(bits));
  end;
  w.Init(p2 div 8 + 1);
  pq := -1;
  for j := 0 to L.n - 1 do
  begin
    val := 0;
    if L.width[j] > 0 then
    begin
      if not m.decoding then val := Integer(r.Get(L.width[j]));
      if (c = 1) and (si.nCh = 2) then po := m.scf[0, L.place[j]] else po := -1;
      val := CodeScf(m, val, L.width[j], L.kind, L.place[j], m.lastScf[c, L.kind, L.place[j]], pq, po);
      w.Put(Cardinal(val), L.width[j]);
    end;
    full[L.place[j]] := val;
    m.lastScf[c, L.kind, L.place[j]] := val;
    pq := val;
  end;
  if m.decoding then PutSlotBits(d, run, b, w.d, p2);
  for j := 0 to 63 do m.scf[c, j] := full[j];
end;

{ granule g, channel c's main data, from bit b of the slot stream }
function CodeGranule(var m: TModel; var d: TBytes; var run: TRun; const si: TSideInfo;
  g, c: Integer; b: Int64; const hd: TMpegHeader; ver: Integer): Boolean;
var
  p23, p2, p3, quads, tail, j, L: Integer; bits: TBytes; w: TBitWriter;
  v: TGranuleValues; ok: Boolean;
begin
  Result := False;
  p23 := si.gr[g, c].part23;
  p2 := Part2Bits(si, g, c, hd);
  if p2 > p23 then
  begin
    Part(5);
    CodeSlotBits(m, d, run, b, b + p23, 0);
    Exit(True);
  end;
  Part(4);
  if ver >= 4 then CodeScalefactors(m, d, run, si, g, c, b, p2, hd)
  else CodeSlotBits(m, d, run, b, b + p2, 0);       { as bits }
  p3 := p23 - p2;
  ok := False; quads := 0; tail := 0;
  FillChar(v, SizeOf(v), 0);
  if not m.decoding then
  begin
    bits := GetSlotBits(d, run, b + p2, p3);
    ok := DecodeValues(bits, 0, p3, si.gr[g, c], hd, v, quads, tail);
    if ok then
    begin
      { it has to come back exactly, or it is kept as bits }
      w.Init(p3 div 8 + 1);
      ok := EncodeValues(v, quads, si.gr[g, c], hd, w) and (w.pos = p3 - tail);
      if ok then
        for j := 0 to p3 - tail - 1 do
          if ((w.d[j shr 3] xor bits[j shr 3]) shr (7 - (j and 7)) and 1) <> 0 then ok := False;
    end;
  end;
  Part(0);
  if m.Bit(Ord(ok), m.modelled, LIMIT_STRUCT) = 0 then
  begin
    Part(5);
    CodeSlotBits(m, d, run, b + p2, b + p23, 0);
    Exit(True);
  end;
  quads := CodeField(m, quads, 8, F_QUADS, m.lastQuads[c]);
  m.lastQuads[c] := quads;
  if ver >= 4 then
  begin
    if not CodeValues4(m, v, si.gr[g, c], hd, quads, c, si.nCh) then Exit;
  end
  else if not CodeValues(m, v, si.gr[g, c], hd, quads, c) then Exit;
  if m.decoding then
  begin
    w.Init(p3 div 8 + 1);
    if not EncodeValues(v, quads, si.gr[g, c], hd, w) then Exit;
    L := Integer(w.pos);
    if L > p3 then Exit;
    PutSlotBits(d, run, b + p2, w.d, L);
  end
  else L := p3 - tail;
  { the tail, as bits }
  Part(9);
  CodeSlotBits(m, d, run, b + p2 + L, b + p23, 1);
  Result := True;
end;

{ version 4: granule g, channel c's main data from bit b, and its part23,
  which the side information did not carry: a modelled granule's is its
  scalefactors, its values coded again and its tail; another's is given.
  False if the stream is damaged. }
function CodeGranule4(var m: TModel; var d: TBytes; var run: TRun; var si: TSideInfo;
  g, c: Integer; b: Int64; const hd: TMpegHeader): Boolean;
var
  p23, p2, p3, quads, tail, j, L, pq: Integer; bits: TBytes; w: TBitWriter;
  v: TGranuleValues; ok: Boolean; slotEnd: Int64;
begin
  Result := False;
  slotEnd := run.slotBytes * 8;
  p23 := si.gr[g, c].part23;
  p2 := Part2Bits(si, g, c, hd);
  ok := False; quads := 0; tail := 0;
  FillChar(v, SizeOf(v), 0);
  if not m.decoding and (p2 <= p23) then
  begin
    p3 := p23 - p2;
    bits := GetSlotBits(d, run, b + p2, p3);
    ok := DecodeValues(bits, 0, p3, si.gr[g, c], hd, v, quads, tail);
    if ok then
    begin
      { it has to come back exactly, or it is kept as bits }
      w.Init(p3 div 8 + 1);
      ok := EncodeValues(v, quads, si.gr[g, c], hd, w) and (w.pos = p3 - tail);
      if ok then
        for j := 0 to p3 - tail - 1 do
          if ((w.d[j shr 3] xor bits[j shr 3]) shr (7 - (j and 7)) and 1) <> 0 then ok := False;
    end;
  end;
  Part(0);
  if m.Bit(Ord(ok), m.modelled, LIMIT_STRUCT) = 0 then
  begin
    p23 := CodeField(m, p23, 12, F_PART23, m.lastPart23[c]);
    m.lastPart23[c] := p23;
    if b + p23 > slotEnd then Exit;
    si.gr[g, c].part23 := p23;
    Part(5);
    CodeSlotBits(m, d, run, b, b + p23, 0);
    Exit(True);
  end;
  if b + p2 > slotEnd then Exit;
  Part(4);
  CodeScalefactors(m, d, run, si, g, c, b, p2, hd);
  { the quadruples, predicted from where the last granule's values ended }
  pq := (m.lastQuads[c] - 2 * si.gr[g, c].bigValues) div 4;
  if pq < 0 then pq := 0 else if pq > 255 then pq := 255;
  quads := CodeField(m, quads, 8, F_QUADS, pq);
  m.lastQuads[c] := 2 * si.gr[g, c].bigValues + 4 * quads;
  if not CodeValues4(m, v, si.gr[g, c], hd, quads, c, si.nCh) then Exit;
  w.Init(64);
  if not EncodeValues(v, quads, si.gr[g, c], hd, w) then Exit;
  L := Integer(w.pos);
  { the tail's length: none, or 12 bits }
  if m.Bit(Ord(tail = 0), m.tailNone, LIMIT_STRUCT) = 0 then
    tail := CodeField(m, tail, 12, F_TAIL, 0)
  else tail := 0;
  p23 := p2 + L + tail;
  if (p23 > 4095) or (b + p23 > slotEnd) then Exit;
  si.gr[g, c].part23 := p23;
  m.lastPart23[c] := p23;
  if m.decoding then PutSlotBits(d, run, b + p2, w.d, L);
  Part(9);
  CodeSlotBits(m, d, run, b + p2 + L, b + p23, 1);
  Result := True;
end;

{ a frame's CRC, once its header and side information are in d: one
  decision when it is the one they give, else its 16 bits }
procedure CodeCrc(var m: TModel; var d: TBytes; pos, siAt: Int64; const hd: TMpegHeader; bits: Integer = -1);
var crc, stored, ok: Integer;
begin
  if not hd.hasCrc then Exit;
  Part(2);
  if bits < 0 then bits := hd.sideInfoBytes * 8;
  crc := MpegCrc(HeaderAt(d, pos), d, siAt, bits);
  stored := (d[pos + 4] shl 8) or d[pos + 5];
  ok := m.Bit(Ord(stored = crc), m.crcOk, LIMIT_STRUCT);
  if ok = 1 then stored := crc
  else stored := CodeField(m, stored, 16, F_CRC, crc);
  d[pos + 4] := stored shr 8; d[pos + 5] := stored and $FF;
end;

{ ---------- Layer I and II (version 5) ---------- }

{ the bits [a, b) of the file from its byte `first`, as CodeSlotBits codes
  the slot stream's: in the context of their byte's bits so far }
procedure CodeFrameBits(var m: TModel; var d: TBytes; first, a, b: Int64; cls: Integer);
var bit, at: Int64; sh, v: Integer;
begin
  bit := a;
  while bit < b do
  begin
    at := first + bit shr 3;
    sh := 7 - Integer(bit and 7);
    if (sh = 7) or (bit = a) then m.hist := 1;
    v := (d[at] shr sh) and 1;
    v := m.Bit(v, m.slot[cls, m.hist], LIMIT_BYTES);
    if m.decoding and (v = 1) then d[at] := d[at] or (1 shl sh);
    m.hist := m.hist * 2 + v;
    Inc(bit);
  end;
  m.lastSlotBit := -2;
end;

{ a value of n bits (n <= 16), most significant first, each bit mixing the
  contexts c0..c4 (with what is decided so far) and the mixer's set `sel` }
function CodeL12Value(var m: TModel; v, n, sel: Integer; c0, c1, c2, c3, c4: Cardinal): Integer;
var bit, node: Integer; hs: array[0..5] of Cardinal;
begin
  node := 1;
  for bit := n - 1 downto 0 do
  begin
    hs[0] := Hash3(c0, node, 1);
    hs[1] := Hash3(c1, node, 2);
    hs[2] := Hash3(c2, node, 3);
    hs[3] := Hash3(c3, node, 4);
    hs[4] := Hash3(c4, node, 5);
    hs[5] := Hash3(sel, node, 6);
    node := node * 2 + Decide(m, m.lmix, (v shr bit) and 1, hs, sel);
    if node >= 1 shl 16 then node := node and $FFFF or $10000;
  end;
  Result := node - (1 shl n);
end;

{ a sample, centred: zero or not, the sign, the magnitude's bit length and
  the bits below its top one; `top` the largest magnitude there can be.
  Each decision mixes the contexts c0..c4 (with the decision and what is
  decided so far), with the mixer's set of the class and the decision. }
function CodeSample(var m: TModel; x, top, cls: Integer; c0, c1, c2, c3, c4: Cardinal): Integer;
var a, L, maxL, bit, k, sg: Integer; hs: array[0..5] of Cardinal;

  function D(id, prefix, b: Integer): Integer;
  var key: Cardinal;
  begin
    if m.ver >= 6 then
    begin
      { version 6: the contexts' hashes made once a sample, the decision
        mixed in by one multiplication (in 64 bits: no overflow) }
      key := Cardinal((QWord(id * 256 + prefix + 1) * $9E3779B1) and $FFFFFFFF);
      hs[0] := c0 xor key; hs[1] := c1 xor key; hs[2] := c2 xor key;
      hs[3] := c3 xor key; hs[4] := c4 xor key; hs[5] := Cardinal(cls) * 7919 xor key;
      if id > 3 then id := 3;
      Exit(Decide(m, m.lmix, b, hs, 32 + cls * 4 + id));
    end;
    hs[0] := Hash4(c0, id, prefix, 11);
    hs[1] := Hash4(c1, id, prefix, 12);
    hs[2] := Hash4(c2, id, prefix, 13);
    hs[3] := Hash4(c3, id, prefix, 14);
    hs[4] := Hash4(c4, id, prefix, 15);
    hs[5] := Hash4(cls, id, prefix, 16);
    if id > 3 then id := 3;
    Result := Decide(m, m.lmix, b, hs, 32 + cls * 4 + id);
  end;

begin
  a := Abs(x);
  Part(6);
  if D(0, 0, Ord(a > 0)) = 0 then Exit(0);
  Part(8);
  sg := D(1, 0, Ord(x < 0));
  Part(7);
  maxL := BitLen(top);
  L := 1;
  while (L < maxL) and (D(2, L, Ord(BitLen(a) > L)) = 1) do Inc(L);
  k := 1;
  for bit := L - 2 downto 0 do
    k := k * 2 + D(3 + L, k and 255, (a shr bit) and 1);
  if sg = 1 then Result := -k else Result := k;
end;

{ a signed value on a signed log scale: 0, +-1, +-2, +-3..4, +-5..8, ...,
  as 0..16 }
function SLog(v: Integer): Integer;
var b: Integer;
begin
  if v = 0 then Exit(8);
  b := BitLen(Abs(v) - 1) + 1;            { 1 for 1, 2 for 2, 3 for 3-4, 4 for 5-8 }
  if b > 8 then b := 8;
  if v > 0 then Result := 8 + b else Result := 8 - b;
end;

{ every field of a Layer I or II frame; decoding fills f }
function CodeL12Fields(var m: TModel; var f: TL12Frame; const hd: TMpegHeader): Boolean;
var
  sb, ch, chs, i, nb, n, mid, top, x, ci, prev, other, near, x1, x2, xo: Integer; q: TQClass;
  last: ^TL12Frame; lc: Integer;

  { the centre of channel c's samples in subband sb }
  function MidOf(c: Integer): Integer;
  var qq: TQClass;
  begin
    if f.layer = 1 then Result := (1 shl f.alloc[c, sb]) - 1
    else
    begin
      qq := QClass(f.table, sb, f.alloc[c, sb]);
      if qq.levels > 0 then Result := (qq.levels - 1) div 2 else Result := (1 shl (qq.bits - 1)) - 1;
    end;
  end;

  { the sample k before sample i of (ch, sb), centred: from this frame, or
    the last frame's end (already centred there); 0 if there is none }
  function Before(k: Integer): Integer;
  begin
    if i - k >= 0 then
    begin
      if f.smp[ch, sb, i - k] < 0 then Result := 0 else Result := f.smp[ch, sb, i - k] - mid;
    end
    else if last^.alloc[ch, sb] <> 0 then Result := last^.smp[ch, sb, n + i - k]
    else Result := 0;
  end;

begin
  Result := False;
  last := @m.lastL12;
  lc := f.layer * 8 + (f.table + 1);
  { the allocation }
  Part(32);
  for sb := 0 to f.sblimit - 1 do
  begin
    if sb < f.bound then chs := f.nch else chs := 1;
    if f.layer = 1 then nb := 4 else nb := AllocBits(f.table, sb);
    for ch := 0 to chs - 1 do
    begin
      prev := last^.alloc[ch, sb];
      if sb > 0 then near := f.alloc[ch, sb - 1] else near := 99;
      if ch = 1 then other := f.alloc[0, sb] else other := 99;
      f.alloc[ch, sb] := CodeL12Value(m, f.alloc[ch, sb], nb, 0,
        Hash3(lc, sb, prev), Hash3(lc, sb, near), Hash3(lc, sb, other),
        Hash4(lc, prev, near, other), Hash3(lc, sb, 0));
      if f.layer = 1 then begin if f.alloc[ch, sb] = 15 then Exit; end
      else if (f.alloc[ch, sb] <> 0) and (QClass(f.table, sb, f.alloc[ch, sb]).levels < 0) then Exit;
    end;
    if chs < f.nch then f.alloc[1, sb] := f.alloc[0, sb];
  end;
  { scfsi }
  if f.layer = 2 then
    for sb := 0 to f.sblimit - 1 do
      for ch := 0 to f.nch - 1 do
        if f.alloc[ch, sb] <> 0 then
        begin
          if sb > 0 then near := f.scfsi[ch, sb - 1] else near := 9;
          f.scfsi[ch, sb] := CodeL12Value(m, f.scfsi[ch, sb], 2, 1,
            Hash3(lc, sb, last^.scfsi[ch, sb]), Hash3(lc, sb, near), Hash3(lc, 100 + ch, near),
            Hash4(lc, last^.scfsi[ch, sb], near, f.alloc[ch, sb]), Hash3(lc, sb, f.alloc[ch, sb]));
        end;
  { the scale factors: the ones each scfsi sends }
  Part(4);
  for sb := 0 to f.sblimit - 1 do
    for ch := 0 to f.nch - 1 do
      if f.alloc[ch, sb] <> 0 then
      begin
        if f.layer = 1 then n := 1 else n := 3;
        for i := 0 to n - 1 do
        begin
          if f.layer = 2 then
            case f.scfsi[ch, sb] of
              1: if i = 1 then begin f.scf[ch, sb, 1] := f.scf[ch, sb, 0]; Continue; end;
              2: if i > 0 then begin f.scf[ch, sb, i] := f.scf[ch, sb, 0]; Continue; end;
              3: if i = 2 then begin f.scf[ch, sb, 2] := f.scf[ch, sb, 1]; Continue; end;
            end;
          if i > 0 then near := f.scf[ch, sb, i - 1]
          else if last^.alloc[ch, sb] <> 0 then near := last^.scf[ch, sb, 2]
          else near := 99;
          if sb > 0 then prev := f.scf[ch, sb - 1, i] else prev := 99;
          if (ch = 1) and (f.alloc[0, sb] <> 0) then other := f.scf[0, sb, i] else other := 99;
          f.scf[ch, sb, i] := CodeL12Value(m, f.scf[ch, sb, i], 6, 2,
            Hash3(lc, sb, near), Hash3(lc, prev, near), Hash3(lc, sb, other),
            Hash4(lc, near, other, i), Hash4(lc, sb, prev, i));
        end;
      end;
  { the samples, subband by subband, in time order }
  for sb := 0 to f.sblimit - 1 do
  begin
    if sb < f.bound then chs := f.nch else chs := 1;
    for ch := 0 to chs - 1 do
    begin
      if f.alloc[ch, sb] = 0 then Continue;
      if f.layer = 1 then
      begin
        n := 12; nb := f.alloc[ch, sb] + 1; mid := (1 shl (nb - 1)) - 1; top := mid + 1; ci := 15 + nb;
      end
      else
      begin
        n := 36;
        q := QClass(f.table, sb, f.alloc[ch, sb]);
        if q.levels > 0 then begin mid := (q.levels - 1) div 2; top := mid; ci := q.levels div 4; end
        else begin mid := (1 shl (q.bits - 1)) - 1; top := mid + 1; ci := q.bits; end;
      end;
      i := 0;
      while i < n do
      begin
        { a grouped code word above its levels: kept as it is }
        if (f.layer = 2) and (q.levels > 0) and (i mod 3 = 0) then
        begin
          Part(5);
          if m.Bit(Ord(f.smp[ch, sb, i + 1] < 0), m.oddCode, LIMIT_STRUCT) = 1 then
          begin
            f.smp[ch, sb, i] := CodeField(m, f.smp[ch, sb, i], q.bits, F_ODD, 0);
            if f.smp[ch, sb, i] < q.levels * q.levels * q.levels then Exit;
            f.smp[ch, sb, i + 1] := -1; f.smp[ch, sb, i + 2] := -1;
            Inc(i, 3);
            Continue;
          end;
        end;
        { the two samples before (the last frame's at the start), centred;
          the other channel's at this time; the scale factor }
        x1 := Before(1); x2 := Before(2);
        if (ch = 1) and (f.alloc[0, sb] <> 0) and (f.smp[0, sb, i] >= 0) then
          xo := SLog(f.smp[0, sb, i] - MidOf(0)) else xo := 99;
        x := f.smp[ch, sb, i] - mid;
        x := CodeSample(m, x, top, ci,
          Hash4(ci, SLog(x1), SLog(x2), 1),
          Hash4(ci, SLog(2 * x1 - x2), sb shr 2, 2),
          Hash4(ci, sb, Min7(Abs(x1)), Min7(Abs(x2))),
          Hash4(ci, xo, SLog(x1), 4),
          Hash4(ci, f.scf[ch, sb, i * 3 div n] shr 2, Min7(Abs(x1)), 5));
        if (x + mid < 0) or (x + mid > 2 * mid + 1) or ((q.levels > 0) and (f.layer = 2) and (x + mid >= q.levels)) then Exit;
        f.smp[ch, sb, i] := x + mid;
        Inc(i);
      end;
    end;
    if chs < f.nch then
      for i := 0 to 35 do f.smp[1, sb, i] := f.smp[0, sb, i];
  end;
  { the context of the next frame: the centred magnitudes }
  m.lastL12 := f;
  for sb := 0 to f.sblimit - 1 do
    for ch := 0 to f.nch - 1 do
      if f.alloc[ch, sb] <> 0 then
      begin
        if f.layer = 1 then mid := (1 shl f.alloc[ch, sb]) - 1
        else
        begin
          q := QClass(f.table, sb, f.alloc[ch, sb]);
          if q.levels > 0 then mid := (q.levels - 1) div 2 else mid := (1 shl (q.bits - 1)) - 1;
        end;
        for i := 0 to 35 do
          if f.smp[ch, sb, i] >= 0 then m.lastL12.smp[ch, sb, i] := f.smp[ch, sb, i] - mid
          else m.lastL12.smp[ch, sb, i] := 0;
      end;
  Result := True;
end;

{ a Layer I or II frame's bytes after its header: modelled, or as bytes }
function CodeL12Frame(var m: TModel; var d: TBytes; pos, len: Int64; const hd: TMpegHeader): Boolean;
var f: TL12Frame; ok, first, j: Integer; w: TBitWriter;
begin
  Result := False;
  ok := 0;
  f := Default(TL12Frame);
  if not m.decoding then ok := Ord(ParseL12(d, pos, len, hd, f));
  Part(0);
  if m.Bit(ok, m.l12modelled, LIMIT_STRUCT) = 0 then
  begin
    Part(1);
    CodeBytes(m, d, pos + 4, len - 4, 0);
    Exit(True);
  end;
  first := 4 + 2 * Ord(hd.hasCrc);
  if m.decoding then
  begin
    { the frame's shape, as ParseL12 sets it }
    f.layer := hd.layer; f.nch := hd.channels;
    if f.layer = 1 then begin f.sblimit := 32; f.table := -1; end
    else L2Table(hd, len, f.table, f.sblimit);
    if hd.mode = 1 then f.bound := 4 * (hd.modeExt + 1) else f.bound := 32;
    if f.bound > f.sblimit then f.bound := f.sblimit;
  end;
  if not CodeL12Fields(m, f, hd) then Exit;
  if m.decoding then
  begin
    w.Init(len);
    WriteL12(f, w);
    if w.pos > (len - first) * 8 then Exit;
    for j := 0 to Integer((w.pos + 7) shr 3) - 1 do d[pos + first + j] := w.d[j];
    f.endBit := first * 8 + Integer(w.pos);
    { the CRC's bits: up to the end of the scfsi, which ParseL12 would say }
    if hd.hasCrc then
      if not ParseL12(d, pos, len, hd, f) then Exit;
  end;
  CodeCrc(m, d, pos, pos + 6, hd, f.crcBits);
  { the ancillary data }
  Part(3);
  CodeFrameBits(m, d, pos, f.endBit, len * 8, 1);
  Result := True;
end;

{ a Layer III frame's bytes after its header, the frame at pos of len bytes;
  False if the stream is damaged }
function CodeL3Frame(var m: TModel; var d: TBytes; var run: TRun; pos, len: Int64;
  const hd: TMpegHeader; ver: Integer): Boolean;
var
  si: TSideInfo; siAt: Int64; w: TBytes; i, g, c, mapped: Integer; start, stop, cum, b: Int64;
begin
  Result := False;
  if len < SlotsOffset(hd) then Exit;
  siAt := pos + 4 + 2 * Ord(hd.hasCrc);
  if m.decoding then InitSideInfo(hd, si) else ReadSideInfo(d, siAt, hd, si);
  Part(2);
  CodeSideInfo(m, si, ver < 4);
  if ver < 4 then
  begin
    if m.decoding then
    begin
      w := WriteSideInfo(si, hd);
      for i := 0 to hd.sideInfoBytes - 1 do d[siAt + i] := w[i];
    end;
    CodeCrc(m, d, pos, siAt, hd);
  end;
  cum := run.slotBytes;
  run.AddSlots(pos + SlotsOffset(hd), len - SlotsOffset(hd));
  start := (cum - si.mainDataBegin) * 8;
  if ver >= 4 then
  begin
    { whether the frame's main data is where its side information says;
      the granules then give their part23 as they are coded }
    mapped := 0;
    if not m.decoding then
      mapped := Ord((start >= run.prevEnd) and (start + MainDataBits(si) <= run.slotBytes * 8));
    Part(0);
    if m.Bit(mapped, m.mappedBit, LIMIT_STRUCT) = 1 then
    begin
      if start < run.prevEnd then Exit;
      Part(3);
      CodeSlotBits(m, d, run, run.prevEnd, start, 1);
      b := start;
      for g := 0 to si.nGr - 1 do
        for c := 0 to si.nCh - 1 do
        begin
          if not CodeGranule4(m, d, run, si, g, c, b, hd) then Exit;
          Inc(b, si.gr[g, c].part23);
        end;
      run.prevEnd := b;
    end
    else
      for g := 0 to si.nGr - 1 do
        for c := 0 to si.nCh - 1 do
        begin
          si.gr[g, c].part23 := CodeField(m, si.gr[g, c].part23, 12, F_PART23, m.lastPart23[c]);
          m.lastPart23[c] := si.gr[g, c].part23;
        end;
    if m.decoding then
    begin
      w := WriteSideInfo(si, hd);
      for i := 0 to hd.sideInfoBytes - 1 do d[siAt + i] := w[i];
    end;
    CodeCrc(m, d, pos, siAt, hd);
    Exit(True);
  end;
  stop := start + MainDataBits(si);
  if (start >= run.prevEnd) and (stop <= run.slotBytes * 8) then
  begin
    Part(3);
    CodeSlotBits(m, d, run, run.prevEnd, start, 1);
    Part(5);
    b := start;
    for g := 0 to si.nGr - 1 do
      for c := 0 to si.nCh - 1 do
      begin
        if ver < 3 then CodeSlotBits(m, d, run, b, b + si.gr[g, c].part23, 0)
        else if not CodeGranule(m, d, run, si, g, c, b, hd, ver) then Exit;
        Inc(b, si.gr[g, c].part23);
      end;
    run.prevEnd := stop;
  end;
  Result := True;
end;

{ ---------- the stream ---------- }

procedure PutVarint(var s: TBytes; var n: SizeInt; v: Int64);
begin
  repeat
    if n >= Length(s) then SetLength(s, 2 * Length(s) + 16);
    if v >= 128 then s[n] := Byte(v and 127) or 128 else s[n] := Byte(v);
    Inc(n);
    v := v shr 7;
  until v = 0;
end;

{ -1 if it runs past the end, is longer than 9 bytes or above maxv }
function GetVarint(const s: TBytes; var p: SizeInt; maxv: Int64): Int64;
var shift: Integer; b: Byte;
begin
  Result := 0; shift := 0;
  repeat
    if (p >= Length(s)) or (shift > 56) then Exit(-1);
    b := s[p]; Inc(p);
    Result := Result or (Int64(b and 127) shl shift);
    Inc(shift, 7);
  until b < 128;
  if Result > maxv then Result := -1;
end;

{ Every segment, the same code both ways: the encoder takes them from
  scan, the decoder from the stream. ver: the stream's version. False if the
  stream is damaged. }
function Walk(var m: TModel; var d: TBytes; total: Int64; const scan: TMpegScan; ver: Integer): Boolean;
var
  pos, len: Int64; i, kind, freeLen, goesOn: Integer; h: UInt32; hd, hn: TMpegHeader;
  run: TRun; inRun: Boolean;
begin
  Result := False;
  m.ver := ver;
  pos := 0; i := 0; inRun := False;
  run := Default(TRun);
  while pos < total do
  begin
    kind := 0;
    Part(0);
    if not m.decoding then kind := Ord(scan.segments[i].kind);
    kind := CodeKind(m, kind);
    if kind > Ord(High(TSegmentKind)) then Exit;
    if inRun and (TSegmentKind(kind) <> skFrame) then Exit;
    if TSegmentKind(kind) = skFrame then
    begin
      h := 0;
      if not m.decoding then h := HeaderAt(d, pos);
      h := CodeHeader(m, h);
      if not DecodeHeader(h, hd) then Exit;
      freeLen := 0;
      if not m.decoding then freeLen := Integer(scan.segments[i].length) - hd.padding * hd.slotBytes;
      if hd.bitrateIndex = 0 then freeLen := CodeFree(m, freeLen);
      len := FrameLength(hd, freeLen);
      if (len < 4) or (len > total - pos) then Exit;
      d[pos] := h shr 24; d[pos + 1] := (h shr 16) and $FF;
      d[pos + 2] := (h shr 8) and $FF; d[pos + 3] := h and $FF;
      if (ver >= 2) and (hd.layer = 3) then
      begin
        if inRun and not SameStream(run.first, hd) then Exit;
        if not inRun then run.Start(hd);
        if not CodeL3Frame(m, d, run, pos, len, hd, ver) then Exit;
        { does the run go on with the next segment? }
        goesOn := 0;
        if not m.decoding then
          goesOn := Ord((i + 1 < scan.count) and (scan.segments[i + 1].kind = skFrame)
            and DecodeHeader(HeaderAt(d, scan.segments[i + 1].offset), hn)
            and (hn.layer = 3) and SameStream(run.first, hn));
        Part(0);
        inRun := m.Bit(goesOn, m.runGoesOn, LIMIT_STRUCT) = 1;
        Part(3);
        if not inRun then
          CodeSlotBits(m, d, run, run.prevEnd, run.slotBytes * 8, 1);
      end
      else
      begin
        if inRun then Exit;
        if ver >= 5 then
        begin
          if not CodeL12Frame(m, d, pos, len, hd) then Exit;
        end
        else
        begin
          Part(1);
          CodeBytes(m, d, pos + 4, len - 4, 0);
        end;
      end;
    end
    else
    begin
      len := 0;
      if not m.decoding then len := scan.segments[i].length;
      len := CodeLength(m, len);
      if (len < 1) or (len > total - pos) then Exit;
      Part(1);
      CodeBytes(m, d, pos, len, 1);
    end;
    Inc(pos, len);
    Inc(i);
  end;
  Result := not inRun;
end;

{ the stream of d; with live, its bytes also go to live as they come out
  (and live is finished, even on an exception) }
function Encode(const d: TBytes; const scan: TMpegScan; ver: Integer; live: TLiveStream = nil): TBytes;
var m: PModel; work, body: TBytes; n: SizeInt;
begin
  New(m);
  try
    try
      m^.Init(False);
      if live <> nil then m^.enc.InitLive(live) else m^.enc.Init;
      work := Copy(d, 0, Length(d));
      Walk(m^, work, Length(d), scan, ver);
      body := m^.enc.Finish;
      if live <> nil then body := live.Bytes;
    except
      { the verifier waits for bytes: let it end }
      if live <> nil then live.Finish;
      raise;
    end;
  finally
    Dispose(m);
  end;
  Result := nil;
  SetLength(Result, 16);
  Result[0] := ver; n := 1;
  PutVarint(Result, n, Length(d));
  SetLength(Result, n + Length(body));
  if Length(body) > 0 then Move(body[0], Result[n], Length(body));
end;

function DecodeFile(const s: TBytes; maxOut: Int64; out d: TBytes; threads: Integer): TDecodeStatus;
var m: PModel; p: SizeInt; total: Int64; ok: Boolean; none: TMpegScan;
begin
  d := nil;
  if Length(s) = 0 then Exit(dsEmpty);
  if s[0] > STREAM_VERSION then Exit(dsFutureVersion);
  if s[0] < 1 then Exit(dsBadStream);
  p := 1;
  total := GetVarint(s, p, High(Int64));
  if total < 1 then Exit(dsBadStream);
  if total > maxOut then Exit(dsTooBig);
  SetLength(d, total);
  none.Clear;
  New(m);
  try
    m^.Init(True);
    m^.dec.Init(s, p);
    ok := Walk(m^, d, total, none, s[0]);
  finally
    Dispose(m);
  end;
  if not ok then begin d := nil; Exit(dsBadStream); end;
  Result := dsOk;
end;

{ ---------- verifying while encoding ---------- }

type
  { Decodes the stream from the encoder's bytes as they come out (a
    TLiveStream), on its own thread: the check runs beside the encoding.
    A bare thread (BeginThread, WaitForThreadTerminate), as PRA's: there
    TThread.WaitFor waited in steps of 100 ms. }
  TVerifier = record
    live: TLiveStream;
    total: Int64;
    back: TBytes;
    ok: Boolean;
  end;
  PVerifier = ^TVerifier;

function VerifierRun(p: Pointer): PtrInt;
var v: PVerifier; m: PModel; none: TMpegScan;
begin
  v := p;
  v^.ok := False;
  none.Clear;
  New(m);
  try
    try
      m^.Init(True);
      m^.dec.InitLive(v^.live);
      SetLength(v^.back, v^.total);
      v^.ok := Walk(m^, v^.back, v^.total, none, STREAM_VERSION);
    except
      v^.ok := False;
    end;
  finally
    Dispose(m);
  end;
  Result := 0;
end;

function EncodeFile(const d: TBytes; out s: TBytes; threads: Integer): TEncodeStatus;
var scan: TMpegScan; back: TBytes; v: TVerifier; tid: TThreadID; same: Boolean;
begin
  s := nil;
  ScanMpeg(d, scan);
  if scan.frames = 0 then Exit(esNotMpeg);
  if threads >= 2 then
  begin
    { the check on a second thread, as the stream comes out }
    v.live := TLiveStream.Create;
    v.total := Length(d); v.back := nil; v.ok := False;
    tid := BeginThread(@VerifierRun, @v);
    try
      try
        s := Encode(d, scan, STREAM_VERSION, v.live);
      except
        s := nil;
      end;
    finally
      WaitForThreadTerminate(tid, 0);
      CloseThread(tid);
      v.live.Free;
    end;
    same := (s <> nil) and v.ok and (Length(v.back) = Length(d))
            and CompareMem(@v.back[0], @d[0], Length(d));
    if not same then begin s := nil; Exit(esNotBack); end;
    Exit(esOk);
  end;
  s := Encode(d, scan, STREAM_VERSION);
  { the one guarantee: it has to come back }
  if (DecodeFile(s, Length(d), back) <> dsOk) or (Length(back) <> Length(d))
     or not CompareMem(@back[0], @d[0], Length(d)) then
  begin
    s := nil;
    Exit(esNotBack);
  end;
  Result := esOk;
end;

function EncodeAs(const d: TBytes; ver: Integer): TBytes;
var scan: TMpegScan;
begin
  ScanMpeg(d, scan);
  if scan.frames = 0 then Exit(nil);
  Result := Encode(d, scan, ver);
end;

function EncodeStatusName(st: TEncodeStatus): string;
begin
  case st of
    esOk: Result := 'ok';
    esNotMpeg: Result := 'no MPEG audio frames';
  else Result := 'did not come back the same';
  end;
end;

function DecodeStatusName(st: TDecodeStatus): string;
begin
  case st of
    dsOk: Result := 'ok';
    dsEmpty: Result := 'empty stream';
    dsFutureVersion: Result := 'stream from a later version';
    dsBadStream: Result := 'damaged stream';
  else Result := 'larger than allowed';
  end;
end;

end.
