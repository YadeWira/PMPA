{ Layer 3, Layer I and II: a frame's fields, read and written bit for bit.

  After its header (and CRC) a Layer I or II frame is, channel by channel
  and subband by subband: the bit allocation, Layer II's scale factor
  selection information (scfsi), the scale factors (6 bits each) and the
  samples, 12 of each subband in Layer I, 36 in Layer II (12 granules of
  3, which Layer II may group into one code word for 3, 5 or 9 levels).
  Above the joint stereo bound the two channels share their allocation and
  samples, not their scale factors. What follows the samples, up to the
  frame's end, is ancillary data.

  Every field has a fixed length once the allocation is known, so writing
  back what was read gives the same bits. Parse fails only when the fields
  do not fit in the frame or an allocation is Layer I's forbidden 15 (or
  not in Layer II's table); such a frame is kept as bytes by the codec. A
  grouped code word above what its levels allow (a few real encoders write
  them: 280 frames of the samples from the net) is kept as it is.

  Layer II's allocation tables (ISO/IEC 11172-3 tables B.2a to B.2d,
  13818-3 table B.1) are chosen by the bitrate per channel and the sample
  rate: what the class of each subband's allocation is, below. }
unit pmpal12;

{$I pmpa.inc}
{$ifdef PMPA_FAST}
  {$R-}{$Q-}
{$else}
  {$ifopt R-}{$fatal pmpal12: range checks ($R+) are mandatory}{$endif}
  {$ifopt Q-}{$fatal pmpal12: overflow checks ($Q+) are mandatory}{$endif}
{$endif}

interface

uses SysUtils, pmpampeg, pmpal3;

type
  TL12Frame = record
    layer, nch, sblimit, bound, table: Integer;
    alloc: array[0..1, 0..31] of Integer;
    scfsi: array[0..1, 0..31] of Integer;
    scf: array[0..1, 0..31, 0..2] of Integer;
    { the samples' codes: Layer I 12, Layer II 36 a subband; for a grouped
      class, the 3 samples of each granule's code word }
    smp: array[0..1, 0..31, 0..35] of Integer;
    { where the frame's fields end, in bits from the frame's first byte;
      what follows is ancillary data }
    endBit: Integer;
    crcBits: Integer;        { the bits the CRC covers after the header and CRC }
    crcEnd: Int64;
    { why Parse failed: 1 an allocation, 3 the frame ends first }
    why: Integer;
    { grouped code words above their levels (kept as they are) }
    oddCodes: Integer;
  end;

  { a quantization class: grouped levels (3, 5 or 9) and the code word's
    bits, or ungrouped (levels 0) and each sample's bits }
  TQClass = record
    levels, bits: Integer;
  end;

{ the fields of the frame at byte pos of d (len bytes, header hd); False if
  they cannot be read (see above) }
function ParseL12(const d: TBytes; pos, len: Int64; const hd: TMpegHeader; out f: TL12Frame): Boolean;
{ the fields of f after the header and CRC, onto w }
procedure WriteL12(const f: TL12Frame; var w: TBitWriter);
{ the allocation table and subbands of a Layer II frame (len bytes) }
procedure L2Table(const hd: TMpegHeader; len: Int64; out table, sblimit: Integer);
{ the bits of subband sb's allocation, Layer II }
function AllocBits(table, sb: Integer): Integer;
{ the class of allocation a in subband sb, Layer II; levels -1: no class
  (0 allocated, or not in the table) }
function QClass(table, sb, a: Integer): TQClass;

implementation

const
  CLASSES: array[0..16] of TQClass = (
    (levels: 3; bits: 5), (levels: 5; bits: 7), (levels: 9; bits: 10),
    (levels: 0; bits: 3), (levels: 0; bits: 4), (levels: 0; bits: 5), (levels: 0; bits: 6),
    (levels: 0; bits: 7), (levels: 0; bits: 8), (levels: 0; bits: 9), (levels: 0; bits: 10),
    (levels: 0; bits: 11), (levels: 0; bits: 12), (levels: 0; bits: 13), (levels: 0; bits: 14),
    (levels: 0; bits: 15), (levels: 0; bits: 16));
  { an allocation's class, by the kind of subband: -1 none }
  CLASS_OF: array[0..5, 0..15] of Integer = (
    (-1, 0, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16),
    (-1, 0, 1, 3, 2, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 16),
    (-1, 0, 1, 3, 2, 4, 5, 16, -1, -1, -1, -1, -1, -1, -1, -1),
    (-1, 0, 1, 16, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1),
    (-1, 0, 1, 2, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15),
    (-1, 0, 1, 3, 2, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14));
  SBLIMITS: array[0..4] of Integer = (27, 30, 8, 12, 30);

function SbKind(table, sb: Integer): Integer;
begin
  case table of
    0, 1:
      if sb < 3 then Result := 0
      else if sb < 11 then Result := 1
      else if sb < 23 then Result := 2
      else Result := 3;
    2, 3: Result := 4;
  else
    if sb < 4 then Result := 5 else Result := 4;
  end;
end;

function AllocBits(table, sb: Integer): Integer;
begin
  case table of
    0, 1:
      if sb < 11 then Result := 4
      else if sb < 23 then Result := 3
      else Result := 2;
    2, 3:
      if sb < 2 then Result := 4 else Result := 3;
  else
    if sb < 4 then Result := 4
    else if sb < 11 then Result := 3
    else Result := 2;
  end;
end;

function QClass(table, sb, a: Integer): TQClass;
var k: Integer;
begin
  k := CLASS_OF[SbKind(table, sb), a and 15];
  if k < 0 then begin Result.levels := -1; Result.bits := 0; end
  else Result := CLASSES[k];
end;

procedure L2Table(const hd: TMpegHeader; len: Int64; out table, sblimit: Integer);
var br, perCh: Int64;
begin
  if hd.ver <> mvMpeg1 then table := 4
  else
  begin
    br := hd.bitrate;
    { free format: the bitrate its length gives }
    if br = 0 then br := len * hd.sampleRate div 144000;
    perCh := br div hd.channels;
    if perCh <= 48 then
    begin
      if hd.sampleRate = 32000 then table := 3 else table := 2;
    end
    else if perCh <= 80 then table := 0
    else if hd.sampleRate = 48000 then table := 0
    else table := 1;
  end;
  sblimit := SBLIMITS[table];
end;

type
  PBitWriter = ^TBitWriter;

{ the same walk reads (w = nil) and writes }
function Walk(var f: TL12Frame; var r: TBitReader; w: PBitWriter; limit: Int64): Boolean;
var
  sb, ch, gr, s, k, b, nb, chs: Integer; q: TQClass; code, l: Integer;

  procedure Fld(var v: Integer; n: Integer);
  begin
    if w = nil then v := Integer(r.Get(n)) else w^.Put(Cardinal(v), n);
  end;

  function Fits: Boolean;
  begin
    if w <> nil then Result := True else Result := r.pos <= limit;
  end;

begin
  Result := False;
  { allocation }
  for sb := 0 to f.sblimit - 1 do
  begin
    if sb < f.bound then chs := f.nch else chs := 1;
    if f.layer = 1 then nb := 4 else nb := AllocBits(f.table, sb);
    for ch := 0 to chs - 1 do Fld(f.alloc[ch, sb], nb);
    if chs < f.nch then f.alloc[1, sb] := f.alloc[0, sb];
    for ch := 0 to f.nch - 1 do
      if f.layer = 1 then begin if f.alloc[ch, sb] = 15 then begin f.why := 1; Exit; end; end
      else if (f.alloc[ch, sb] <> 0) and (QClass(f.table, sb, f.alloc[ch, sb]).levels < 0) then
      begin f.why := 1; Exit; end;
  end;
  if f.layer = 2 then
    for sb := 0 to f.sblimit - 1 do
      for ch := 0 to f.nch - 1 do
        if f.alloc[ch, sb] <> 0 then Fld(f.scfsi[ch, sb], 2);
  if w = nil then f.crcEnd := r.pos;
  if not Fits then begin f.why := 3; Exit; end;
  { scale factors }
  for sb := 0 to f.sblimit - 1 do
    for ch := 0 to f.nch - 1 do
      if f.alloc[ch, sb] <> 0 then
      begin
        if f.layer = 1 then Fld(f.scf[ch, sb, 0], 6)
        else
          case f.scfsi[ch, sb] of
            0: begin Fld(f.scf[ch, sb, 0], 6); Fld(f.scf[ch, sb, 1], 6); Fld(f.scf[ch, sb, 2], 6); end;
            1: begin Fld(f.scf[ch, sb, 0], 6); Fld(f.scf[ch, sb, 2], 6); f.scf[ch, sb, 1] := f.scf[ch, sb, 0]; end;
            2: begin Fld(f.scf[ch, sb, 0], 6); f.scf[ch, sb, 1] := f.scf[ch, sb, 0]; f.scf[ch, sb, 2] := f.scf[ch, sb, 0]; end;
          else begin Fld(f.scf[ch, sb, 0], 6); Fld(f.scf[ch, sb, 1], 6); f.scf[ch, sb, 2] := f.scf[ch, sb, 1]; end;
          end;
      end;
  if not Fits then begin f.why := 3; Exit; end;
  { samples }
  if f.layer = 1 then
  begin
    for s := 0 to 11 do
      for sb := 0 to 31 do
      begin
        if sb < f.bound then chs := f.nch else chs := 1;
        for ch := 0 to chs - 1 do
          if f.alloc[ch, sb] <> 0 then Fld(f.smp[ch, sb, s], f.alloc[ch, sb] + 1);
        if chs < f.nch then f.smp[1, sb, s] := f.smp[0, sb, s];
      end;
  end
  else
    for gr := 0 to 11 do
      for sb := 0 to f.sblimit - 1 do
      begin
        if sb < f.bound then chs := f.nch else chs := 1;
        for ch := 0 to chs - 1 do
          if f.alloc[ch, sb] <> 0 then
          begin
            q := QClass(f.table, sb, f.alloc[ch, sb]);
            if q.levels > 0 then
            begin
              l := q.levels;
              if w = nil then
              begin
                code := Integer(r.Get(q.bits));
                if code >= l * l * l then
                begin
                  { a code word above what its levels allow (some encoders
                    write them): kept as it is, the other two marked -1 }
                  f.smp[ch, sb, gr * 3] := code;
                  f.smp[ch, sb, gr * 3 + 1] := -1; f.smp[ch, sb, gr * 3 + 2] := -1;
                  Inc(f.oddCodes);
                end
                else
                  for k := 0 to 2 do
                  begin
                    f.smp[ch, sb, gr * 3 + k] := code mod l;
                    code := code div l;
                  end;
              end
              else
              begin
                if f.smp[ch, sb, gr * 3 + 1] < 0 then code := f.smp[ch, sb, gr * 3]
                else code := f.smp[ch, sb, gr * 3] + l * (f.smp[ch, sb, gr * 3 + 1] + l * f.smp[ch, sb, gr * 3 + 2]);
                w^.Put(Cardinal(code), q.bits);
              end;
            end
            else
              for k := 0 to 2 do Fld(f.smp[ch, sb, gr * 3 + k], q.bits);
          end;
        if chs < f.nch then
          for b := 0 to 2 do f.smp[1, sb, gr * 3 + b] := f.smp[0, sb, gr * 3 + b];
        if (w = nil) and (r.pos > limit) then begin f.why := 3; Exit; end;
      end;
  if not Fits then begin f.why := 3; Exit; end;
  if w = nil then f.endBit := Integer(r.pos);
  Result := True;
end;

function ParseL12(const d: TBytes; pos, len: Int64; const hd: TMpegHeader; out f: TL12Frame): Boolean;
var r: TBitReader; first: Integer;
begin
  f := Default(TL12Frame);
  Result := False;
  if (hd.layer = 3) or (len < 4 + 2 * Ord(hd.hasCrc)) then Exit;
  f.layer := hd.layer;
  f.nch := hd.channels;
  if f.layer = 1 then begin f.sblimit := 32; f.table := -1; end
  else L2Table(hd, len, f.table, f.sblimit);
  if hd.mode = 1 then f.bound := 4 * (hd.modeExt + 1) else f.bound := 32;
  if f.bound > f.sblimit then f.bound := f.sblimit;
  first := 4 + 2 * Ord(hd.hasCrc);
  r.Init(d, pos, len);
  r.pos := (pos + first) * 8;
  Result := Walk(f, r, nil, (pos + len) * 8);
  if Result then
  begin
    f.endBit := f.endBit - Integer(pos * 8);
    f.crcBits := Integer(f.crcEnd - (pos + first) * 8);
  end;
end;

procedure WriteL12(const f: TL12Frame; var w: TBitWriter);
var g: TL12Frame; r: TBitReader;
begin
  g := f;
  r := Default(TBitReader);
  Walk(g, r, @w, High(Int64));
end;

end.
