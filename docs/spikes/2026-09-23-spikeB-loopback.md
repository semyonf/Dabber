# Spike B: loopback quality over 60 s

Date: 2026-09-23. Driver: BlackHole v0.7.1 fork, installed (Spike A). Tone: `--play-tone Dabber_2_UID 75 5`
(5 s silence, then 70 s tone) into the hidden Dabber Feed; recording: `--record --mic Dabber_UID --seconds 60`.

## Feed

`output format: 48000.0 Hz 2 ch flags 9`, `buffer frames: 512`. Wall-clock latency estimate, derived from code,
not measured: Feed buffer + Mic buffer, about 2 x 512 / 48000 = 21 ms (both safety offsets 0).

## Run 1 (build/loopB/2026-09-23 19-04-58): clicks, finalizer bug

- Feed `rendered frames=3599872 discontinuities=0 unexpectedLayouts=0`; recording 1 segment, 0 overruns,
  totalFrames 2884000, onset 3.9467 s, timestamp delay 0.027 ms, peak -11.2 dB, RMS -15.1 dB.
- silencedetect (n=-50dB d=0.005) found zero runs ending exactly at every file second with lengths repeating
  every 8 s (about 19, 18, 15, 12.5, 10, 7 ms, then under 5 ms); the >2 kHz click locator fired every second.
  The user: clicks clearly audible.
- Root cause: `CAFSegment.read` treated a short `AVAudioFile.read` as end of file and zero-filled the rest.
  AVAudioFile returns short reads that stop at a 1024-frame file boundary; with a segment offset of 416 frames the
  shortfall is `(48000k - 416) mod 1024`, which matches the measured gaps (48000 mod 1024 = 896 gives the 128-frame
  step and the 8 s period). Reproduced offline without audio hardware. Not a driver problem. Affected every
  track and mix produced by the finalizer before the fix (part1a and part3).
- Fix: `0dbebb1` on part3, `65ea450` on part1a (read until the range is filled, zero-pad only past the end),
  with tests `readsUnalignedRangeWithoutZeroFill` and `padsRangePastEndWithZeros`.

## Run 2 after the fix (build/loopB2/2026-09-23 19-12-29): clean

- Feed `rendered frames=3599872 discontinuities=0 unexpectedLayouts=0`; recording 1 segment, 0 overruns,
  totalFrames 2883383, leading gap 311 frames (not a multiple of 1024, so the short-read path was exercised).
- silencedetect: only `silence_start: 0`, `silence_end: 4.518667`. Click locator: none. Sample-level zero-run scan
  (threshold 0.003, min run 24 and 96 samples): only the leading silence.
- Onset 4.5187 s, timestamp delay 0.018 ms, peak -12.0 dB, RMS -15.05 dB.
- The user's listening check of run 2: pending.

## Latent driver risk noted

`BlackHole.c:4555` zeroes an input read when `lastOutputSampleTime - bufferSize < inputTime`, and
`kLatency_Frame_Size` is 0 (`:235`). Not triggered in these runs; Plan 3b measures it for the live feed.
