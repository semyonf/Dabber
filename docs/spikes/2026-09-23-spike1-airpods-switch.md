# Spike 1: AirPods call-profile switch

Date: 2026-09-23. Device: "AirPods", input UID `<AirPods UID>:input`. Dipper was quit before both runs.
Logs: `build/mic.log`, `build/mic2.log` (not committed). Times below are seconds from the first log line.

## Device layout

The AirPods appear as two Core Audio devices: an input-only device (`...:input`, 1 channel) and a separate output
device. The input device has no output streams (`out -` in every poll line). The spike watched only the input
device, so output-side format changes were not observed directly; the global tap format stayed
`48000.0 Hz 2 ch` in both runs (polled every second).

## Run 1: Dabber opens the mic first

Phases: A 0, B 15.0, C 36.8, D 61.8, E 76.9, end 97.
- Input format polled every second: `24000.0 Hz 1 ch` for all 95 polls. No format change seen.
- Starting the mic IOProc (phase B) took about 1.8 s longer than the schedule: phase C was logged at 36.8 instead of
  35. At 16.7-16.8 the input device fired `vist`, `stm#`, `ltnc`, `cfgb` ... `cfge`, `sdel`, `bdsp`, `nrle`, `dcat`,
  `avap`, `btfo`, `avcp` and repeated `goin`/`gone`. No `nsrt`, no stream `sfmt`.
- Safari took the mic at about 43 (`cdes` at 42.9, then `gone`, `went`, `mute` at 43.5); no reconfiguration events.
- Tab closed: `went`, `mute` at 71.6, `cdes` at 74.6.
- Mic recorder: `frames=1440480 failedWrites=0` = 60.02 s at 24 kHz, the whole B-E window. Voice at about -26 dB RMS
  from 17 to 53 s, including while Safari shared the mic. From 55 s on the level is -53 to -62 dB with short bursts;
  The user says they probably stopped talking after the "close the tab" prompt.
- Tap: Safari audio (a YouTube clip, 48-62 s) and the spoken prompts are present, confirmed by listening.

## Run 2: Safari holds the mic before Dabber starts

Phases: A 0, B 15.0, C 35.1, D 60.2, E 75.2, end 95. No schedule delay at phase B.
- At 7.4, with no Dabber IOProc running, the input device switched from 24000 to 48000 Hz. Events on the device:
  `cfgb`, `dsOb`, `cfge`, `vist`, `sPaT`, `sPaC`, `ccre`, `stm#`, `cfgb`, `sdel`, `bdsp`, `nrle`, `dcat`, `avap`,
  `btfo`, `avcp`, `nsr#`, `nsrt`, `diff`, `cfge`, `pft`, `pfta`, `sfm#`, `sfmt`; on the input stream `pft`, `pfta`,
  `sfma`, `sfm#`, `sfmt`. The cause is unknown (no human action was scheduled then).
- Input format `48000.0 Hz 1 ch` from 8 s to the end. Starting the mic IOProc at 15.1 fired `goin`, `stm#`, `ltnc`,
  `gone`, without reconfiguration.
- Tab closed: `went`, `mute` at 71.3, `cdes` at 74.4. Mic IOProc stopped at 75.2; reconfiguration events at 77.4.
- Mic recorder: `frames=2883840 failedWrites=0` = 60.08 s at 48 kHz. Voice about -17 to -38 dB in every 2 s window
  from 15 to 75 s, including after the tab was closed at about 71.

## Findings

1. Recording the AirPods mic worked in both orders (Dabber first, Safari first), with no write failures and no gaps.
   Safari and Dabber share the mic without interrupting each other.
2. The input device can change its nominal rate at any time (24 to 48 kHz in run 2) without any app starting or
   stopping. When the rate changes, `nsrt`, `diff` and `sfmt` fire on the device and `sfmt` on the input stream.
   A switch while Dabber is recording was not captured in either run, so its effect on a running IOProc is not
   known.
3. Opening the mic from Dabber reconfigures the device (`cfgb`/`cfge`, `stm#`) even when the rate does not change
   (run 1).
4. The tap stayed at 48 kHz stereo throughout both runs.

## Restart trigger set for Plan 1b

Restart the input source on any of: device `nsrt`, device `diff`, input stream `sfmt`, device `livn`
(DeviceIsAlive, not observed here but needed for disconnects), `stpd` (IOStoppedAbnormally, not observed), system
`dev#` for the device disappearing, system `srst`. Do not restart on `cfgb`/`cfge`/`stm#`/`goin`/`gone`/`went`/`mute`:
they fired without a format change and recording continued correctly through them.
Keep a per-buffer check of the actual buffer byte size against the segment format as a safety net, because a
switch during recording was not observed.

## Final test 2026-09-23 (plan 1b, Task 13)

Headless `--record --computer-audio --mic <AirPods> --seconds 300`, session `build/rec/2026-09-23 18-10-41`.
The Audio MIDI Setup rate change was not possible: the AirPods input format is read-only there (24 000 Hz 1 ch).
Replaced by switching Mic Mode Standard -> Voice Isolation -> Standard (menu bar mic indicator) at 1:30-2:00.

- `EXIT 0`, mix duration 300.46 s, all three `.m4a` plus `session.json`, no `.caf` left.
- Computer audio: one segment, 48 kHz, 300.4 s, 0 overruns, no restarts. Signal exactly at the spoken prompts
  and the YouTube clip (155-180 s).
- Mic: two segments, both 24 kHz. `start` 0.1-223.3 s; `restart: device returned` from 232.3 s, 68.2 s.
  Restarts: `livn` (AirPods put in the case at about 223 s), then `device returned`. Status went
  `restarting("livn")` -> `waitingForDevice` -> recording. 0 overruns.
- Gaps: start latency 14 ms (computer audio) and 115 ms (mic), and 8.975 s on the mic at 223.3 s (AirPods in the
  case). `silencedetect n=-60dB d=5` on the mic file reports only 223.1-233.7 s.
- Drift 0 on every segment, nothing resampled.
- Mic Mode switching fired no restart and did not change the mic format: a switch of the sample rate during
  recording was still not observed. That path is covered only by unit tests and the per-buffer size check.
- An earlier accidental 300 s run (`build/rec/2026-09-23 17-50-36`) showed one `sample time jump` segment split on
  the mic at 12.4 s with a 65 ms gap, handled as designed.

Per the user: once an app captures the AirPods mic they stay in the call profile and cannot change rate until
released, so a rate switch during Dabber's own recording should not occur. Consistent with every run here (no
switch while Dabber held the mic). Not absolute: in run 2 the input switched 24 -> 48 kHz while Safari held the
mic, and then recorded at 48 kHz while held. The restart-on-format-change path stays as a cheap safety net.
