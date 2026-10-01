# Dabber Part 1: recording engine and menu bar app

Date: 2026-09-23. Status: design approved in chat, pending spec review.

## Why

Dipper (audio.existential.Dipper 1.14) recorded a Safari call without the AirPods mic, although the
AirPods input was enabled in its settings. The file had L == R and digital silence in pauses, so the mic was
never captured. Likely cause (not proven): when Safari opens the mic, AirPods switch to the call profile and the
device changes format mid-stream (observed on this machine: AirPods input and output at 24000 Hz while in that
mode). Dabber must survive that switch and must make a missing source visible during recording, not after.

## Scope

Dabber is a Dipper replacement, built in three parts. Each part gets its own spec and plan.

1. **This spec.** Recording engine, simple menu bar app, headless record mode.
2. Settings: per-source volume/pan/mute, output format choice, global hotkey, launch at login, output folder
   choice.
3. Own virtual microphone (HAL plug-in): an input device that call apps can select, carrying system audio,
   optionally mixed with a real mic (AirPods), so it can be streamed into calls. The call app's own playback (the
   other side's voice) is part of system audio and would echo back to the other side, so the virtual mic's system
   audio excludes user-chosen apps (the call app), via a tap that excludes their processes. Decided 2026-09-23.
   Recording is unaffected: it keeps the whole-system tap.

Out of scope for all parts: auto-start rules, per-app capture for recording (only whole-system audio is
recorded; decided 2026-09-23).


## Decisions

| Topic | Decision |
|---|---|
| App audio capture | Core Audio process taps, not ScreenCaptureKit |
| Default computer audio source | Global tap of all processes except Dabber itself |
| Multi-source strategy | Each source records independently, stamped with host time; a failing source restarts alone |
| Output | One folder per session: `mix.m4a`, one `.m4a` per source, `session.json` |
| Toolchain | Swift 6.4 Command Line Tools, SwiftPM, no Xcode; a script assembles and signs the `.app` |
| Signing | Self-signed code signing certificate in the login keychain, so TCC grants survive rebuilds |
| Sandbox / hardened runtime | Neither |

Rejected: one aggregate device holding every source. A mic reconnect rebuilds the aggregate and puts a gap in
every track, which is the failure class we are trying to escape.

## Components

One Swift package, two targets.

- **DabberCore** (library, no UI)
  - `SourceCatalog`: input devices (by UID) and the "Computer audio" source. Updates on
    `kAudioHardwarePropertyDevices`.
  - `ComputerAudioSource`: `CATapDescription(stereoGlobalTapButExcludeProcesses: [ownProcessObject])`,
    `AudioHardwareCreateProcessTap`, a private aggregate device holding only the tap
    (`kAudioAggregateDeviceIsPrivateKey = 1`, `kAudioAggregateDeviceTapListKey`, no tap auto-start), IOProc via
    `AudioDeviceCreateIOProcIDWithBlock`. Format read from `kAudioTapPropertyFormat` at each start.
  - `InputDeviceSource`: raw HAL IOProc directly on the device ID. No AVAudioEngine (it follows the default
    input and hides the device).
  - Both sources share one restart policy: listeners on `kAudioDevicePropertyNominalSampleRate`,
    `kAudioDevicePropertyDeviceIsAlive`, `kAudioDevicePropertyDeviceHasChanged`,
    `kAudioDevicePropertyIOStoppedAbnormally`, `kAudioStreamPropertyVirtualFormat` on input streams,
    `kAudioHardwarePropertyServiceRestarted`. Any event: stop, close the segment, re-read the format, restart,
    open a new segment. A device that disappears is found again by UID in the system device list (`kAudioHardwarePropertyDevices`)
    when that list changes. Stream format is never cached across restarts.
  - `RingBuffer`: lock-free single producer / single consumer. The IOProc only copies into it and counts overruns.
  - `TrackWriter`: writer thread. Drains the ring buffer, converts to 48 kHz float32 with `AVAudioConverter`
    (one converter per segment), writes CAF via `ExtAudioFile`. CAF stays readable if the app dies.
  - `Segment` model: per track, a list of segments `{startHostTime, sampleCount, sourceFormat}`. A jump in
    IOProc `mSampleTime` inside a segment is recorded as a gap.
  - `SessionRecorder`: one state machine (idle, recording, stopping). Starts sources, writes the event log,
    cancels pending restarts on stop, finalizes writers, destroys taps and aggregates.
  - `Finalizer`: after stop. Aligns tracks by host time (`AudioConvertHostTimeToNanos`), pads gaps with silence,
    measures drift per segment (samples / host duration) and resamples only if it exceeds 50 ms over the
    segment, renders the mix, encodes every track and the mix to AAC `.m4a` with `AVAudioFile`, closes files
    explicitly, deletes CAFs after a successful encode. Also runs on launch for any session folder left with CAFs
    and no `.m4a` (crash recovery).
  - `LevelMeter`: RMS per source, read by the UI.
- **DabberApp** (executable, SwiftUI `MenuBarExtra`, `LSUIElement`)
  - Menu: source list with checkboxes (Computer audio + each input device), live level meter per source,
    Start/Stop, elapsed time, "Show in Finder" for the last session.
  - Warning in the menu bar icon when an enabled mic stays below -60 dBFS for 10 s while computer audio has
    signal, and when a source is restarting.
  - Headless mode: `Dabber.app/Contents/MacOS/Dabber --record --mic <uid> --computer-audio --seconds N --out <dir>`,
    started through `open -W -a Dabber.app --args ...` so TCC attributes it to Dabber, not Terminal.

## Output

```
~/Recordings/Dabber/2026-09-23 05-53-11/
  mix.m4a
  mic - AirPods.m4a
  computer audio.m4a
  session.json
```

`session.json`: sources, segments with host times and formats, restart events with reason, gap durations,
ring buffer overruns, measured drift, app version.

## Edge cases

- Sleep: `NSWorkspace.willSleepNotification` closes segments; on wake the listeners fire and sources restart.
- Disk: before start require at least 2 GB free per expected hour (CAF float32 mono is about 691 MB/h per track);
  on a write error stop cleanly and finalize what exists.
- Stop while a source restarts: the state machine cancels the restart.
- Quit while recording: stop and finalize first.
- Channel count may change between segments; the finalizer downmixes the mic to mono and keeps computer audio stereo.

## Permissions

Info.plist: bundle id, `NSMicrophoneUsageDescription`, `NSAudioCaptureUsageDescription`, `LSUIElement = YES`.
Signed with the self-signed certificate (`codesign -s "Dabber Dev"`). Creating the certificate is a one-time human
step (login keychain password).

## Milestones

- **Spike 0**: build script, certificate, bundle; headless 60 s recording of computer audio to CAF; rebuild twice
  and confirm the TCC grant survives (rows in `~/Library/Application Support/com.apple.TCC/TCC.db`).
- **Spike 1**: mic IOProc on AirPods with a wildcard property listener (`kAudioObjectPropertySelectorWildcard`)
  that logs every event. Human opens and closes a WebRTC mic test page in Safari. Result: which properties fire
  on the call-profile switch, and whether the tap format changes too. Restart policy is adjusted to the facts.
- **Build**: segment model, ring buffer, writers, finalizer, state machine, menu UI.

## Testing

- Unit tests (synthetic buffers): gap padding, alignment by host time, drift resampling threshold, mixing,
  segment bookkeeping, finalizer crash recovery.
- Integration (headless mode): a known tone played through the speakers is captured by the computer audio track;
  checks with `ffprobe` (duration matches frames) and `ffmpeg astats` (signal present, no digital-zero stretches
  where signal was played).
- Human: TCC prompts, the AirPods switch during a Safari call test page, listening to one final mix.

## Open risks

- Whether every property listed above fires on the AirPods switch is unknown until Spike 1.
- Whether a self-signed certificate keeps the TCC grant across rebuilds is documented behaviour, not yet observed
  on this machine; Spike 0 checks it.
