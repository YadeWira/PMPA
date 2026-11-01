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

uses SysUtils, pmpampeg, pmpal3, pmpahuff;

const
  STREAM_VERSION = 3;
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
{ for the tests: the stream of d in an earlier version (1 to STREAM_VERSION),
  not verified; nil if d has no MPEG audio frame }
function EncodeAs(const d: TBytes; ver: Integer): TBytes;
function DecodeStatusName(st: TDecodeStatus): string;

implementation

uses pmpaarith, pmpalimits;

const
  LIMIT_STRUCT = 127;   { the structure (kinds, headers, lengths) is steady }
  LIMIT_BYTES = 60;
  KIND_START = 6;       { the context of the first segment's kind }

const
  { the side information's fields, each with its own contexts }
  F_MDB = 0; F_PRIV = 1; F_SCFSI = 2; F_PART23 = 3; F_BIGV = 4; F_GAIN = 5;
  F_SFC = 6; F_WS = 7; F_BT = 8; F_MIX = 9; F_TAB = 10; { 10, 11, 12 }
  F_SUBG = 13; F_R0 = 14; F_R1 = 15; F_PRE = 16; F_SFS = 17; F_C1 = 18; F_CRC = 19;
  F_QUADS = 20;
  N_FIELDS = 21;
  { the values' contexts: how many of each }
  N_CAP = 7;      { what the table allows: 1, 2, 3, 5, 7, 15, 15 and linbits }
  N_NB = 8;       { the two values before }
  N_PREV = 6;     { the same value in the granule before }
  N_POS = 6;      { where in the granule }
  HIST_BITS = 12;

type
  TModel = record
    decoding: Boolean;
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
    crcOk, runGoesOn: TAdaptiveBit;
    slot: array[0..1, 0..(1 shl HIST_BITS) - 1] of TAdaptiveBit;   { [0] main data, [1] filler }
    { version 3: Layer III's Huffman-coded values }
    modelled: TAdaptiveBit;
    zero: array[0..N_CAP - 1, 0..N_NB - 1, 0..N_PREV - 1, 0..N_POS - 1] of TAdaptiveBit;
    gt: array[0..N_CAP - 1, 1..15, 0..N_NB - 1, 0..N_PREV - 1] of TAdaptiveBit;
    sign: TAdaptiveBit;
    linLen: array[1..15] of TAdaptiveBit;      { a tree of 4 decisions }
    linLow: array[0..12] of TAdaptiveBit;
    c1Zero: array[0..N_NB - 1, 0..N_PREV - 1, 0..N_POS - 1] of TAdaptiveBit;
    prevVals: array[0..1] of TGranuleValues;
    lastQuads: array[0..1] of Integer;
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
  crcOk.Init; runGoesOn.Init;
  for i := 0 to 1 do for j := 0 to (1 shl HIST_BITS) - 1 do slot[i, j].Init;
  hist := 0; lastSlotBit := -2;
  modelled.Init; sign.Init;
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
  lastSi := Default(TSideInfo);
  lastHeader := 0; lastFree := 0; prevKind := KIND_START;
end;

function TModel.Bit(b: Integer; var ab: TAdaptiveBit; limit: Integer): Integer;
begin
  if decoding then Result := dec.Decode(ab.p)
  else begin enc.Encode(b, ab.p); Result := b; end;
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

procedure CodeSideInfo(var m: TModel; var si: TSideInfo);
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
        part23 := CodeField(m, part23, 12, F_PART23, p.part23);
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
      if m.Bit(Ord(a <> 0), m.zero[cls, nb, pp, ps], LIMIT_BYTES) = 0 then
      begin
        v[i] := 0;
        Continue;
      end;
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
      if m.Bit(Ord(v[i] < 0), m.sign, LIMIT_BYTES) = 1 then v[i] := -k else v[i] := k;
    end
    else if i < 2 * gi.bigValues + 4 * quads then
    begin
      nb := 0;
      if i > 0 then nb := 2 * Abs(v[i - 1]);
      if i > 1 then Inc(nb, Abs(v[i - 2]));
      nb := NbBucket(nb);
      pp := PrevBucket(Abs(m.prevVals[c][i]));
      if m.Bit(Ord(v[i] <> 0), m.c1Zero[nb, pp, PosBucket(i)], LIMIT_BYTES) = 0 then v[i] := 0
      else if m.Bit(Ord(v[i] < 0), m.sign, LIMIT_BYTES) = 1 then v[i] := -1
      else v[i] := 1;
    end
    else v[i] := 0;
  end;
  m.prevVals[c] := v;
  Result := True;
end;

{ granule g, channel c's main data, from bit b of the slot stream }
function CodeGranule(var m: TModel; var d: TBytes; var run: TRun; const si: TSideInfo;
  g, c: Integer; b: Int64; const hd: TMpegHeader): Boolean;
var
  p23, p2, p3, quads, tail, j, L: Integer; bits: TBytes; w: TBitWriter;
  v: TGranuleValues; ok: Boolean;
begin
  Result := False;
  p23 := si.gr[g, c].part23;
  p2 := Part2Bits(si, g, c, hd);
  if p2 > p23 then
  begin
    CodeSlotBits(m, d, run, b, b + p23, 0);
    Exit(True);
  end;
  { the scalefactors, as bits }
  CodeSlotBits(m, d, run, b, b + p2, 0);
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
  if m.Bit(Ord(ok), m.modelled, LIMIT_STRUCT) = 0 then
  begin
    CodeSlotBits(m, d, run, b + p2, b + p23, 0);
    Exit(True);
  end;
  quads := CodeField(m, quads, 8, F_QUADS, m.lastQuads[c]);
  m.lastQuads[c] := quads;
  if not CodeValues(m, v, si.gr[g, c], hd, quads, c) then Exit;
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
  CodeSlotBits(m, d, run, b + p2 + L, b + p23, 1);
  Result := True;
end;

{ a Layer III frame's bytes after its header, the frame at pos of len bytes;
  False if the stream is damaged }
function CodeL3Frame(var m: TModel; var d: TBytes; var run: TRun; pos, len: Int64;
  const hd: TMpegHeader; ver: Integer): Boolean;
var
  si: TSideInfo; siAt: Int64; w: TBytes; crc, stored, ok, i, g, c: Integer; start, stop, cum, b: Int64;
begin
  Result := False;
  if len < SlotsOffset(hd) then Exit;
  siAt := pos + 4 + 2 * Ord(hd.hasCrc);
  if m.decoding then InitSideInfo(hd, si) else ReadSideInfo(d, siAt, hd, si);
  CodeSideInfo(m, si);
  if m.decoding then
  begin
    w := WriteSideInfo(si, hd);
    for i := 0 to hd.sideInfoBytes - 1 do d[siAt + i] := w[i];
  end;
  if hd.hasCrc then
  begin
    crc := MpegCrc(HeaderAt(d, pos), d, siAt, hd.sideInfoBytes * 8);
    stored := (d[pos + 4] shl 8) or d[pos + 5];
    ok := m.Bit(Ord(stored = crc), m.crcOk, LIMIT_STRUCT);
    if ok = 1 then stored := crc
    else stored := CodeField(m, stored, 16, F_CRC, crc);
    d[pos + 4] := stored shr 8; d[pos + 5] := stored and $FF;
  end;
  cum := run.slotBytes;
  run.AddSlots(pos + SlotsOffset(hd), len - SlotsOffset(hd));
  start := (cum - si.mainDataBegin) * 8;
  stop := start + MainDataBits(si);
  if (start >= run.prevEnd) and (stop <= run.slotBytes * 8) then
  begin
    CodeSlotBits(m, d, run, run.prevEnd, start, 1);
    if ver < 3 then CodeSlotBits(m, d, run, start, stop, 0)
    else
    begin
      b := start;
      for g := 0 to si.nGr - 1 do
        for c := 0 to si.nCh - 1 do
        begin
          if not CodeGranule(m, d, run, si, g, c, b, hd) then Exit;
          Inc(b, si.gr[g, c].part23);
        end;
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
  pos := 0; i := 0; inRun := False;
  run := Default(TRun);
  while pos < total do
  begin
    kind := 0;
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
        inRun := m.Bit(goesOn, m.runGoesOn, LIMIT_STRUCT) = 1;
        if not inRun then
          CodeSlotBits(m, d, run, run.prevEnd, run.slotBytes * 8, 1);
      end
      else
      begin
        if inRun then Exit;
        CodeBytes(m, d, pos + 4, len - 4, 0);
      end;
    end
    else
    begin
      len := 0;
      if not m.decoding then len := scan.segments[i].length;
      len := CodeLength(m, len);
      if (len < 1) or (len > total - pos) then Exit;
      CodeBytes(m, d, pos, len, 1);
    end;
    Inc(pos, len);
    Inc(i);
  end;
  Result := not inRun;
end;

function Encode(const d: TBytes; const scan: TMpegScan; ver: Integer): TBytes;
var m: PModel; work, body: TBytes; n: SizeInt;
begin
  New(m);
  try
    m^.Init(False);
    m^.enc.Init;
    work := Copy(d, 0, Length(d));
    Walk(m^, work, Length(d), scan, ver);
    body := m^.enc.Finish;
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

function EncodeFile(const d: TBytes; out s: TBytes; threads: Integer): TEncodeStatus;
var scan: TMpegScan; back: TBytes;
begin
  s := nil;
  ScanMpeg(d, scan);
  if scan.frames = 0 then Exit(esNotMpeg);
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
