{ The info provider (pmpainfo) of the .pmpa: the container (doc/FORMAT.md)
  and the codec stream inside it (doc/CODEC.md), read as those documents
  lay them out, without decoding it.

  Container: its version, flags, the original's size, hash and extension.
  Stream: its version, the original's length it declares, and for
  versions 7 and 8 its bands (where each starts in the file and how many
  bytes of the stream it takes). }
unit pmpainfopmpa;

{$I pmpa.inc}
{$ifopt R-}{$fatal pmpainfopmpa: range checks ($R+) are mandatory}{$endif}
{$ifopt Q-}{$fatal pmpainfopmpa: overflow checks ($Q+) are mandatory}{$endif}

interface

uses SysUtils, pmpainfo;

function ProbePmpa(const d: TBytes): Boolean;
procedure DescribePmpa(const d: TBytes; n: TInfoNode);
{ How many bands the stream has (1 before version 7); 0 when it has none
  (stored) or it cannot be told. For --stats. }
function StreamBands(const s: TBytes): Integer;

implementation

uses pmpaformat, pmpacodec;

const
  MAX_LISTED_BANDS = 64;

function ProbePmpa(const d: TBytes): Boolean;
var i: Integer;
begin
  Result := Length(d) >= 4;
  if Result then
    for i := 0 to 3 do if d[i] <> MAGIC[i] then Exit(False);
end;

{ pmpacodec's varint (7 bits a byte, the low ones first); -1 if it does
  not fit or runs past the end }
function Varint(const s: TBytes; var p: SizeInt): Int64;
var shift: Integer; b: Byte;
begin
  Result := 0; shift := 0;
  repeat
    if (p >= Length(s)) or (shift > 56) then Exit(-1);
    b := s[p]; Inc(p);
    Result := Result or (Int64(b and 127) shl shift);
    Inc(shift, 7);
  until b < 128;
end;

{ the bands' table of a stream of version 7 or later: False if it is not
  whole. starts and lens have nb entries. }
function ReadBands(const s: TBytes; out total, nb: Int64; out starts, lens: array of Int64; out listed: Integer): Boolean;
var p: SizeInt; k: Int64; at, gap, len, sum: Int64;
begin
  Result := False;
  listed := 0; total := -1; nb := -1;
  if (Length(s) < 1) or (s[0] < 7) then Exit;
  p := 1;
  total := Varint(s, p);
  if total < 1 then Exit;
  nb := Varint(s, p);
  if (nb < 1) or (nb > total) then Exit;
  at := 0; sum := 0;
  k := 0;
  while k < nb do begin
    if k > 0 then begin
      gap := Varint(s, p);
      if gap < 1 then Exit;
      Inc(at, gap);
      if at >= total then Exit;
    end;
    len := Varint(s, p);
    if (len < 0) or (len > Length(s)) then Exit;
    Inc(sum, len);
    if listed <= High(starts) then begin
      starts[listed] := at; lens[listed] := len;
      Inc(listed);
    end;
    Inc(k);
  end;
  Result := sum <= Length(s) - p;
end;

function StreamBands(const s: TBytes): Integer;
var total, nb: Int64; starts, lens: array[0..0] of Int64; listed: Integer; p: SizeInt;
begin
  Result := 0;
  if Length(s) < 1 then Exit;
  if s[0] < 7 then begin
    p := 1;
    if Varint(s, p) >= 1 then Result := 1;
    Exit;
  end;
  if ReadBands(s, total, nb, starts, lens, listed) and (nb <= High(Integer)) then Result := Integer(nb);
end;

procedure DescribePmpa(const d: TBytes; n: TInfoNode);
var p: TPmpa; r: TPmpaResult; c, st, bl: TInfoNode; flags: string; total, nb: Int64;
    starts, lens: array[0..MAX_LISTED_BANDS - 1] of Int64; listed, k: Integer; q: SizeInt;
begin
  n.Str('format', '.pmpa');
  n.Num('size', Length(d));
  c := n.Obj('container');
  if Length(d) >= 6 then begin
    c.Num('version', d[4]);
    flags := '';
    if d[5] and FLAG_STORED <> 0 then flags := 'stored';
    if d[5] and not KNOWN_FLAGS <> 0 then begin
      if flags <> '' then flags := flags + ', ';
      flags := flags + 'unknown ' + IntToStr(d[5] and not KNOWN_FLAGS);
    end;
    if flags = '' then flags := 'none';
    c.Str('flags', flags);
  end;
  r := Open(d, p);
  c.Bool('valid', r.Ok);
  if not r.Ok then begin
    c.Str('error', r.Text);
    Exit;
  end;
  c.Num('original_size', p.orig_size);
  c.Str('blake3_128', HexBytes(p.hash));
  c.Str('extension', p.ext);
  c.Bool('stored', p.stored);
  c.Num('payload_size', Length(p.payload));
  st := n.Obj('stream');
  if p.stored then begin
    st.Str('kind', 'none: the original stored as is');
    Exit;
  end;
  if Length(p.payload) = 0 then begin
    st.Str('error', 'empty');
    Exit;
  end;
  st.Num('version', p.payload[0]);
  if p.payload[0] > STREAM_VERSION then begin
    st.Str('error', 'a later version than this pmpa reads (' + IntToStr(STREAM_VERSION) + ')');
    Exit;
  end;
  if p.payload[0] < 7 then begin
    q := 1;
    total := Varint(p.payload, q);
    st.Num('declared_length', total);
    st.Num('bands', 1);
    Exit;
  end;
  if not ReadBands(p.payload, total, nb, starts, lens, listed) then begin
    st.Str('error', 'the bands'' table is not whole');
    Exit;
  end;
  st.Num('declared_length', total);
  st.Num('bands', nb);
  bl := st.List('band_list');
  for k := 0 to listed - 1 do
    with bl.Obj do begin
      Num('starts_at', starts[k]);
      Num('stream_bytes', lens[k]);
    end;
  for k := 0 to listed - 1 do
    bl.items[k].line := 'from ' + IntToStr(starts[k]) + ', ' + IntToStr(lens[k]) + ' B of stream';
  if nb > listed then st.Num('bands_not_listed', nb - listed);
end;

initialization
  RegisterInfoProvider('pmpa', @ProbePmpa, @DescribePmpa);
end.
