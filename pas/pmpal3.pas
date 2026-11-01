{ Layer 3, Layer III: a frame's side information, read and written bit for
  bit, and where its main data lies.

  A Layer III frame is its header, a CRC if the header says so, the side
  information (17 or 32 bytes in MPEG-1, 9 or 17 in MPEG-2 and 2.5), and
  slots. The main data of a frame (scalefactors and Huffman-coded values,
  granule by granule, channel by channel) does not have to be in its own
  slots: it starts main_data_begin bytes before them, in the slots of the
  frames before (the bit reservoir), and ends at the latest where the
  frame's slots end. Laid end to end, the slots of a run of frames are one
  stream of bytes, the slot stream; the main data of each frame is a range
  of bits in it, and whatever no frame claims is filler (ancillary data,
  padding, or what a frame cut away left behind).

  Reading the side information and writing it back gives the same bits:
  every field is kept, those that only some block types have included. }
unit pmpal3;

{$I pmpa.inc}
{$ifdef PMPA_FAST}
  {$R-}{$Q-}
{$else}
  {$ifopt R-}{$fatal pmpal3: range checks ($R+) are mandatory}{$endif}
  {$ifopt Q-}{$fatal pmpal3: overflow checks ($Q+) are mandatory}{$endif}
{$endif}

interface

uses SysUtils, pmpampeg;

type
  TBitReader = record
    d: TBytes;
    pos, limit: Int64;        { in bits }
    procedure Init(const data: TBytes; firstByte, lenBytes: Int64);
    { n <= 32 bits, most significant first; zeros past the limit }
    function Get(n: Integer): Cardinal;
  end;

  TBitWriter = record
    d: TBytes;
    pos: Int64;               { in bits }
    procedure Init(bytes: Integer);
    procedure Put(v: Cardinal; n: Integer);
  end;

  TGranuleInfo = record
    part23: Integer;          { 12 bits: the granule's scalefactors and Huffman data }
    bigValues: Integer;       { 9 }
    globalGain: Integer;      { 8 }
    sfCompress: Integer;      { 4 in MPEG-1, 9 in MPEG-2 and 2.5 }
    winSwitch: Integer;       { 1 }
    blockType: Integer;       { 2, when winSwitch }
    mixed: Integer;           { 1, when winSwitch }
    table: array[0..2] of Integer;     { 5 bits each; 2 of them when winSwitch }
    subGain: array[0..2] of Integer;   { 3 bits each, when winSwitch }
    region0, region1: Integer;         { 4 and 3 bits, when not winSwitch }
    preflag: Integer;         { 1, MPEG-1 only }
    sfScale: Integer;         { 1 }
    count1Table: Integer;     { 1 }
  end;

  TSideInfo = record
    nGr, nCh: Integer;
    lsf: Boolean;             { MPEG-2 or 2.5 }
    mainDataBegin: Integer;   { 9 bits in MPEG-1, 8 otherwise }
    privateBits: Integer;     { 5 or 3 in MPEG-1, 1 or 2 otherwise }
    scfsi: array[0..1, 0..3] of Integer;   { MPEG-1 only }
    gr: array[0..1, 0..1] of TGranuleInfo; { [granule, channel] }
  end;

{ an empty side information of the shape hd's frames have (granules,
  channels, MPEG-1 or not) }
procedure InitSideInfo(const hd: TMpegHeader; out si: TSideInfo);
{ the side information at byte `first` of d, for a frame with header hd
  (Layer III); the caller checks that its sideInfoBytes are there }
procedure ReadSideInfo(const d: TBytes; first: Int64; const hd: TMpegHeader; out si: TSideInfo);
{ the side information's bytes }
function WriteSideInfo(const si: TSideInfo; const hd: TMpegHeader): TBytes;
{ the bits of main data the side information declares: the sum of part23 }
function MainDataBits(const si: TSideInfo): Integer;
{ where the slots start in a Layer III frame: after the header, the CRC and
  the side information }
function SlotsOffset(const hd: TMpegHeader): Integer;
{ MPEG audio's CRC-16 (polynomial $8005, starting at $FFFF) over the header's
  last 16 bits and then `bits` bits of d from byte `first` }
function MpegCrc(h: UInt32; const d: TBytes; first: Int64; bits: Integer): Integer;

implementation

procedure TBitReader.Init(const data: TBytes; firstByte, lenBytes: Int64);
begin
  d := data; pos := firstByte * 8; limit := (firstByte + lenBytes) * 8;
end;

function TBitReader.Get(n: Integer): Cardinal;
var i: Integer;
begin
  Result := 0;
  for i := 1 to n do
  begin
    Result := Result shl 1;
    if pos < limit then
      Result := Result or Cardinal((d[pos shr 3] shr (7 - (pos and 7))) and 1);
    Inc(pos);
  end;
end;

procedure TBitWriter.Init(bytes: Integer);
begin
  d := nil; SetLength(d, bytes); pos := 0;
  if bytes > 0 then FillChar(d[0], bytes, 0);
end;

procedure TBitWriter.Put(v: Cardinal; n: Integer);
var i: Integer;
begin
  for i := n - 1 downto 0 do
  begin
    if ((v shr i) and 1) <> 0 then
      d[pos shr 3] := d[pos shr 3] or (1 shl (7 - (pos and 7)));
    Inc(pos);
  end;
end;

procedure InitSideInfo(const hd: TMpegHeader; out si: TSideInfo);
begin
  si := Default(TSideInfo);
  si.lsf := hd.ver <> mvMpeg1;
  si.nCh := hd.channels;
  if si.lsf then si.nGr := 1 else si.nGr := 2;
end;

{ the same code reads and writes: `w` nil reads from r, else writes to w }
procedure Field(var v: Integer; n: Integer; var r: TBitReader; w: Pointer);
type PBitWriter = ^TBitWriter;
begin
  if w = nil then v := Integer(r.Get(n))
  else PBitWriter(w)^.Put(Cardinal(v), n);
end;

procedure Walk(var si: TSideInfo; var r: TBitReader; w: Pointer);
var g, c, b, i: Integer;
begin
  if si.lsf then
  begin
    Field(si.mainDataBegin, 8, r, w);
    Field(si.privateBits, si.nCh, r, w);
  end
  else
  begin
    Field(si.mainDataBegin, 9, r, w);
    if si.nCh = 1 then Field(si.privateBits, 5, r, w) else Field(si.privateBits, 3, r, w);
    for c := 0 to si.nCh - 1 do
      for b := 0 to 3 do Field(si.scfsi[c, b], 1, r, w);
  end;
  for g := 0 to si.nGr - 1 do
    for c := 0 to si.nCh - 1 do
      with si.gr[g, c] do
      begin
        Field(part23, 12, r, w);
        Field(bigValues, 9, r, w);
        Field(globalGain, 8, r, w);
        if si.lsf then Field(sfCompress, 9, r, w) else Field(sfCompress, 4, r, w);
        Field(winSwitch, 1, r, w);
        if winSwitch = 1 then
        begin
          Field(blockType, 2, r, w);
          Field(mixed, 1, r, w);
          for i := 0 to 1 do Field(table[i], 5, r, w);
          for i := 0 to 2 do Field(subGain[i], 3, r, w);
        end
        else
        begin
          for i := 0 to 2 do Field(table[i], 5, r, w);
          Field(region0, 4, r, w);
          Field(region1, 3, r, w);
        end;
        if not si.lsf then Field(preflag, 1, r, w);
        Field(sfScale, 1, r, w);
        Field(count1Table, 1, r, w);
      end;
end;

procedure ReadSideInfo(const d: TBytes; first: Int64; const hd: TMpegHeader; out si: TSideInfo);
var r: TBitReader;
begin
  InitSideInfo(hd, si);
  r.Init(d, first, hd.sideInfoBytes);
  Walk(si, r, nil);
end;

function WriteSideInfo(const si: TSideInfo; const hd: TMpegHeader): TBytes;
var w: TBitWriter; r: TBitReader; s: TSideInfo;
begin
  s := si;
  r := Default(TBitReader);
  w.Init(hd.sideInfoBytes);
  Walk(s, r, @w);
  Result := w.d;
end;

function MainDataBits(const si: TSideInfo): Integer;
var g, c: Integer;
begin
  Result := 0;
  for g := 0 to si.nGr - 1 do
    for c := 0 to si.nCh - 1 do Inc(Result, si.gr[g, c].part23);
end;

function SlotsOffset(const hd: TMpegHeader): Integer;
begin
  Result := 4 + hd.sideInfoBytes;
  if hd.hasCrc then Inc(Result, 2);
end;

function MpegCrc(h: UInt32; const d: TBytes; first: Int64; bits: Integer): Integer;
var crc, i, bit: Integer; r: TBitReader;

  procedure Feed(b: Integer);
  var top: Integer;
  begin
    top := (crc shr 15) and 1;
    crc := (crc shl 1) and $FFFF;
    if (top xor b) <> 0 then crc := crc xor $8005;
  end;

begin
  crc := $FFFF;
  for i := 15 downto 0 do Feed(Integer((h shr i) and 1));
  r.Init(d, first, (bits + 7) div 8);
  for i := 1 to bits do
  begin
    bit := Integer(r.Get(1));
    Feed(bit);
  end;
  Result := crc;
end;

end.
