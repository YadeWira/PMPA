{ Layer 4: the codec stream. A whole file in, a stream out, and back.

  Stream, version 1 (doc/CODEC.md):

      version     1 B      1
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

  Bytes are coded bit by bit, in the context of the bits of the byte so
  far: alone inside frames (order 0), with the byte before in the rest
  (order 1). Order 1 inside frames cost 8% on the samples (65,536 contexts
  to learn on data near noise: 01/11/2026). This is the scaffold the layer
  models replace: version 1 knows the frames' structure, not what is inside
  them.

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

uses SysUtils, pmpampeg;

const
  STREAM_VERSION = 1;
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
function DecodeStatusName(st: TDecodeStatus): string;

implementation

uses pmpaarith, pmpalimits;

const
  LIMIT_STRUCT = 127;   { the structure (kinds, headers, lengths) is steady }
  LIMIT_BYTES = 60;
  KIND_START = 6;       { the context of the first segment's kind }

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
    lastHeader: UInt32;
    lastFree: Integer;
    prevKind: Integer;
    procedure Init(isDecoding: Boolean);
    { codes bit b (encoding) or returns the decoded bit (decoding) }
    function Bit(b: Integer; var ab: TAdaptiveBit; limit: Integer): Integer; inline;
  end;
  PModel = ^TModel;

procedure TModel.Init(isDecoding: Boolean);
var i, j, k: Integer;
begin
  decoding := isDecoding;
  for i := 0 to KIND_START do for j := 1 to 7 do kinds[i, j].Init;
  for i := 0 to 31 do for j := 0 to 1 do for k := 0 to 1 do header[i, j, k].Init;
  freeSame.Init;
  for i := 0 to 15 do freeBits[i].Init;
  for i := 1 to 63 do lenBits[i].Init;
  for i := 0 to 62 do lenLow[i].Init;
  for i := 0 to 1 do for j := 0 to 255 do for k := 1 to 255 do bytes[i, j, k].Init;
  lastHeader := 0; lastFree := 0; prevKind := KIND_START;
end;

function TModel.Bit(b: Integer; var ab: TAdaptiveBit; limit: Integer): Integer;
begin
  if decoding then Result := dec.Decode(ab.p)
  else begin enc.Encode(b, ab.p); Result := b; end;
  ab.Update(Result, limit);
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
  for i := first to first + len - 1 do
  begin
    x := d[i]; node := 1;
    for k := 7 downto 0 do
      node := node * 2 + m.Bit((x shr k) and 1, m.bytes[cls, prev * cls, node], LIMIT_BYTES);
    x := node - 256;
    d[i] := x;
    prev := x;
  end;
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

function Encode(const d: TBytes; const scan: TMpegScan): TBytes;
var
  m: PModel; work, body: TBytes; i: Integer; seg: TSegment; hd: TMpegHeader;
  n: SizeInt; freeLen: Integer;
begin
  New(m);
  try
    m^.Init(False);
    m^.enc.Init;
    work := Copy(d, 0, Length(d));
    for i := 0 to scan.count - 1 do
    begin
      seg := scan.segments[i];
      CodeKind(m^, Ord(seg.kind));
      if seg.kind = skFrame then
      begin
        CodeHeader(m^, HeaderAt(d, seg.offset));
        DecodeHeader(HeaderAt(d, seg.offset), hd);
        if hd.bitrateIndex = 0 then
        begin
          freeLen := Integer(seg.length) - hd.padding * hd.slotBytes;
          CodeFree(m^, freeLen);
        end;
        CodeBytes(m^, work, seg.offset + 4, seg.length - 4, 0);
      end
      else
      begin
        CodeLength(m^, seg.length);
        CodeBytes(m^, work, seg.offset, seg.length, 1);
      end;
    end;
    body := m^.enc.Finish;
  finally
    Dispose(m);
  end;
  Result := nil;
  SetLength(Result, 16);
  Result[0] := STREAM_VERSION; n := 1;
  PutVarint(Result, n, Length(d));
  SetLength(Result, n + Length(body));
  if Length(body) > 0 then Move(body[0], Result[n], Length(body));
end;

function DecodeFile(const s: TBytes; maxOut: Int64; out d: TBytes; threads: Integer): TDecodeStatus;
var
  m: PModel; p: SizeInt; total, pos, len: Int64; kind, freeLen: Integer;
  h: UInt32; hd: TMpegHeader;
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
  New(m);
  try
    m^.Init(True);
    m^.dec.Init(s, p);
    pos := 0;
    while pos < total do
    begin
      kind := CodeKind(m^, 0);
      if kind > Ord(High(TSegmentKind)) then begin d := nil; Exit(dsBadStream); end;
      if TSegmentKind(kind) = skFrame then
      begin
        h := CodeHeader(m^, 0);
        if not DecodeHeader(h, hd) then begin d := nil; Exit(dsBadStream); end;
        freeLen := 0;
        if hd.bitrateIndex = 0 then freeLen := CodeFree(m^, 0);
        len := FrameLength(hd, freeLen);
        if (len < 4) or (len > total - pos) then begin d := nil; Exit(dsBadStream); end;
        d[pos] := h shr 24; d[pos + 1] := (h shr 16) and $FF;
        d[pos + 2] := (h shr 8) and $FF; d[pos + 3] := h and $FF;
        CodeBytes(m^, d, pos + 4, len - 4, 0);
      end
      else
      begin
        len := CodeLength(m^, 0);
        if (len < 1) or (len > total - pos) then begin d := nil; Exit(dsBadStream); end;
        CodeBytes(m^, d, pos, len, 1);
      end;
      Inc(pos, len);
    end;
  finally
    Dispose(m);
  end;
  Result := dsOk;
end;

function EncodeFile(const d: TBytes; out s: TBytes; threads: Integer): TEncodeStatus;
var scan: TMpegScan; back: TBytes;
begin
  s := nil;
  ScanMpeg(d, scan);
  if scan.frames = 0 then Exit(esNotMpeg);
  s := Encode(d, scan);
  { the one guarantee: it has to come back }
  if (DecodeFile(s, Length(d), back) <> dsOk) or (Length(back) <> Length(d))
     or not CompareMem(@back[0], @d[0], Length(d)) then
  begin
    s := nil;
    Exit(esNotBack);
  end;
  Result := esOk;
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
