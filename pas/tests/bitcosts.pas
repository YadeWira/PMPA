{ Where the bits of the codec stream go, by part, for the files given:
  built with -dPMPA_COSTS. A tool for tuning the model, not a test.

    bitcosts FILE... }
program bitcosts;
{$I ../pmpa.inc}
uses SysUtils, Classes, pmpacodec;

var
  i, k: Integer; f: TFileStream; d, s: TBytes; total, inBytes: Double;
begin
  inBytes := 0;
  DropInput := StrToIntDef(GetEnvironmentVariable('PMPA_DROP'), 0);
  for i := 1 to ParamCount do
  begin
    f := TFileStream.Create(ParamStr(i), fmOpenRead or fmShareDenyNone);
    try
      d := nil; SetLength(d, f.Size);
      if f.Size > 0 then f.ReadBuffer(d[0], f.Size);
    finally
      f.Free;
    end;
    { not verified: the tool measures, the tests check }
    s := EncodeAs(d, STREAM_VERSION);
    if s = nil then Continue;
    inBytes := inBytes + Length(d);
  end;
  total := 0;
  for k := 0 to High(Costs) do total := total + Costs[k];
  for k := 0 to High(Costs) do
    Writeln(Format('%-14s %12.0f B  %6.2f%% of the stream  %6.2f%% of the input',
      [COST_NAMES[k], Costs[k] / 8, 100 * Costs[k] / total, 100 * Costs[k] / 8 / inBytes]));
  Writeln(Format('%-14s %12.0f B  of %.0f B in (%.2f%%)', ['total', total / 8, inBytes, 100 * total / 8 / inBytes]));
end.
