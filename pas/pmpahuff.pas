{ Layer 3, Layer III: a granule's Huffman-coded values, decoded and coded
  again.

  The values of a granule (576 a channel) are three parts: the big values
  (pairs, each pair with the table of its region, values of 15 and more
  with linbits), the count1 quadruples (values -1, 0 or 1, table A or B),
  and zeros. The side information gives everything but where the count1
  part ends: that is where the granule's bits end.

  DecodeValues says whether the bits are regular: every big value decoded
  inside them, every code in its table. The count1 part goes on while a
  whole quadruple (its code and signs) fits in the bits and in the 576
  values; what is left (a last quadruple cut short, bits after the 576th
  value: stuffing some encoders leave, which decoders skip) is the tail,
  kept as bits. A regular granule coded again with EncodeValues, and its
  tail after it, gives its bits back exactly: the codes are a prefix code,
  a value has one way to be written, and the count1 part's length is
  kept. }
unit pmpahuff;

{$I pmpa.inc}
{$ifdef PMPA_FAST}
  {$R-}{$Q-}
{$else}
  {$ifopt R-}{$fatal pmpahuff: range checks ($R+) are mandatory}{$endif}
  {$ifopt Q-}{$fatal pmpahuff: overflow checks ($Q+) are mandatory}{$endif}
{$endif}

interface

uses SysUtils, pmpampeg, pmpal3;

{$I pmpahuff.inc}

type
  TGranuleValues = array[0..575] of Integer;

{ the values of one granule and channel from its Huffman bits (nbits of
  them, from bit `first` of bits); quads: how many count1 quadruples; tail:
  how many bits are left after them. False if the bits are not regular
  (see above). }
function DecodeValues(const bits: TBytes; first, nbits: Int64; const gi: TGranuleInfo;
  const hd: TMpegHeader; out v: TGranuleValues; out quads, tail: Integer): Boolean;
{ the Huffman bits of v onto w (not its tail); False if a value does not fit
  its table, or the big values and quads do not fit in 576 }
function EncodeValues(const v: TGranuleValues; quads: Integer; const gi: TGranuleInfo;
  const hd: TMpegHeader; var w: TBitWriter): Boolean;
{ for the tests: every table a complete prefix code }
function TablesComplete: Boolean;

implementation

type
  { one decoding tree per table: node 0 is the root; child[n, b] > 0 is
    the next node, < 0 is -(index + 1) of the entry decoded }
  TTree = record
    child: array of array[0..1] of Integer;
    n: Integer;
  end;

var
  { trees of the 17 distinct tables }
  Trees: array of TTree;
  TreeOf: array of Integer;   { a table's first entry -> its tree }
  Built: Boolean = False;

procedure BuildTree(first, count: Integer; out t: TTree);
var e, k, node, b, nxt: Integer;
begin
  t.child := nil;
  SetLength(t.child, 2 * count + 2);
  t.n := 1;
  t.child[0, 0] := 0; t.child[0, 1] := 0;
  for e := 0 to count - 1 do
  begin
    node := 0;
    for k := HUFF_LEN[first + e] - 1 downto 0 do
    begin
      b := (HUFF_CODE[first + e] shr k) and 1;
      if k = 0 then
        t.child[node, b] := -(e + 1)
      else
      begin
        nxt := t.child[node, b];
        if nxt <= 0 then
        begin
          nxt := t.n; Inc(t.n);
          t.child[nxt, 0] := 0; t.child[nxt, 1] := 0;
          t.child[node, b] := nxt;
        end;
        node := nxt;
      end;
    end;
  end;
end;

procedure BuildAll;
var t, first, k: Integer;
  procedure Add(f, c: Integer);
  begin
    SetLength(Trees, k + 1);
    BuildTree(f, c, Trees[k]);
    TreeOf[f] := k;
    Inc(k);
  end;
begin
  if Built then Exit;
  SetLength(TreeOf, Length(HUFF_LEN));
  k := 0;
  Add(COUNT1_A, 16);
  Add(COUNT1_B, 16);
  for t := 1 to 31 do
  begin
    first := HUFF_OFFSET[t];
    if first < 0 then Continue;
    if (t > 16) and (t <= 23) then Continue;    { table 16's }
    if t > 24 then Continue;                    { table 24's }
    Add(first, HUFF_SIZE[t] * HUFF_SIZE[t]);
  end;
  Built := True;
end;

function TablesComplete: Boolean;
var t, e, first, count: Integer; sum: Double;
begin
  Result := True;
  for t := -2 to 31 do
  begin
    if t = -2 then begin first := COUNT1_A; count := 16; end
    else if t = -1 then begin first := COUNT1_B; count := 16; end
    else begin
      first := HUFF_OFFSET[t];
      if first < 0 then Continue;
      count := HUFF_SIZE[t] * HUFF_SIZE[t];
    end;
    sum := 0;
    for e := 0 to count - 1 do sum := sum + 1 / (Int64(1) shl HUFF_LEN[first + e]);
    if Abs(sum - 1) > 1e-12 then Result := False;
  end;
end;

{ reads a code of the table whose entries start at `first`; -1 if the bits
  end first }
function ReadCode(var r: TBitReader; first: Integer): Integer;
var node, b: Integer;
begin
  node := 0;
  repeat
    if r.pos >= r.limit then Exit(-1);
    b := Integer(r.Get(1));
    node := Trees[TreeOf[first]].child[node, b];
    if node = 0 then Exit(-1);        { cannot happen with a complete code }
  until node < 0;
  Result := -node - 1;
end;

function DecodeValues(const bits: TBytes; first, nbits: Int64; const gi: TGranuleInfo;
  const hd: TMpegHeader; out v: TGranuleValues; out quads, tail: Integer): Boolean;
var
  r: TBitReader; r1, r2, i, t, e, x, y, size, lin, q, k: Integer; vals: array[0..3] of Integer;
  mark: Int64; whole: Boolean;
begin
  Result := False;
  FillChar(v, SizeOf(v), 0);
  quads := 0; tail := 0;
  BuildAll;
  if gi.bigValues * 2 > 576 then Exit;
  r.d := bits; r.pos := first; r.limit := first + nbits;
  Regions(gi, hd, r1, r2);
  i := 0;
  while i < gi.bigValues * 2 do
  begin
    if i < r1 then t := gi.table[0]
    else if i < r2 then t := gi.table[1]
    else t := gi.table[2];
    if HUFF_OFFSET[t] = -2 then Exit;          { tables 4 and 14 }
    if HUFF_OFFSET[t] = -1 then
    begin
      Inc(i, 2);                               { table 0: zeros, no bits }
      Continue;
    end;
    size := HUFF_SIZE[t]; lin := LINBITS[t];
    e := ReadCode(r, HUFF_OFFSET[t]);
    if e < 0 then Exit;
    x := e div size; y := e mod size;
    if (lin > 0) and (x = 15) then
    begin
      if r.pos + lin > r.limit then Exit;
      Inc(x, Integer(r.Get(lin)));
    end;
    if x <> 0 then
    begin
      if r.pos >= r.limit then Exit;
      if r.Get(1) = 1 then x := -x;
    end;
    if (lin > 0) and (y = 15) then
    begin
      if r.pos + lin > r.limit then Exit;
      Inc(y, Integer(r.Get(lin)));
    end;
    if y <> 0 then
    begin
      if r.pos >= r.limit then Exit;
      if r.Get(1) = 1 then y := -y;
    end;
    v[i] := x; v[i + 1] := y;
    Inc(i, 2);
  end;
  if gi.count1Table = 0 then q := COUNT1_A else q := COUNT1_B;
  whole := True;
  while whole and (r.pos < r.limit) and (i + 4 <= 576) do
  begin
    mark := r.pos;
    e := ReadCode(r, q);
    whole := e >= 0;
    if whole then
    begin
      vals[0] := (e shr 3) and 1; vals[1] := (e shr 2) and 1;
      vals[2] := (e shr 1) and 1; vals[3] := e and 1;
      for k := 0 to 3 do
        if whole and (vals[k] <> 0) then
        begin
          if r.pos >= r.limit then whole := False
          else if r.Get(1) = 1 then vals[k] := -1;
        end;
    end;
    if whole then
    begin
      for k := 0 to 3 do v[i + k] := vals[k];
      Inc(i, 4);
      Inc(quads);
    end
    else
      r.pos := mark;                           { the tail starts here }
  end;
  tail := Integer(r.limit - r.pos);
  Result := True;
end;

function EncodeValues(const v: TGranuleValues; quads: Integer; const gi: TGranuleInfo;
  const hd: TMpegHeader; var w: TBitWriter): Boolean;
var r1, r2, i, t, e, x, y, ax, ay, size, lin, q, k, a: Integer;
begin
  Result := False;
  BuildAll;
  if (gi.bigValues * 2 > 576) or (quads < 0) or (gi.bigValues * 2 + 4 * quads > 576) then Exit;
  Regions(gi, hd, r1, r2);
  i := 0;
  while i < gi.bigValues * 2 do
  begin
    if i < r1 then t := gi.table[0]
    else if i < r2 then t := gi.table[1]
    else t := gi.table[2];
    x := v[i]; y := v[i + 1];
    if HUFF_OFFSET[t] = -2 then Exit;
    if HUFF_OFFSET[t] = -1 then
    begin
      if (x <> 0) or (y <> 0) then Exit;
      Inc(i, 2);
      Continue;
    end;
    size := HUFF_SIZE[t]; lin := LINBITS[t];
    ax := Abs(x); ay := Abs(y);
    if lin > 0 then
    begin
      if (ax - 15 >= 1 shl lin) or (ay - 15 >= 1 shl lin) then Exit;
      if ax > 15 then a := 15 else a := ax;
      if ay > 15 then e := 15 else e := ay;
      e := a * size + e;
    end
    else
    begin
      if (ax >= size) or (ay >= size) then Exit;
      e := ax * size + ay;
    end;
    w.Put(HUFF_CODE[HUFF_OFFSET[t] + e], HUFF_LEN[HUFF_OFFSET[t] + e]);
    if (lin > 0) and (ax >= 15) then w.Put(Cardinal(ax - 15), lin);
    if x <> 0 then w.Put(Ord(x < 0), 1);
    if (lin > 0) and (ay >= 15) then w.Put(Cardinal(ay - 15), lin);
    if y <> 0 then w.Put(Ord(y < 0), 1);
    Inc(i, 2);
  end;
  if gi.count1Table = 0 then q := COUNT1_A else q := COUNT1_B;
  for k := 1 to quads do
  begin
    e := 0;
    for a := 0 to 3 do
    begin
      if Abs(v[i + a]) > 1 then Exit;
      e := e * 2 + Abs(v[i + a]);
    end;
    w.Put(HUFF_CODE[q + e], HUFF_LEN[q + e]);
    for a := 0 to 3 do
      if v[i + a] <> 0 then w.Put(Ord(v[i + a] < 0), 1);
    Inc(i, 4);
  end;
  { what follows the count1 part is zero }
  while i < 576 do
  begin
    if v[i] <> 0 then Exit;
    Inc(i);
  end;
  Result := True;
end;

end.
