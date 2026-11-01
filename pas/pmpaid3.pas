{ Layer 3, ID3v2: the pictures inside a tag (album covers), where their
  bytes are in it.

  An ID3v2 tag keeps a picture in an APIC frame (v2.3, v2.4) or a PIC frame
  (v2.2): a text encoding, a MIME type (v2.2: three letters), a picture
  type, a description, then the picture's bytes. This unit finds those
  whose bytes are a JPEG (by their first bytes, whatever the MIME type
  says: "image/jpg" is common) and says where they are in the file.

  Unsynchronisation inserts a 0 after some FF bytes: over the whole tag
  (v2.2, v2.3) or over one frame (v2.4). A picture's bytes in the file are
  then a range of raw bytes whose undone form is the JPEG; Unsync gives the
  raw form back from the JPEG, in one of two ways (MODE_*), and the caller
  keeps a picture only if one of them gives exactly the file's bytes.
  Compressed or encrypted frames are left alone. Anything this unit does
  not understand is no picture: the tag's bytes are kept as they are. }
unit pmpaid3;

{$I pmpa.inc}
{$ifopt R-}{$fatal pmpaid3: range checks ($R+) are mandatory}{$endif}
{$ifopt Q-}{$fatal pmpaid3: overflow checks ($Q+) are mandatory}{$endif}

interface

uses SysUtils;

const
  { how the JPEG's bytes are in the file }
  MODE_PLAIN = 0;       { as they are }
  MODE_UNSYNC = 1;      { a 0 after each FF that comes before a byte of E0 or more, or a 0 }
  MODE_UNSYNC_ALL = 2;  { a 0 after each FF }
  MAX_PICTURES = 64;

type
  TPicture = record
    rawStart, rawLen: Int64;      { in the file }
    mode: Integer;                { MODE_*, the one that gives the raw bytes back }
    jpeg: TBytes;                 { the picture's bytes, unsynchronisation undone }
  end;
  TPictures = array of TPicture;

{ the JPEG pictures of the ID3v2 tag at d[tagStart], tagLen bytes in all
  (its header included), in the order they are in the file; only those
  whose raw bytes one of the modes gives back }
function FindPictures(const d: TBytes; tagStart, tagLen: Int64): TPictures;
{ the raw form of a picture's bytes in mode m }
function Unsync(const jpeg: TBytes; m: Integer): TBytes;

implementation

function Syncsafe(const d: TBytes; at: Int64): Int64;
begin
  Result := (Int64(d[at] and $7F) shl 21) or (Int64(d[at + 1] and $7F) shl 14) or
            (Int64(d[at + 2] and $7F) shl 7) or Int64(d[at + 3] and $7F);
end;

function Be32(const d: TBytes; at: Int64): Int64;
begin
  Result := (Int64(d[at]) shl 24) or (Int64(d[at + 1]) shl 16) or (Int64(d[at + 2]) shl 8) or Int64(d[at + 3]);
end;

function Unsync(const jpeg: TBytes; m: Integer): TBytes;
var i, n: Integer;
begin
  Result := nil;
  SetLength(Result, 2 * Length(jpeg));
  n := 0;
  for i := 0 to High(jpeg) do
  begin
    Result[n] := jpeg[i]; Inc(n);
    if (m <> MODE_PLAIN) and (jpeg[i] = $FF) then
      if (m = MODE_UNSYNC_ALL) or
         ((i < High(jpeg)) and ((jpeg[i + 1] >= $E0) or (jpeg[i + 1] = 0))) then
      begin
        Result[n] := 0; Inc(n);
      end;
  end;
  SetLength(Result, n);
end;

type
  { a stretch of the tag with unsynchronisation undone, and where each of
    its bytes was in the file }
  TView = record
    b: TBytes;
    at: array of Int64;
    n: Integer;
  end;

{ d[first .. first + len - 1] as it is, or with every FF 00 made FF }
procedure MakeView(const d: TBytes; first, len: Int64; undo: Boolean; out v: TView);
var i: Int64;
begin
  v.b := nil; v.at := nil;
  SetLength(v.b, len); SetLength(v.at, len + 1);
  v.n := 0;
  i := first;
  while i < first + len do
  begin
    v.b[v.n] := d[i]; v.at[v.n] := i; Inc(v.n);
    if undo and (d[i] = $FF) and (i + 1 < first + len) and (d[i + 1] = 0) then Inc(i);
    Inc(i);
  end;
  v.at[v.n] := first + len;       { where the stretch ends }
end;

{ the bytes of v from k to the end of a frame at k + size (exclusive): the
  picture inside a picture frame's content, from its text encoding on;
  -1 if it is not one this unit takes }
function PictureStart(const c: TBytes; ver: Integer): Integer;
var k, enc: Integer;
begin
  Result := -1;
  if Length(c) < 4 then Exit;
  enc := c[0];
  if enc > 3 then Exit;
  if ver = 2 then k := 4                       { encoding, a three-letter format }
  else
  begin
    k := 1;
    while (k < Length(c)) and (c[k] <> 0) do Inc(k);   { the MIME type }
    Inc(k);
  end;
  Inc(k);                                      { the picture type }
  if k >= Length(c) then Exit;
  if (enc = 1) or (enc = 2) then
  begin
    { UTF-16: two zero bytes, at an even offset from the description's start }
    while (k + 1 < Length(c)) and ((c[k] <> 0) or (c[k + 1] <> 0)) do Inc(k, 2);
    Inc(k, 2);
  end
  else
  begin
    while (k < Length(c)) and (c[k] <> 0) do Inc(k);
    Inc(k);
  end;
  if k + 3 > Length(c) then Exit;
  if (c[k] <> $FF) or (c[k + 1] <> $D8) or (c[k + 2] <> $FF) then Exit;
  Result := k;
end;

function FindPictures(const d: TBytes; tagStart, tagLen: Int64): TPictures;
var
  ver, tflags, hdr, fflags, k, m, start: Integer; size, bodyLen, pos, fsize, rawA, rawB, extLen: Int64;
  whole, frameView: TView; tagUnsync, frameUnsync, same: Boolean;
  id: array[0..3] of Byte; content, raw: TBytes; p: TPicture; n, j: Integer;
begin
  Result := nil;
  n := 0;
  if (tagLen < 10) or (tagStart + tagLen > Length(d)) then Exit;
  if (d[tagStart] <> Ord('I')) or (d[tagStart + 1] <> Ord('D')) or (d[tagStart + 2] <> Ord('3')) then Exit;
  ver := d[tagStart + 3];
  if (ver < 2) or (ver > 4) then Exit;
  tflags := d[tagStart + 5];
  size := Syncsafe(d, tagStart + 6);
  bodyLen := size;
  if 10 + bodyLen > tagLen then Exit;
  tagUnsync := ((tflags and $80) <> 0) and (ver <= 3);
  MakeView(d, tagStart + 10, bodyLen, tagUnsync, whole);
  pos := 0;
  { the extended header }
  if (ver >= 3) and ((tflags and $40) <> 0) then
  begin
    if whole.n < 4 then Exit;
    if ver = 3 then extLen := 4 + Be32(whole.b, 0) else extLen := Syncsafe(whole.b, 0);
    if (extLen < 4) or (extLen > whole.n) then Exit;
    pos := extLen;
  end;
  if ver = 2 then hdr := 6 else hdr := 10;
  while pos + hdr <= whole.n do
  begin
    for j := 0 to 3 do id[j] := 0;
    if ver = 2 then
    begin
      for j := 0 to 2 do id[j] := whole.b[pos + j];
      fsize := (Int64(whole.b[pos + 3]) shl 16) or (Int64(whole.b[pos + 4]) shl 8) or whole.b[pos + 5];
      fflags := 0;
    end
    else
    begin
      for j := 0 to 3 do id[j] := whole.b[pos + j];
      if ver = 4 then fsize := Syncsafe(whole.b, pos + 4) else fsize := Be32(whole.b, pos + 4);
      fflags := (whole.b[pos + 8] shl 8) or whole.b[pos + 9];
    end;
    if (id[0] = 0) or (fsize <= 0) or (pos + hdr + fsize > whole.n) then Break;   { padding, or the end }
    if ((ver = 2) and (id[0] = Ord('P')) and (id[1] = Ord('I')) and (id[2] = Ord('C'))) or
       ((ver >= 3) and (id[0] = Ord('A')) and (id[1] = Ord('P')) and (id[2] = Ord('I')) and (id[3] = Ord('C'))) then
    begin
      { the content's first byte and stretch, past the frame's own extras }
      k := 0;
      if ver = 3 then
      begin
        if (fflags and $00C0) <> 0 then begin Inc(pos, hdr + fsize); Continue; end;  { compressed, encrypted }
        if (fflags and $0020) <> 0 then k := 1;                                      { a group }
      end
      else if ver = 4 then
      begin
        if (fflags and $000C) <> 0 then begin Inc(pos, hdr + fsize); Continue; end;  { compressed, encrypted }
        if (fflags and $0040) <> 0 then Inc(k);                                      { a group }
        if (fflags and $0001) <> 0 then Inc(k, 4);                                   { the data length }
      end;
      frameUnsync := (ver = 4) and (((fflags and $0002) <> 0) or ((tflags and $80) <> 0));
      if k < fsize then
      begin
        { the content, unsynchronisation undone, and where each byte was }
        rawA := whole.at[pos + hdr + k];
        rawB := whole.at[pos + hdr + fsize];
        MakeView(d, rawA, rawB - rawA, frameUnsync or tagUnsync, frameView);
        content := Copy(frameView.b, 0, frameView.n);
        start := PictureStart(content, ver);
        if (start >= 0) and (n < MAX_PICTURES) then
        begin
          p.rawStart := frameView.at[start];
          p.rawLen := frameView.at[frameView.n] - p.rawStart;
          p.jpeg := Copy(content, start, Length(content) - start);
          { the mode that gives the file's bytes back, if one does }
          p.mode := -1;
          for m := MODE_PLAIN to MODE_UNSYNC_ALL do
            if p.mode < 0 then
            begin
              if (m = MODE_PLAIN) and (frameUnsync or tagUnsync) then Continue;
              if (m <> MODE_PLAIN) and not (frameUnsync or tagUnsync) then Continue;
              raw := Unsync(p.jpeg, m);
              same := Length(raw) = p.rawLen;
              if same then
                for j := 0 to High(raw) do
                  if raw[j] <> d[p.rawStart + j] then begin same := False; Break; end;
              if same then p.mode := m;
            end;
          if p.mode >= 0 then
          begin
            SetLength(Result, n + 1);
            Result[n] := p;
            Inc(n);
          end;
        end;
      end;
    end;
    Inc(pos, hdr + fsize);
  end;
end;

end.
