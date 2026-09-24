# Dabber Part 3: virtual microphone

Date: 2026-09-23. Status: design approved in chat.

## Why

The user wants to send the Mac's audio, optionally mixed with an AirPods mic, into calls (Safari calls, call apps
such as Zoom/Telegram/FaceTime/Discord) and into streaming software (OBS). Dipper offered this through its own
virtual mic, which is BlackHole renamed and signed by Existential Audio (`/Library/Audio/Plug-Ins/HAL/Dipper.driver`,
`CFBundleExecutable = BlackHole`). Dabber replaces it with a driver built from source here.

## Decisions

| Topic | Decision |
|---|---|
| Consumers | Safari calls, call apps, streaming apps: any app that can pick an input device |
| Relation to recording | Independent: own on/off switch and own settings; works with or without a recording |
| Driver source | Fork of BlackHole (GPL-3.0), vendored at a pinned upstream commit, reviewed, trimmed, built and signed here. Personal use only; distributing Dabber later would require publishing the driver source under GPL-3.0 |
| Echo | The call app's playback is part of system audio; the virtual mic's system audio excludes user-chosen apps (default: Safari). Recording is unaffected |
| Build | No Xcode: `clang` builds the `.driver` bundle from a script; signed with the "Dabber Dev" identity |

## Devices

The driver publishes two devices that share one ring buffer inside the driver:

- **Dabber Mic**: input only, visible. Apps select it as their microphone.
- **Dabber Feed**: output only, hidden (`kAudioDevicePropertyIsHidden = 1`), so it never appears in output
  device lists and nobody routes their speakers into the mic by accident. Dabber opens it by UID.

Format: 48 kHz, 2 channels, float32. Audio written to Dabber Feed is read from Dabber Mic with a small fixed delay (to be measured in Spike B).
Rejected: a single loopback device with both input and output (BlackHole's default) because it would be listed as
a speaker; passing audio to the driver through shared memory or XPC (more own code inside `coreaudiod`).

## Mixing in Dabber

- One private aggregate device per virtual-mic session: main clock = Dabber Feed; sub-device = the chosen mic with
  drift compensation; tap list = one process tap of system audio excluding Dabber and the excluded apps, with
  drift compensation.
- One IOProc on the aggregate: reads the mic and tap inputs, mixes (mono mic to both channels, sum, clamp; the
  existing `Mixer` rules), writes to the Dabber Feed output.
- The aggregate is used here although recording rejected it: a source failure in a live feed is a short dropout,
  while recording keeps its independent per-source pipeline and files are unaffected.
- Excluded apps are matched by bundle ID. For Safari the audio is rendered by `com.apple.WebKit.GPU` helper
  processes, so excluding Safari means excluding those. The tap description uses bundle IDs with process restore
  (macOS 26 `bundleIDs`, `processRestoreEnabled`) so helpers that start later are excluded too; the exact behaviour
  is checked in a spike.
- Restart: on the same triggers as recording (device gone/returned, format change, `srst`), the aggregate is torn
  down and rebuilt. While the mic is absent the feed carries system audio only and the menu says so.

## Menu

A "Virtual mic" section, independent of the recording controls: on/off switch, "Computer audio" checkbox, mic
picker (none or one input device), excluded apps list (add from running apps, remove), level meter of the feed,
status line (running, restarting, mic missing, driver not installed). Settings persist in UserDefaults.

## Installation

- `scripts/install-driver.sh`: builds the driver, copies it to `/Library/Audio/Plug-Ins/HAL/DabberMic.driver`
  with `sudo`, restarts `coreaudiod` (`sudo killall coreaudiod`; all audio drops briefly while it restarts).
- `scripts/uninstall-driver.sh`: removes it and restarts `coreaudiod`.
- Dipper's driver stays installed and untouched; the user may remove Dipper later.
- Dabber detects a missing driver (no device with the Dabber Mic UID) and shows it in the menu instead of failing.

## Spikes first

- **Spike A (signature)**: build the unmodified-behaviour fork with renamed devices, sign with "Dabber Dev",
  install, restart `coreaudiod`; does Dabber Mic appear (`--list-inputs`)? If `coreaudiod` refuses the
  self-signed driver, stop and decide (ad-hoc signature, or other trust setup) before any more work.
- **Spike B (loopback quality)**: play a test tone into Dabber Feed from a headless command, record Dabber Mic
  with the existing recorder for 60 s; check no dropouts (silencedetect), correct duration, no clicks at buffer
  boundaries (visual/listening check by the user).
- **Spike C (exclusion)**: tap excluding Safari by bundle ID while a YouTube clip plays in Safari and a sound plays
  from another app: the clip must be absent and the other sound present.

## Testing

- Unit: mixing into the feed buffer, exclusion list to bundle ID set, settings persistence, status model.
- Hardware (headless): feed tone -> Dabber Mic recording checks with ffprobe/ffmpeg; exclusion check (Spike C).
- Human: a real call where the other side confirms hearing Mac audio and the user's voice without echo of themselves;
  OBS picks Dabber Mic and shows levels.

## Out of scope

Per-source volume/pan in the feed (Part 2 settings), more than one mic in the feed, monitoring the feed on
headphones, sample rates other than 48 kHz.
