# Spike C: tap exclusion by bundle ID

Date: 2026-09-23. macOS 26.6.2, MacBook Air `Mac17,3`. This spike replaces Plan 3a Task 10.

Helper: `build/ToneHelper.app`, a copy of `Dabber.app` with `CFBundleIdentifier` `local.dabber.tonehelper`,
re-signed with "Dabber Dev" (`scripts/build-tone-helper.sh`). Its `--list-audio-processes` line:
`40971	-	local.dabber.tonehelper`.

The helper plays `--play-tone default` (440 Hz, amplitude 0.25) to the default output, MacBook Air Speakers
(`48000.0 Hz 2 ch flags 9`, buffer 512). Recordings: `--record --computer-audio --seconds 20`.

## E1-E3 (automated)

| Run | Setup | silencedetect (n=-50dB d=1) | mean_volume |
| --- | --- | --- | --- |
| E1 | helper playing, no exclusion | none | -15.1 dB |
| E2 | helper playing, `--exclude-bundle local.dabber.tonehelper` | `silence_start: 0` `silence_end: 20.036292` (end of file) | -91.0 dB |
| E3 | same exclusion, helper started about 5 s after the tap | `silence_start: 0` `silence_end: 20.025625` (end of file) | -91.0 dB |

- All three recordings: `FINALIZED` and `EXIT 0`. Tone logs: `toneE12` `rendered frames=2880000 discontinuities=0`,
  `toneE3` `rendered frames=960000 discontinuities=0`, both `EXIT 0`.
- E2 and E3 per-second meter: `-160.0 dB` for all 20 s. In E3 the recording session started at 657.6 and the
  helper's tone at 662.6 (log clock), so the last 15 s had the helper playing.
- Caveat: nothing else was playing during E2 and E3, so they have no in-run positive control. E1 shows the
  same tap path captures the tone; E2 and E3 differ from it only by the exclusion list.

## S1-S3: Safari (HUMAN)

Safari run: pending (HUMAN). Not run: `procsS.log` process lines, S1-S3 silencedetect and `mean_volume`.

## Answers

1. Does a tap exclude an app by bundle ID (E2)? Yes.
2. Does it exclude an app that starts after the tap (E3)? Yes.
3. Which ID covers Safari's web audio (S2, S3)? Pending (HUMAN Safari run).

Tap bundle ID set for "Safari" for Task 6: pending, to be derived only from S2/S3.

Excluding `com.apple.WebKit.GPU` would also exclude the web audio of every other WebKit-based app (Mail, in-app
web views). That follows from the bundle ID; it was not tested.
