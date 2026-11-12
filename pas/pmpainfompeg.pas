{ The info provider (pmpainfo) of MPEG audio: what pmpampeg's scanner finds
  in the file, as the codec sees it. The frames by stream (version, layer,
  sample rate, channel mode), their bit rates, CRCs and length in time; the
  tags (ID3v2, ID3v1, APE, Lyrics3) with their place and size, and in each
  ID3v2 tag the JPEG pictures PMPA takes through PJA; the bytes that are
  neither (a container's headers, junk), and the container when there is
  one PMPA knows (WAV, MP4, MPEG-PS).

  Nothing of what the tags say is shown: only how many bytes they take. }
unit pmpainfompeg;

{$I pmpa.inc}
{$ifopt R-}{$fatal pmpainfompeg: range checks ($R+) are mandatory}{$endif}
{$ifopt Q-}{$fatal pmpainfompeg: overflow checks ($Q+) are mandatory}{$endif}

interface

uses SysUtils, pmpainfo;

function ProbeMpeg(const d: TBytes): Boolean;
procedure DescribeMpeg(const d: TBytes; n: TInfoNode);

implementation

uses pmpampeg, pmpaid3;

const
  { past these, counted and not listed }
  MAX_LISTED_STREAMS = 32;
  MAX_LISTED_TAGS = 64;
  MAX_LISTED_RAW = 32;

  MODE_NAMES: array[0..3] of string = ('stereo', 'joint stereo', 'dual channel', 'mono');

type
  TStreamSum = record
    ver: TMpegVersion;
    layer, rate, mode: Integer;
    frames, bytes, crcs, freeFormat: Int64;
    minRate, maxRate: Integer;
    sampleCount: Int64;
  end;

function ProbeMpeg(const d: TBytes): Boolean;
var S: TMpegScan;
begin
  ScanMpeg(d, S);
  Result := S.frames > 0;
end;

function Ascii4(const d: TBytes; p: Int64; const s: string): Boolean;
var i: Integer;
begin
  Result := p + 4 <= Length(d);
  if Result then
    for i := 0 to 3 do if d[p + i] <> Ord(s[i + 1]) then Exit(False);
end;

{ the container around the frames, when the file starts as one PMPA knows }
function ContainerOf(const d: TBytes): string;
begin
  Result := '';
  if Ascii4(d, 0, 'RIFF') and Ascii4(d, 8, 'WAVE') then Result := 'RIFF WAVE'
  else if Ascii4(d, 4, 'ftyp') then Result := 'MP4 (ISO base media)'
  else if (Length(d) >= 4) and (d[0] = 0) and (d[1] = 0) and (d[2] = 1) and (d[3] = $BA) then
    Result := 'MPEG program stream';
end;

function StreamLine(const t: TStreamSum): string;
begin
  Result := VersionName(t.ver) + ' Layer ' + StringOfChar('I', t.layer) + ', ' + IntToStr(t.rate) + ' Hz, ' +
            MODE_NAMES[t.mode] + ': ' + IntToStr(t.frames) + ' frames';
  if t.freeFormat = t.frames then Result := Result + ', free format'
  else if t.minRate = t.maxRate then Result := Result + ', ' + IntToStr(t.minRate) + ' kbit/s'
  else Result := Result + ', ' + IntToStr(t.minRate) + '-' + IntToStr(t.maxRate) + ' kbit/s';
  if t.crcs > 0 then Result := Result + ', ' + IntToStr(t.crcs) + ' with CRC';
end;

procedure DescribeMpeg(const d: TBytes; n: TInfoNode);
var
  S: TMpegScan; hd: TMpegHeader; i, k, nStreams, nTags, nRaw: Integer; sums: array of TStreamSum;
  streams, tags, raws, it, pl, meta: TInfoNode; p: TPictures; secs: Double;
  tagBytes: array[TSegmentKind] of Int64; picBytes, picCount: Int64; c, line: string; sk: TSegmentKind;
begin
  ScanMpeg(d, S);
  n.Str('format', 'MPEG audio');
  n.Num('size', Length(d));
  c := ContainerOf(d);
  if c <> '' then n.Str('container', c);
  sums := nil;
  nTags := 0; nRaw := 0; picBytes := 0; picCount := 0;
  for sk := Low(TSegmentKind) to High(TSegmentKind) do tagBytes[sk] := 0;
  tags := TInfoNode.Create(ikList, 'tags');
  raws := TInfoNode.Create(ikList, 'other_bytes');
  try
    for i := 0 to S.count - 1 do
      case S.segments[i].kind of
        skFrame: begin
          if not DecodeHeader(HeaderAt(d, S.segments[i].offset), hd) then Continue;
          k := 0;
          while (k < Length(sums)) and not ((sums[k].ver = hd.ver) and (sums[k].layer = hd.layer) and
                (sums[k].rate = hd.sampleRate) and (sums[k].mode = hd.mode)) do Inc(k);
          if k = Length(sums) then begin
            SetLength(sums, k + 1);
            sums[k] := Default(TStreamSum);
            sums[k].ver := hd.ver; sums[k].layer := hd.layer; sums[k].rate := hd.sampleRate; sums[k].mode := hd.mode;
            sums[k].minRate := MaxInt; sums[k].maxRate := 0;
          end;
          Inc(sums[k].frames);
          Inc(sums[k].bytes, S.segments[i].length);
          Inc(sums[k].sampleCount, hd.samplesPerFrame);
          if hd.hasCrc then Inc(sums[k].crcs);
          if hd.bitrateIndex = 0 then Inc(sums[k].freeFormat)
          else begin
            if hd.bitrate < sums[k].minRate then sums[k].minRate := hd.bitrate;
            if hd.bitrate > sums[k].maxRate then sums[k].maxRate := hd.bitrate;
          end;
        end;
        skRaw: begin
          Inc(nRaw);
          if nRaw <= MAX_LISTED_RAW then begin
            it := raws.Obj;
            it.Num('offset', S.segments[i].offset);
            it.Num('length', S.segments[i].length);
            it.line := 'at ' + IntToStr(S.segments[i].offset) + ', ' + IntToStr(S.segments[i].length) + ' B';
          end;
        end;
      else
        Inc(nTags);
        Inc(tagBytes[S.segments[i].kind], S.segments[i].length);
        p := nil;
        if S.segments[i].kind = skID3v2 then
          p := FindPictures(d, S.segments[i].offset, S.segments[i].length);
        if nTags <= MAX_LISTED_TAGS then begin
          it := tags.Obj;
          it.Str('kind', SegmentKindName(S.segments[i].kind));
          it.Num('offset', S.segments[i].offset);
          it.Num('length', S.segments[i].length);
          line := SegmentKindName(S.segments[i].kind) + ' at ' + IntToStr(S.segments[i].offset) + ', ' +
                  IntToStr(S.segments[i].length) + ' B';
          if (S.segments[i].kind = skID3v2) and (S.segments[i].length >= 10) then begin
            it.Str('version', '2.' + IntToStr(d[S.segments[i].offset + 3]) + '.' + IntToStr(d[S.segments[i].offset + 4]));
            it.Bool('unsynchronised', d[S.segments[i].offset + 5] and $80 <> 0);
            line := line + ', version 2.' + IntToStr(d[S.segments[i].offset + 3]);
            if d[S.segments[i].offset + 5] and $80 <> 0 then line := line + ', unsynchronised';
          end;
          if Length(p) > 0 then begin
            pl := it.List('jpeg_pictures');
            for k := 0 to High(p) do begin
              with pl.Obj do begin
                Num('offset', p[k].rawStart);
                Num('length', p[k].rawLen);
                Num('mode', p[k].mode);
              end;
              pl.items[High(pl.items)].line := 'at ' + IntToStr(p[k].rawStart) + ', ' + IntToStr(p[k].rawLen) +
                ' B, mode ' + IntToStr(p[k].mode);
            end;
            line := line + ', ' + IntToStr(Length(p)) + ' JPEG picture(s)';
          end;
          it.line := line;
          { with pictures, its fields under it, not on one line }
          if Length(p) > 0 then it.line := '';
        end;
        for k := 0 to High(p) do begin
          Inc(picCount);
          Inc(picBytes, p[k].rawLen);
        end;
      end;
    { the streams }
    streams := n.List('streams');
    nStreams := Length(sums);
    secs := 0;
    for k := 0 to nStreams - 1 do begin
      if sums[k].rate > 0 then secs := secs + sums[k].sampleCount / sums[k].rate;
      if k >= MAX_LISTED_STREAMS then Continue;
      it := streams.Obj;
      it.Str('version', VersionName(sums[k].ver));
      it.Num('layer', sums[k].layer);
      it.Num('sample_rate', sums[k].rate);
      it.Str('mode', MODE_NAMES[sums[k].mode]);
      it.Num('frames', sums[k].frames);
      it.Num('bytes', sums[k].bytes);
      if sums[k].freeFormat < sums[k].frames then begin
        it.Num('min_kbps', sums[k].minRate);
        it.Num('max_kbps', sums[k].maxRate);
      end;
      it.Num('free_format_frames', sums[k].freeFormat);
      it.Num('crc_frames', sums[k].crcs);
      it.line := StreamLine(sums[k]);
    end;
    if nStreams > MAX_LISTED_STREAMS then n.Num('streams_not_listed', nStreams - MAX_LISTED_STREAMS);
    n.Num('frames', S.frames);
    n.Num('frame_bytes', S.frameBytes);
    n.Fixed('seconds', secs, 3);
    n.Add(tags);
    tags := nil;
    if nTags > MAX_LISTED_TAGS then n.Num('tags_not_listed', nTags - MAX_LISTED_TAGS);
    n.Num('jpeg_pictures', picCount);
    n.Num('jpeg_picture_bytes', picBytes);
    n.Num('other_bytes_total', S.rawBytes);
    n.Add(raws);
    raws := nil;
    if nRaw > MAX_LISTED_RAW then n.Num('other_bytes_not_listed', nRaw - MAX_LISTED_RAW);
  finally
    tags.Free;
    raws.Free;
  end;
  { the tags' sizes only: what they say is not shown }
  meta := n.Obj('metadata_bytes');
  meta.Num('id3v2', tagBytes[skID3v2]);
  meta.Num('id3v1', tagBytes[skID3v1]);
  meta.Num('ape', tagBytes[skAPE]);
  meta.Num('lyrics3', tagBytes[skLyrics3]);
  meta.line := 'ID3v2 ' + IntToStr(tagBytes[skID3v2]) + ' B, ID3v1 ' + IntToStr(tagBytes[skID3v1]) + ' B, APE ' +
               IntToStr(tagBytes[skAPE]) + ' B, Lyrics3 ' + IntToStr(tagBytes[skLyrics3]) + ' B; contents not shown';
end;

initialization
  RegisterInfoProvider('mpeg', @ProbeMpeg, @DescribeMpeg);
end.
