# Samples

Every sample here is synthetic: generated for PMPA's tests, never taken from
a real recording, so that its license is PMPA's own.

They are made by `scripts/mksamples.py`: tones, sweeps and noise from
ffmpeg's lavfi sources, encoded by lame, twolame and ffmpeg's encoders, and
Layer I by the script itself. `tests/odd` wraps them in what real files
carry: tags, junk, a frame cut short, concatenated streams.
