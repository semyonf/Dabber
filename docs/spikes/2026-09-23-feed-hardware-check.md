# Feed hardware check (Plan 3b Task 10)

Date: 2026-09-23. macOS 26.6.2, MacBook Air `Mac17,3`, Dabber Mic driver from Plan 3a installed. Code at `9bb3cef`,
finalizer fix `0dbebb1` in the branch. Builds: `local.dabber.Dabber` and `local.dabber.tonehelper`, both signed.

The tone helper (`build/ToneHelper.app`) plays `--play-tone default` to the default output. The feed runs as
`--feed`, the Dabber Mic is read by `--scan-input Dabber_UID <s> <frames>` and `--record --mic Dabber_UID`.

## Run A: computer audio only, 60 s

Feed `--feed --computer-audio --seconds 72`:
- `FEED config mic=none computer=true tap excludes ["local.dabber.Dabber"]`
- `t=1 running -15.0 dB` ... `t=72 running -15.2 dB`; all 72 `t=` lines `running`, -15.2..-14.9 dB
- `FEED cycles=6763 frames=3462656 discontinuities=0 unexpectedLayouts=0 skippedInputs=0`, `EXIT 0`

Scans, 60 s each, run at the same time:

| Reader buffer | SCAN line | ZERO_RUN lines | Exit |
| --- | --- | --- | --- |
| 128 | `SCAN frames=2880384 firstSignal=0 zeroRuns=0 longest=0 discontinuities=0 unexpectedLayouts=0` | none | `EXIT 0` |
| 512 | `SCAN frames=2880000 firstSignal=172 zeroRuns=0 longest=0 discontinuities=0 unexpectedLayouts=0` | none | `EXIT 0` |
| 4096 | `SCAN frames=2879488 firstSignal=0 zeroRuns=0 longest=0 discontinuities=0 unexpectedLayouts=0` | none | `EXIT 0` |

The 512 scan read 172 zero frames before its first signal (start-up, before `firstSignal`); the plan expected
`firstSignal=0`. The scanner counts runs only after the first non-zero frame, so this is not a zero run.

Recording `--record --mic Dabber_UID --seconds 60`: `t=1 ... running -14.9 dB` ... `t=60 ... running -15.2 dB`,
`FINALIZED total=2885959 gaps=1 resampled=0`, `EXIT 0`. Tone: `rendered frames=3840000 discontinuities=0
unexpectedLayouts=0`, `EXIT 0`.

Checks on `mic - Dabber Mic.m4a` (duration 60.181333 s):
- silencedetect (n=-50dB d=0.005): `silence_start: 0`, `silence_end: 0.00641667`; nothing after. Onset 0.0064 s.
- astats from onset+1 for 50 s: `Peak level dB: -11.950047`, `RMS level dB: -15.052123` (3.1 dB apart, a sine).
- Click locator: no `click second` lines. Of the 61 one-second windows after the double 2 kHz high-pass, the
  steady ones sit at -64 dB; only `0` (-18.6 dB, onset) and `60` (-30.0 dB, the partial last window) exceed
  -55 dB, and both are outside the locator's window.

## Run B: built-in mic plus computer audio, 30 s

Feed `--feed --mic BuiltInMicrophoneDevice --computer-audio --seconds 38`:
- `FEED config mic=BuiltInMicrophoneDevice computer=true tap excludes ["local.dabber.Dabber"]`
- `t=1 running -14.4 dB` ... `t=38 running -14.3 dB`; all 38 `t=` lines `running`, -14.6..-14.2 dB
- `FEED cycles=3569 frames=1827328 discontinuities=0 unexpectedLayouts=0 skippedInputs=0`, `EXIT 0`

| Reader buffer | SCAN line | ZERO_RUN lines | Exit |
| --- | --- | --- | --- |
| 128 | `SCAN frames=1440256 firstSignal=0 zeroRuns=0 longest=0 discontinuities=0 unexpectedLayouts=0` | none | `EXIT 0` |
| 512 | `SCAN frames=1440256 firstSignal=0 zeroRuns=0 longest=0 discontinuities=0 unexpectedLayouts=0` | none | `EXIT 0` |
| 4096 | `SCAN frames=1437696 firstSignal=0 zeroRuns=0 longest=0 discontinuities=0 unexpectedLayouts=0` | none | `EXIT 0` |

Tone: `rendered frames=2160128 discontinuities=0 unexpectedLayouts=0`, `EXIT 0`.

## Run C: the tone helper excluded from the feed

Feed `--feed --computer-audio --exclude-bundle local.dabber.tonehelper --seconds 33`:
- `FEED config mic=none computer=true tap excludes ["local.dabber.Dabber", "local.dabber.tonehelper"]`
- `t=1 running -160.0 dB` ... `t=33 running -160.0 dB`; `t=5 running -160.0 dB`; all 33 lines at -160.0 dB
- `FEED cycles=3099 frames=1586688 discontinuities=0 unexpectedLayouts=0 skippedInputs=0`, `EXIT 0`

Recording `--record --mic Dabber_UID --seconds 25`: every `t=` line `running -160.0 dB`,
`FINALIZED total=1202462 gaps=1 resampled=0`, `EXIT 0`. Tone `EXIT 0`.
silencedetect (n=-50dB d=1): `silence_start: 0`, `silence_end: 25.051292` (end of file, duration 25.109333 s).
The exclusion holds through the feed path, as in Spike C E2.

## Run D: mic absent

`--feed --mic no-such-uid --computer-audio --seconds 5`: `t=1 micMissing -160.0 dB` ... `t=5 micMissing -160.0 dB`,
all five lines `micMissing`, `FEED cycles=470 frames=240640 discontinuities=0 unexpectedLayouts=0 skippedInputs=0`,
`EXIT 0`. Nothing was playing, so the level is silence.

## Decision on the driver latency (Task 11)

Every scan in Runs A and B shows `zeroRuns=0` and no `ZERO_RUN` line, Run A's silencedetect shows nothing after
start-up, and there are no click lines. Driver latency not needed, measured. Task 11 is skipped.
