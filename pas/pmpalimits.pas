{ The limits, in one place: the codec applies them when writing a stream,
  and the decoder applies the same ones before decoding anything. Why each
  one is what it is: doc/POLICY.md. }
unit pmpalimits;

{$I pmpa.inc}

interface

const
  { the smallest codec stream: the version byte, the original's length (one
    byte at least) and the arithmetic coder's 4 closing bytes }
  MIN_PAYLOAD = 6;

  { How many times its payload a declared original size may be: so that a
    tiny file cannot declare a huge output before anything is decoded. A
    last-resort cap, PJA's; not measured on MPEG audio yet (doc/POLICY.md),
    and the user's --max-output still applies. }
  MAX_EXPANSION_RATIO = 65536;

  { a free-format frame's length, as the stream may give it }
  MAX_FREE_FRAME = 1 shl 16;

implementation

end.
