# Dabber 3b: Virtual Mic Feed and Menu Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Dabber feeds the hidden **Dabber Feed** with system audio (minus chosen apps) mixed with one chosen mic, so any app that picks **Dabber Mic** as its microphone hears both. The feed survives device changes like recording does, keeps sending computer audio while the mic is absent, and says so when the driver is missing. A "Virtual mic" section in the menu controls it. Two spikes come first: (C) exclusion of an app by bundle ID, proved automatically with a second bundle of the Dabber binary, plus one short Safari run; (D) one private aggregate holding the hidden Feed, a mic and a process tap.

**Architecture:**
- `FeedAggregate` builds one private aggregate per feed session: main sub-device Dabber Feed (by UID), the chosen mic as a drift-compensated sub-device, one drift-compensated process tap excluding Dabber and the excluded apps.
- `DuplexIOProcRunner` runs one IOProc on it. `FeedRenderer` mixes every input buffer into the Feed output with the recording `Mixer` rules (mono to both channels, stereo as is, sum, clamp) and meters the result.
- `FeedEngine` owns the lifecycle: start/stop from a `FeedConfig`, restart on the recording trigger set, mic-absent mode, driver-missing state. Core Audio sits behind `FeedHooks`, the same seam as the recorder's `CaptureHooks`, so the state machine is unit-tested with fakes.
- `FeedModel` (`@MainActor @Observable`, like `RecorderModel`) drives the menu section and persists `FeedSettings` as JSON in UserDefaults.
- Headless `--feed`, `--scan-input` and `--feed-probe` make the hardware checks scriptable.

**Tech Stack:** Swift 6.4 with SwiftPM and Swift Testing, CoreAudio (HAL IOProc, private aggregate devices, process taps with `bundleIDs`), SwiftUI `MenuBarExtra`, ffmpeg/ffprobe, plutil, codesign.

Spec: `docs/superpowers/specs/2026-09-23-dabber-part3-virtual-mic-design.md` (sections "Mixing in Dabber", "Menu", "Installation", "Testing"). Format model: `docs/superpowers/plans/2026-09-23-dabber-3a-driver-and-spikes.md`. Inputs: `docs/spikes/2026-09-23-spikeA-driver-signature.md`, `docs/spikes/2026-09-23-spikeB-loopback.md`.

Task 1 replaces Plan 3a Task 10 (Spike C). It writes the same doc, `docs/spikes/2026-09-23-spikeC-exclusion.md`.

## Ground rules for implementers

- Repo root: the repository root. Branch `part3`. No remote. Never push.
- Commit messages: one line, `type: description`, no body, no trailers. `git add` by explicit path only; read `git diff --cached --stat` before every commit.
- Shell is zsh. Tests: `scripts/test.sh` only (bare `swift test` cannot find the Swift Testing macro plugin). Success means exit code 0 (`scripts/test.sh; echo "exit=$?"`), never grep for text. No Xcode, no `xcodebuild`. Never use `@State` or `@Bindable` (the SwiftUI macro plugin is not in the CLT toolchain; see Plan 1b).
- **The implementer never runs `sudo`.** Driver install/uninstall is a HUMAN step (Task 11 only, and only if its trigger fires).
- Never touch `/Library/Audio/Plug-Ins/HAL/Dipper.driver` or any file of Dipper. Do not edit `/Library/Preferences/Audio/*`.
- In zsh, `log` is a shell builtin. Always call `/usr/bin/log`.
- Hardware checks: `scripts/build-app.sh`, then `scripts/run-headless.sh <log> <args>`. The log's last line must end in ` EXIT 0`. From Task 1 on, `DABBER_APP=build/ToneHelper.app scripts/run-headless.sh ...` runs the same binary as the tone helper bundle.
- **Automated hardware steps play a 440 Hz beep through the current output device** (Tasks 1 and 10) and open the built-in mic (Tasks 2 and 10; the orange mic dot shows). Tell the user once before Task 1: "the next automated steps beep through the speakers for a few minutes; do not change the output volume or device meanwhile".
- Code: English, no comments unless the code cannot say it. KISS. Swift 6 language mode. Classes crossing into IOProc blocks are `final class ...: @unchecked Sendable`. The IO thread only writes their counters, and those are read after `stop()`.
- Do not touch `Sources/DabberCore/Finalize/*` (a separate fix lives there).
- Tasks marked **HUMAN** need the user (listening, Safari, AirPods, a call, OBS). Stop there, tell the user exactly what to do in at most five short lines, and wait.
- Test counts below assume the baseline of `df309e6`: **99 tests**. If `scripts/test.sh` reports a different baseline before Task 3, shift every expected count by the difference.
- Facts below were checked on this machine on 2026-09-23 (macOS 26.6.2, MacBook Air `Mac17,3`, driver from Plan 3a installed) with the code of this plan built and signed in a scratch copy outside the repo. Treat them as verified:
  - The complete Swift code of this plan compiled; `scripts/test.sh` ran **138 tests, exit 0** (99 before). `scripts/build-app.sh` built and signed it.
  - A copy of `Dabber.app` with `CFBundleIdentifier` replaced by `local.dabber.tonehelper` and re-signed with "Dabber Dev" launches through `open -W -n`, and Core Audio reports its process with that bundle ID: `--list-audio-processes` run from the copy printed `38005	-	local.dabber.tonehelper`.
  - A private aggregate whose main sub-device is the **hidden** Dabber Feed (`Dabber_2_UID`) is created and runs. `--feed-probe none 2`: `aggregate rate=48000.0 buffer=512`, inputs `48000.0Hz/2ch/flags9` (the tap), outputs `48000.0Hz/2ch/flags9`, first cycle `in 2ch/4096B | out 2ch/4096B`, `cycles=188` in 2 s.
  - With the built-in mic as a drift-compensated sub-device (`--feed-probe BuiltInMicrophoneDevice 3`): inputs `48000.0Hz/1ch/flags9 48000.0Hz/2ch/flags9` (mic first, then tap), first cycle `in 1ch/2048B 2ch/4096B | out 2ch/4096B`, mic at -55.5 dB (room noise), `mic rate before=48000.0 after=48000.0`.
  - The full feed path works for a mic: `--feed --mic BuiltInMicrophoneDevice --seconds 12` logged `running` at -48..-56 dB every second and `FEED cycles=1127 frames=577024 discontinuities=0 unexpectedLayouts=0 skippedInputs=0`.
  - During that feed, raw scans of Dabber Mic (`--scan-input Dabber_UID 8 [frames]`) with the reader's buffer at 128, 512 and 4096 frames each read about 384,000 frames with `zeroRuns=0 discontinuities=0`. With 4096 frames the first 136 frames read were zero (start-up, before `firstSignal`). Only 8 s each and only the built-in mic at 48 kHz: Task 10 repeats this for 60 s with system audio.
  - Not verified: tone exclusion by bundle ID, Safari exclusion, a 24 kHz Bluetooth mic (AirPods call profile) inside the aggregate, the menu UI on screen. Tasks 1, 2, 9 and 12 check these.

## The driver underrun risk and how 3b handles it

`BlackHole.c:4555` zeroes a Dabber Mic read when `lastOutputSampleTime - inIOBufferFrameSize < inputTime`, i.e. when the Feed has not yet been written up to the end of the window the Mic client asks for. When that happens it also clears the whole ring (`isBufferClear`), so one late Feed cycle is a dropout of at least one buffer. `kLatency_Frame_Size` is 0 (`:235`), so both safety offsets are 0.

From the code (derived, not measured), with Feed buffer `Bf` and the Feed cycle at `Cf`: the Feed writes `[Cf+Bf, Cf+2Bf)`, so `lastOutputSampleTime = Cf+2Bf`. A Mic client with buffer `Bm` at `Cm` reads `[Cm-Bm, Cm)`. The read is zeroed iff `Cf+2Bf < Cm`. The Feed cycles every `Bf`, so its latest cycle is at `Cf >= Cm-Bf` when it is on time, which gives `Cf+2Bf >= Cm+Bf`. An underrun therefore needs the Feed writer to be late by more than `Bf` frames (10.7 ms at 512), whatever the reader's buffer size. Both devices share one clock, so there is no drift between them. In the aggregate the Feed's output time gets the aggregate's own safety offset on top, which only adds margin.

3b does not change the driver up front. It measures:
- `--scan-input Dabber_UID <s> <frames>` reads Dabber Mic as a real client would and counts exact-zero runs of 16 or more frames after the first non-zero frame (`ZeroRunScanner`). A tone or a live mic never produces 16 exact zeros in a row, so every run is a driver zero-fill.
- Task 10 runs it for 60 s at reader buffers 128, 512 and 4096 during a system-audio feed, and for 30 s with a mic in the aggregate.
- Only if Task 10 finds a zero run does Task 11 give the driver a latency (`kLatency_Frame_Size=256`, which adds 256 frames of margin on each side) and ask the user to reinstall it.

## Fallback if the aggregate fails (Spike D)

If Task 2 cannot create or run the aggregate (the hidden Feed refused as a sub-device, a tap refused next to real sub-devices, or AirPods at 24 kHz refused or silent), stop after Task 2 and write the doc. Plan 3b-fallback is then written from it. The design it would follow:
- Mic: existing `IOProcRunner` on the mic into a `RingBuffer`.
- System audio: existing `GlobalTap` aggregate + `IOProcRunner` into a second `RingBuffer`.
- Output: `OutputIOProcRunner` on Dabber Feed. Each cycle pulls one buffer's worth from each ring, converts the mic to 48 kHz with an `AVAudioConverter` when it runs at another rate, and mixes with `FeedMixer`.
- No drift compensation: each ring keeps a target fill of 2 buffers. Above 4 buffers it drops one buffer, below 1 it inserts silence. Each such slip is an audible click every few minutes, which is the price of not using the aggregate.

Tasks 3, 4, 6, 7, 8 and 9 carry over unchanged. Task 5 would swap `FeedHooks.live` for the three-runner version.

## File structure

```
scripts/build-tone-helper.sh                     copy of Dabber.app with bundle ID local.dabber.tonehelper, re-signed
scripts/run-headless.sh                          (modify) DABBER_APP picks the bundle
Sources/DabberCore/CoreAudio/GlobalTap.swift     (modify) createTap(excludingBundleIDs:) without an aggregate
Sources/DabberCore/CoreAudio/DuplexIOProcRunner.swift   IOProc with input and output
Sources/DabberCore/Feed/FeedAggregate.swift      private aggregate: Feed main, mic sub-device, tap; FeedDevices UIDs; FeedError
Sources/DabberCore/Model/FeedMixer.swift         pointer-based mix into a stereo buffer
Sources/DabberCore/Feed/FeedRenderer.swift       IO-thread mix of all inputs into the Feed, meter, counters
Sources/DabberCore/Feed/FeedEngine.swift         FeedConfig, FeedStatus, FeedHooks, lifecycle and restarts
Sources/DabberCore/Feed/FeedSettings.swift       ExclusionList, FeedSettings (Codable), AppEntry candidates
Sources/DabberCore/App/FeedModel.swift           FeedControlling, AppCatalog, LiveAppCatalog, FeedModel
Sources/DabberCore/Model/ZeroRunScanner.swift    exact-zero run counter for the underrun check
Sources/Dabber/Headless.swift                    (modify) --play-tone default, --feed-probe, --scan-input, --feed
Sources/Dabber/AppDelegate.swift                 (modify) feed model, ticks, device and app notifications
Sources/Dabber/MenuApp.swift                     (modify) VirtualMicSection
Tests/DabberCoreTests/FeedMixerTests.swift
Tests/DabberCoreTests/FeedRendererTests.swift
Tests/DabberCoreTests/FeedEngineTests.swift
Tests/DabberCoreTests/FeedSettingsTests.swift
Tests/DabberCoreTests/FeedModelTests.swift
Tests/DabberCoreTests/ZeroRunScannerTests.swift
docs/spikes/2026-09-23-spikeC-exclusion.md
docs/spikes/2026-09-23-spikeD-feed-aggregate.md
docs/spikes/2026-09-23-feed-hardware-check.md
```

---

### Task 1: Spike C, exclusion by bundle ID (automated, then HUMAN: one Safari run)

**Files:**
- Create: `scripts/build-tone-helper.sh`, `docs/spikes/2026-09-23-spikeC-exclusion.md`
- Modify: `scripts/run-headless.sh`, `Sources/Dabber/Headless.swift`

The helper is the Dabber binary under another bundle ID, so the tap sees a separate app that Dabber controls. It plays `--play-tone` to the default output. Recordings of computer audio with and without `--exclude-bundle local.dabber.tonehelper` must then contain the tone or not. No human is needed for that part. The Safari run then answers which bundle ID covers Safari's web audio (`com.apple.Safari`, `com.apple.WebKit.GPU`, or only both).

- [ ] **Step 1: `--play-tone default` plays to the default output device**

In `Sources/Dabber/Headless.swift`, in the `--play-tone` case, replace
```swift
            let device = try deviceID(uid: args[1])
            guard device != kAudioObjectUnknown else {
                log.line("no device with uid \(args[1])")
                return 2
            }
            let streams = try getArray(
                device, address(kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeOutput),
```
with
```swift
            let device = args[1] == "default"
                ? try getValue(systemObject, address(kAudioHardwarePropertyDefaultOutputDevice), default: AudioObjectID(0))
                : try deviceID(uid: args[1])
            guard device != kAudioObjectUnknown else {
                log.line("no device with uid \(args[1])")
                return 2
            }
            let streams = try getArray(
                device, address(kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeOutput),
```

- [ ] **Step 2: Let `run-headless.sh` run another bundle**

In `scripts/run-headless.sh` replace
```bash
open -W -n build/Dabber.app --args --log "$LOG" "$@"
```
with
```bash
open -W -n "${DABBER_APP:-build/Dabber.app}" --args --log "$LOG" "$@"
```

- [ ] **Step 3: Write `scripts/build-tone-helper.sh`**

```bash
#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
ID=local.dabber.tonehelper
APP=build/ToneHelper.app
rm -rf "$APP"
cp -R build/Dabber.app "$APP"
plutil -replace CFBundleIdentifier -string "$ID" "$APP/Contents/Info.plist"
plutil -replace CFBundleName -string "Dabber Tone Helper" "$APP/Contents/Info.plist"
codesign --force --sign "Dabber Dev" "$APP"
codesign -d -r- "$APP" 2>&1 | grep designated
echo "$APP"
```

- [ ] **Step 4: Build both bundles and check the helper's identity**

Run:
```zsh
chmod +x scripts/build-tone-helper.sh
scripts/build-app.sh
scripts/build-tone-helper.sh
DABBER_APP=build/ToneHelper.app scripts/run-headless.sh "$PWD/build/helper-procs.log" --list-audio-processes | grep -E 'dabber|EXIT'
```
Expected:
- `build/ToneHelper.app: replacing existing signature`, `designated => identifier "local.dabber.tonehelper" and certificate leaf = H"<certificate hash>"`, `build/ToneHelper.app`
- a line `<pid>	-	local.dabber.tonehelper` and `EXIT 0`

The existing `Property.swift` warnings and the `ld: warning: search path` lines are expected in the build output.

- [ ] **Step 5: Commit**

```zsh
git add scripts/build-tone-helper.sh scripts/run-headless.sh Sources/Dabber/Headless.swift
git diff --cached --stat
git commit -m "build: add tone helper bundle and default output tone for exclusion checks"
```

- [ ] **Step 6: E1-E3, three 20 s recordings of computer audio (automated, beeps)**

- **E1**: the helper plays, no exclusion (control).
- **E2**: the helper plays, `--exclude-bundle local.dabber.tonehelper`.
- **E3**: same exclusion, but the helper starts about 5 s after the tap exists (process restore).

Run:
```zsh
H=build/ToneHelper.app
rm -rf build/exclE1 build/exclE2 build/exclE3
DABBER_APP=$H scripts/run-headless.sh "$PWD/build/toneE12.log" --play-tone default 60 0 > /dev/null &
sleep 2
scripts/run-headless.sh "$PWD/build/exclE1.log" --record --computer-audio --seconds 20 --out "$PWD/build/exclE1" | tail -2
scripts/run-headless.sh "$PWD/build/exclE2.log" --record --computer-audio --exclude-bundle local.dabber.tonehelper --seconds 20 --out "$PWD/build/exclE2" | tail -2
wait
( sleep 5; DABBER_APP=$H scripts/run-headless.sh "$PWD/build/toneE3.log" --play-tone default 20 0 > /dev/null ) &
scripts/run-headless.sh "$PWD/build/exclE3.log" --record --computer-audio --exclude-bundle local.dabber.tonehelper --seconds 20 --out "$PWD/build/exclE3" | tail -2
wait
tail -1 build/toneE12.log build/toneE3.log
```
Expected: each recording ends with `FINALIZED ...` and `EXIT 0`; both tone logs end with `EXIT 0`. If E2 or E3 logs `ERROR` with `create process tap`, record the error and stop: the OS rejected the description.

- [ ] **Step 7: Analyse E1-E3**

Run:
```zsh
for run in E1 E2 E3; do
  S=$(ls -d build/excl$run/*/ | tail -1); F="$S/computer audio.m4a"
  echo "== $run"
  ffmpeg -hide_banner -nostats -i "$F" -af silencedetect=n=-50dB:d=1 -f null - 2>&1 | grep -oE 'silence_(start|end): [0-9.]+' | paste - -
  ffmpeg -hide_banner -nostats -i "$F" -af volumedetect -f null - 2>&1 | grep -oE 'mean_volume: .*'
done
```
Expected:
- **E1**: no silence lines (the tone is captured at all). `mean_volume` is recorded, not judged: whether the tap level follows the output volume is not known. If E1 is silent, the helper did not play; check `toneE12.log` and stop.
- **E2**: one `silence_start: 0` with no `silence_end` (or one at the very end), `mean_volume` below -60 dB. A notification sound during the run shows up as a short non-silent stretch; rerun E2 once before concluding anything.
- **E3**: like E2. A non-silent stretch from about 6 s on means a process that starts after the tap is **not** excluded by bundle ID. That is a finding: record it, finish this task, and tell the user before Task 5, because the feed then has to rebuild its tap when an excluded app starts.

- [ ] **Step 8: Safari, one run (HUMAN)**

Tell the user:
> Open Safari and play a YouTube video with continuous sound (music is best), normal volume.
> Keep it playing for about two minutes; I record three short clips of computer audio meanwhile.
> Tell me when it plays.

Then run:
```zsh
scripts/run-headless.sh "$PWD/build/procsS.log" --list-audio-processes | grep -E 'Safari|WebKit'
for run in S1 S2 S3; do
  case $run in
    S1) ex=() ;;
    S2) ex=(--exclude-bundle com.apple.Safari) ;;
    S3) ex=(--exclude-bundle com.apple.WebKit.GPU) ;;
  esac
  rm -rf build/excl$run
  scripts/run-headless.sh "$PWD/build/excl$run.log" --record --computer-audio "${ex[@]}" --seconds 20 --out "$PWD/build/excl$run" | tail -1
done
```
Tell the user they can stop the video. Then run the Step 7 analysis loop with `S1 S2 S3` instead of `E1 E2 E3`.

Expected: a `com.apple.WebKit.GPU` line marked `OUT` in `procsS.log`; S1 not silent (no silence line longer than a few seconds). If S1 is silent, the video was not playing: ask the user once more and redo Step 8. S2 and S3 are facts, not pass/fail:
- **S2 silent**: excluding `com.apple.Safari` covers its WebKit audio.
- **S2 not silent, S3 silent**: `com.apple.WebKit.GPU` must be in the tap list for Safari.
- **Both not silent**: neither ID alone works. Record it; Task 6 then keeps both IDs, and Task 10 plus the final call test show whether both together work.

If a result is ambiguous (short non-silent bits), ask the user to listen with `afplay "<file>"` and say whether they hear the video.

- [ ] **Step 9: Write `docs/spikes/2026-09-23-spikeC-exclusion.md`**

Record:
- the helper's `--list-audio-processes` line;
- E1-E3 and S1-S3: silencedetect lines and `mean_volume`;
- the process lines from `procsS.log`;
- answers:
  1. Does a tap exclude an app by bundle ID (E2)?
  2. Does it exclude an app that starts after the tap (E3)?
  3. Which ID covers Safari's web audio (S2, S3)?
- the tap bundle ID set for "Safari" that Task 6 uses, derived only from S2/S3;
- that excluding `com.apple.WebKit.GPU` also excludes the web audio of every other WebKit-based app (Mail, in-app web views). That follows from the bundle ID; it was not tested;
- that this task replaces Plan 3a Task 10.

- [ ] **Step 10: Commit**

```zsh
git add docs/spikes/2026-09-23-spikeC-exclusion.md
git commit -m "docs: record spike c exclusion results"
```

---

### Task 2: Spike D, one aggregate with the hidden Feed, a mic and a tap (automated, then HUMAN: AirPods)

**Files:**
- Create: `Sources/DabberCore/CoreAudio/DuplexIOProcRunner.swift`, `Sources/DabberCore/Feed/FeedAggregate.swift`, `docs/spikes/2026-09-23-spikeD-feed-aggregate.md`
- Modify: `Sources/DabberCore/CoreAudio/GlobalTap.swift`, `Sources/Dabber/Headless.swift`

The automated part was already run in the scratch copy (ground rules). It is repeated here on the real build because everything after this task builds on it. The open question is the AirPods mic in call profile (24 kHz, Spike 1): does the aggregate take a sub-device at another nominal rate, and does it change the AirPods rate?

- [ ] **Step 1: Tap creation without an aggregate in `GlobalTap`**

In `Sources/DabberCore/CoreAudio/GlobalTap.swift` replace
```swift
    public init(excludingBundleIDs bundleIDs: [String] = []) throws {
        let me = try processObject(pid: getpid())
        let description = Self.description(
            excludingProcesses: me == kAudioObjectUnknown ? [] : [me], bundleIDs: bundleIDs)

        var tap = AudioObjectID(kAudioObjectUnknown)
        try check(AudioHardwareCreateProcessTap(description, &tap), "create process tap")
        tapID = tap
```
with
```swift
    public init(excludingBundleIDs bundleIDs: [String] = []) throws {
        let tap = try Self.createTap(excludingBundleIDs: bundleIDs)
        tapID = tap
```
and add, directly before `static func description(`:
```swift
    public static func createTap(excludingBundleIDs bundleIDs: [String]) throws -> AudioObjectID {
        let me = try processObject(pid: getpid())
        let description = Self.description(
            excludingProcesses: me == kAudioObjectUnknown ? [] : [me], bundleIDs: bundleIDs)
        var tap = AudioObjectID(kAudioObjectUnknown)
        try check(AudioHardwareCreateProcessTap(description, &tap), "create process tap")
        return tap
    }

```

- [ ] **Step 2: Write `Sources/DabberCore/CoreAudio/DuplexIOProcRunner.swift`**

The output twin of `IOProcRunner` that also passes the input side. It destroys its IOProc if the start fails.

```swift
import CoreAudio
import Foundation

public final class DuplexIOProcRunner: @unchecked Sendable {
    public typealias Handler = @Sendable (
        UnsafePointer<AudioBufferList>, UnsafeMutablePointer<AudioBufferList>, UnsafePointer<AudioTimeStamp>
    ) -> Void

    private let device: AudioObjectID
    private var procID: AudioDeviceIOProcID?

    public init(device: AudioObjectID, handler: @escaping Handler) throws {
        self.device = device
        try check(
            AudioDeviceCreateIOProcIDWithBlock(&procID, device, nil) { _, input, _, output, outputTime in
                handler(input, output, outputTime)
            }, "create duplex ioproc")
        do {
            try check(AudioDeviceStart(device, procID), "start device")
        } catch {
            AudioDeviceDestroyIOProcID(device, procID!)
            procID = nil
            throw error
        }
    }

    public func stop() {
        guard let procID else { return }
        AudioDeviceStop(device, procID)
        AudioDeviceDestroyIOProcID(device, procID)
        self.procID = nil
    }
}
```

- [ ] **Step 3: Write `Sources/DabberCore/Feed/FeedAggregate.swift`**

- Main sub-device = Dabber Feed by UID, so the aggregate runs on the driver's clock.
- The mic and the tap are drift-compensated (`"drift": 1`).
- Missing Feed throws `FeedError.driverMissing`; missing mic throws the existing `SourceError.deviceMissing`.
- `watched` lists what the engine watches: aggregate (`.device`), tap (`.tap`), mic device (`.device`) and the mic's first input stream (`.inputStream`). That is the recording trigger set: `nsrt`, `diff`, `livn`, `stpd`, stream `sfmt`, tap format.

```swift
import CoreAudio
import Foundation

public enum FeedDevices {
    public static let micUID = "Dabber_UID"
    public static let feedUID = "Dabber_2_UID"
}

public enum FeedError: Error, Equatable, CustomStringConvertible {
    case driverMissing

    public var description: String { "Dabber Feed (\(FeedDevices.feedUID)) not present" }
}

public final class FeedAggregate: @unchecked Sendable {
    public let aggregateID: AudioObjectID
    public let tapID: AudioObjectID?
    public let micID: AudioObjectID?

    public init(micUID: String?, tapExcluding bundleIDs: [String]?) throws {
        guard try deviceID(uid: FeedDevices.feedUID) != kAudioObjectUnknown else { throw FeedError.driverMissing }
        var subDevices: [[String: Any]] = [[kAudioSubDeviceUIDKey: FeedDevices.feedUID]]
        var mic: AudioObjectID?
        if let micUID {
            let id = try deviceID(uid: micUID)
            guard id != kAudioObjectUnknown else { throw SourceError.deviceMissing(micUID) }
            mic = id
            subDevices.append([kAudioSubDeviceUIDKey: micUID, kAudioSubDeviceDriftCompensationKey: 1])
        }
        var config: [String: Any] = [
            kAudioAggregateDeviceUIDKey: "local.dabber.feed.\(UUID().uuidString)",
            kAudioAggregateDeviceNameKey: "Dabber Feed Mix",
            kAudioAggregateDeviceIsPrivateKey: 1,
            kAudioAggregateDeviceMainSubDeviceKey: FeedDevices.feedUID,
            kAudioAggregateDeviceSubDeviceListKey: subDevices,
        ]
        var tap: AudioObjectID?
        if let bundleIDs {
            let t = try GlobalTap.createTap(excludingBundleIDs: bundleIDs)
            tap = t
            do {
                let uid = try getString(t, address(kAudioTapPropertyUID))
                config[kAudioAggregateDeviceTapListKey] = [[kAudioSubTapUIDKey: uid, kAudioSubTapDriftCompensationKey: 1]]
            } catch {
                AudioHardwareDestroyProcessTap(t)
                throw error
            }
        }
        var aggregate = AudioObjectID(kAudioObjectUnknown)
        let status = AudioHardwareCreateAggregateDevice(config as CFDictionary, &aggregate)
        if status != noErr {
            if let tap { AudioHardwareDestroyProcessTap(tap) }
            throw CAError(status: status, op: "create feed aggregate")
        }
        aggregateID = aggregate
        tapID = tap
        micID = mic
    }

    public var watched: [(AudioObjectID, WatchedObject)] {
        var list: [(AudioObjectID, WatchedObject)] = [(aggregateID, .device)]
        if let tapID { list.append((tapID, .tap)) }
        if let micID {
            list.append((micID, .device))
            let streams = (try? getArray(
                micID, address(kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeInput),
                filler: AudioObjectID(0))) ?? []
            if let stream = streams.first { list.append((stream, .inputStream)) }
        }
        return list
    }

    public func destroy() {
        AudioHardwareDestroyAggregateDevice(aggregateID)
        if let tapID { AudioHardwareDestroyProcessTap(tapID) }
    }
}
```

- [ ] **Step 4: Add `--feed-probe <micUID|none> <seconds>` to `Headless.dispatch`**

It builds the aggregate with a tap that excludes nothing but Dabber, logs the stream layout, runs one IOProc that writes silence and measures each input buffer's level, then destroys the aggregate. Insert this case directly after the `--play-tone` case:

```swift
        case "--feed-probe":
            guard args.count == 3, let seconds = Double(args[2]) else { return 64 }
            let micUID = args[1] == "none" ? nil : args[1]
            let micBefore = try micUID.map { try nominalRate(deviceID(uid: $0)) }
            let aggregate = try FeedAggregate(micUID: micUID, tapExcluding: [])
            defer { aggregate.destroy() }
            let id = aggregate.aggregateID
            log.line("aggregate rate=\(try nominalRate(id)) buffer=\(try getValue(id, address(kAudioDevicePropertyBufferFrameSize), default: UInt32(0)))")
            log.line("aggregate inputs: \(streamFormats(id, kAudioObjectPropertyScopeInput))")
            log.line("aggregate outputs: \(streamFormats(id, kAudioObjectPropertyScopeOutput))")
            let probe = LayoutProbe()
            let runner = try DuplexIOProcRunner(device: id) { input, output, _ in probe.handle(input, output) }
            Thread.sleep(forTimeInterval: seconds)
            runner.stop()
            log.line("first cycle: \(probe.firstLayout)")
            log.line("cycles=\(probe.cycles) input dB: " + probe.decibels.map { String(format: "%.1f", $0) }.joined(separator: " "))
            if let micUID {
                log.line("mic rate before=\(micBefore ?? 0) after=\(try nominalRate(deviceID(uid: micUID)))")
            }
            return 0
```

Append to the end of `Sources/Dabber/Headless.swift`:
```swift

func nominalRate(_ device: AudioObjectID) throws -> Double {
    try getValue(device, address(kAudioDevicePropertyNominalSampleRate), default: 0.0)
}

func streamFormats(_ device: AudioObjectID, _ scope: AudioObjectPropertyScope) -> String {
    let streams = (try? getArray(device, address(kAudioDevicePropertyStreams, scope: scope), filler: AudioObjectID(0))) ?? []
    return streams.map { stream in
        let f = (try? getValue(stream, address(kAudioStreamPropertyVirtualFormat), default: AudioStreamBasicDescription()))
            ?? AudioStreamBasicDescription()
        return "\(f.mSampleRate)Hz/\(f.mChannelsPerFrame)ch/flags\(f.mFormatFlags)"
    }.joined(separator: " ")
}

final class LayoutProbe: @unchecked Sendable {
    var cycles = 0
    var firstLayout = ""
    private var sums = [Double](repeating: 0, count: 8)
    private var counts = [Int](repeating: 0, count: 8)
    private var inputs = 0

    var decibels: [Double] {
        (0..<inputs).map { i in counts[i] > 0 && sums[i] > 0 ? 10 * log10(sums[i] / Double(counts[i])) : -160 }
    }

    func handle(_ input: UnsafePointer<AudioBufferList>, _ output: UnsafeMutablePointer<AudioBufferList>) {
        let ins = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        let outs = UnsafeMutableAudioBufferListPointer(output)
        if cycles == 0 {
            inputs = min(ins.count, 8)
            firstLayout = "in " + ins.map { "\($0.mNumberChannels)ch/\($0.mDataByteSize)B" }.joined(separator: " ")
                + " | out " + outs.map { "\($0.mNumberChannels)ch/\($0.mDataByteSize)B" }.joined(separator: " ")
        }
        cycles += 1
        for (i, b) in ins.enumerated() where i < inputs {
            guard let d = b.mData?.assumingMemoryBound(to: Float.self) else { continue }
            let n = Int(b.mDataByteSize) / MemoryLayout<Float>.size
            for k in 0..<n { sums[i] += Double(d[k] * d[k]) }
            counts[i] += n
        }
        for b in outs { if let d = b.mData { memset(d, 0, Int(b.mDataByteSize)) } }
    }
}
```

- [ ] **Step 5: Tests still pass; build**

Run: `scripts/test.sh; echo "exit=$?"`, then `scripts/build-app.sh`.
Expected: `Test run with 99 tests ... passed`, `exit=0`; the build prints the `local.dabber.Dabber` designated line.

- [ ] **Step 6: Probe without and with the built-in mic**

Run:
```zsh
scripts/run-headless.sh "$PWD/build/probeD-none.log" --feed-probe none 2
scripts/run-headless.sh "$PWD/build/probeD-mic.log" --feed-probe BuiltInMicrophoneDevice 3
```
Expected (as in the scratch run):
- none: `aggregate rate=48000.0 buffer=512`, inputs `48000.0Hz/2ch/flags9`, outputs `48000.0Hz/2ch/flags9`, `first cycle: in 2ch/4096B | out 2ch/4096B`, `cycles=` about 188, `EXIT 0`.
- mic: inputs `48000.0Hz/1ch/flags9 48000.0Hz/2ch/flags9`, `first cycle: in 1ch/2048B 2ch/4096B | out 2ch/4096B`, first input dB above -90 (room noise), `mic rate before=48000.0 after=48000.0`, `EXIT 0`.

If either fails (`ERROR ... create feed aggregate` or `start device`), record it, write the doc (Step 8) and stop the plan: the fallback design above applies.

- [ ] **Step 7: AirPods in call profile (HUMAN)**

Tell the user:
> Put in your AirPods and make sure they are connected to the Mac.
> When I say "go", count slowly from 1 to 10 out loud.

Run `scripts/run-headless.sh "$PWD/build/inputsD.log" --list-inputs` and take the AirPods input UID (it ends in `:input`). Say "go", then run:
```zsh
scripts/run-headless.sh "$PWD/build/probeD-airpods.log" --feed-probe '<airpods uid>' 10
```
Expected: `EXIT 0`, two input formats (the mic first), first input dB above -45 while the user counts. Record the aggregate input format for the mic stream and `mic rate before=... after=...` whatever they are. 24000 before and 48000 after means the aggregate changed the AirPods rate. That is a finding, not a failure, as long as the voice is there.

Failure = `ERROR`, or first input at -160 dB, or the mic input missing from `first cycle`. Then ask the user to count once more and rerun. If it fails again, write the doc and stop: the fallback applies to Bluetooth mics.

- [ ] **Step 8: Write `docs/spikes/2026-09-23-spikeD-feed-aggregate.md` and commit**

Record the three probe logs (layout, levels, rates), the AirPods UID, and whether the aggregate changed the AirPods rate. Then:
```zsh
git add Sources/DabberCore/CoreAudio/GlobalTap.swift Sources/DabberCore/CoreAudio/DuplexIOProcRunner.swift \
  Sources/DabberCore/Feed/FeedAggregate.swift Sources/Dabber/Headless.swift docs/spikes/2026-09-23-spikeD-feed-aggregate.md
git diff --cached --stat
git commit -m "feat: add feed aggregate with hidden feed, mic and tap and a headless probe"
```

---

### Task 3: Feed mixer (pure, TDD)

**Files:**
- Create: `Sources/DabberCore/Model/FeedMixer.swift`, `Tests/DabberCoreTests/FeedMixerTests.swift`

`Mixer.mixToStereo` works on arrays and allocates. The IO thread needs the same rules on pointers. Rules: one channel goes to both sides, two channels stay stereo, more than two use channel 0 as mono (a multi-channel USB interface feeds its first input). One test pins it to `Mixer.mixToStereo`, so recording and feed cannot drift apart.

- [ ] **Step 1: Write the failing tests `Tests/DabberCoreTests/FeedMixerTests.swift`**

```swift
import Testing
@testable import DabberCore

private func mix(_ inputs: [([Float], Int)], frames: Int) -> [Float] {
    var out = [Float](repeating: 0, count: frames * 2)
    out.withUnsafeMutableBufferPointer { o in
        for (samples, channels) in inputs {
            samples.withUnsafeBufferPointer { FeedMixer.add($0, channels: channels, into: o) }
        }
        FeedMixer.clamp(o)
    }
    return out
}

@Test func feedMonoGoesToBothChannels() {
    #expect(mix([([0.1, 0.2], 1)], frames: 2) == [0.1, 0.1, 0.2, 0.2])
}

@Test func feedStereoKeepsItsChannels() {
    #expect(mix([([0.1, 0.2, 0.3, 0.4], 2)], frames: 2) == [0.1, 0.2, 0.3, 0.4])
}

@Test func moreThanTwoChannelsUseTheFirstAsMono() {
    #expect(mix([([0.1, 0.9, 0.9, 0.2, 0.9, 0.9], 3)], frames: 2) == [0.1, 0.1, 0.2, 0.2])
}

@Test func feedMixMatchesTheRecordingMixer() {
    let mono: [Float] = [0.5, -0.25, 0.75]
    let stereo: [Float] = [0.25, 0.5, -1, 0.5, 0.5, -0.5]
    #expect(mix([(mono, 1), (stereo, 2)], frames: 3) == Mixer.mixToStereo(mono: [mono], stereo: [stereo]))
}

@Test func shortInputLeavesTheRestUntouched() {
    #expect(mix([([0.5], 1)], frames: 2) == [0.5, 0.5, 0, 0])
}
```

- [ ] **Step 2: Run, expect compile failure**

Run: `scripts/test.sh; echo "exit=$?"`
Expected: `cannot find 'FeedMixer' in scope`, non-zero exit.

- [ ] **Step 3: Write `Sources/DabberCore/Model/FeedMixer.swift`**

```swift
public enum FeedMixer {
    public static func add(_ input: UnsafeBufferPointer<Float>, channels: Int, into out: UnsafeMutableBufferPointer<Float>) {
        let frames = min(out.count / 2, input.count / channels)
        for f in 0..<frames {
            let left = input[f * channels]
            out[2 * f] += left
            out[2 * f + 1] += channels == 2 ? input[f * 2 + 1] : left
        }
    }

    public static func clamp(_ out: UnsafeMutableBufferPointer<Float>) {
        for i in out.indices { out[i] = min(1, max(-1, out[i])) }
    }
}
```

- [ ] **Step 4: Run tests**

Run: `scripts/test.sh; echo "exit=$?"`
Expected: `Test run with 104 tests ... passed`, `exit=0`.

- [ ] **Step 5: Commit**

```zsh
git add Sources/DabberCore/Model/FeedMixer.swift Tests/DabberCoreTests/FeedMixerTests.swift
git commit -m "feat: add pointer-based feed mixer with the recording mix rules"
```

---

### Task 4: Feed renderer (TDD)

**Files:**
- Create: `Sources/DabberCore/Feed/FeedRenderer.swift`, `Tests/DabberCoreTests/FeedRendererTests.swift`

Runs on the IO thread of the aggregate. The output must be one interleaved 2-channel buffer (the Feed stream, `flags 9`, Spike B and Task 2); anything else is zeroed and counted. The inputs are whatever the aggregate delivers (mic first, then tap, Task 2), mixed without needing to know which is which. An input whose size does not match the output frames is skipped and counted instead of read out of bounds. The meter is `TrackWriter`'s `LevelMeter`.

- [ ] **Step 1: Write the failing tests `Tests/DabberCoreTests/FeedRendererTests.swift`**

```swift
import CoreAudio
import Testing
@testable import DabberCore

private func withList(
    _ buffers: [(channels: Int, samples: [Float])], _ body: (UnsafeMutablePointer<AudioBufferList>) -> Void
) {
    let list = AudioBufferList.allocate(maximumBuffers: max(1, buffers.count))
    defer { free(list.unsafeMutablePointer) }
    list.count = buffers.count
    var storage: [UnsafeMutablePointer<Float>] = []
    for (i, b) in buffers.enumerated() {
        let p = UnsafeMutablePointer<Float>.allocate(capacity: max(1, b.samples.count))
        p.initialize(from: b.samples, count: b.samples.count)
        storage.append(p)
        list[i] = AudioBuffer(
            mNumberChannels: UInt32(b.channels), mDataByteSize: UInt32(b.samples.count * 4), mData: p)
    }
    body(list.unsafeMutablePointer)
    for p in storage { p.deallocate() }
}

private func render(
    _ renderer: FeedRenderer, inputs: [(channels: Int, samples: [Float])], frames: Int, sampleTime: Double = 0
) -> [Float] {
    var out = [Float](repeating: 9, count: frames * 2)
    withList(inputs) { input in
        out.withUnsafeMutableBytes { raw in
            var list = AudioBufferList(
                mNumberBuffers: 1,
                mBuffers: AudioBuffer(mNumberChannels: 2, mDataByteSize: UInt32(raw.count), mData: raw.baseAddress))
            var ts = AudioTimeStamp()
            ts.mSampleTime = sampleTime
            withUnsafeMutablePointer(to: &list) { l in withUnsafePointer(to: &ts) { t in renderer.render(input, l, t) } }
        }
    }
    return out
}

@Test func rendererMixesMicAndTapIntoTheFeed() {
    let r = FeedRenderer()
    let out = render(r, inputs: [(1, [0.5, 0.25]), (2, [0.1, 0.2, 0.3, 0.4])], frames: 2)
    #expect(out == Mixer.mixToStereo(mono: [[0.5, 0.25]], stereo: [[0.1, 0.2, 0.3, 0.4]]))
    #expect(r.meter.decibels > -20)
    #expect(r.cycles == 1)
}

@Test func rendererWithNoInputsWritesSilence() {
    let r = FeedRenderer()
    #expect(render(r, inputs: [], frames: 4).allSatisfy { $0 == 0 })
    #expect(r.meter.decibels == -160)
}

@Test func inputOfTheWrongSizeIsSkippedAndCounted() {
    let r = FeedRenderer()
    let out = render(r, inputs: [(1, [0.5]), (2, [0.1, 0.2, 0.3, 0.4])], frames: 2)
    #expect(out == [0.1, 0.2, 0.3, 0.4])
    #expect(r.skippedInputs == 1)
}

@Test func outputSampleTimeJumpIsCounted() {
    let r = FeedRenderer()
    _ = render(r, inputs: [], frames: 4, sampleTime: 0)
    _ = render(r, inputs: [], frames: 4, sampleTime: 4)
    _ = render(r, inputs: [], frames: 4, sampleTime: 100)
    #expect(r.discontinuities == 1)
    #expect(r.framesRendered == 12)
}
```

- [ ] **Step 2: Run, expect compile failure**

Run: `scripts/test.sh; echo "exit=$?"`
Expected: `cannot find type 'FeedRenderer' in scope`, non-zero exit.

- [ ] **Step 3: Write `Sources/DabberCore/Feed/FeedRenderer.swift`**

```swift
import CoreAudio
import Foundation

public final class FeedRenderer: @unchecked Sendable {
    public let meter = LevelMeter()
    public private(set) var cycles = 0
    public private(set) var framesRendered = 0
    public private(set) var discontinuities = 0
    public private(set) var unexpectedLayouts = 0
    public private(set) var skippedInputs = 0
    private var nextSampleTime = -1.0

    public init() {}

    public func render(
        _ input: UnsafePointer<AudioBufferList>, _ output: UnsafeMutablePointer<AudioBufferList>,
        _ time: UnsafePointer<AudioTimeStamp>
    ) {
        let outs = UnsafeMutableAudioBufferListPointer(output)
        guard outs.count == 1, let data = outs[0].mData, outs[0].mNumberChannels == 2 else {
            for b in outs { if let d = b.mData { memset(d, 0, Int(b.mDataByteSize)) } }
            unexpectedLayouts += 1
            return
        }
        let frames = Int(outs[0].mDataByteSize) / MemoryLayout<Float>.size / 2
        let t = time.pointee
        if nextSampleTime >= 0, t.mSampleTime != nextSampleTime { discontinuities += 1 }
        nextSampleTime = t.mSampleTime + Double(frames)
        cycles += 1
        framesRendered += frames
        let out = UnsafeMutableBufferPointer(start: data.assumingMemoryBound(to: Float.self), count: frames * 2)
        out.update(repeating: 0)
        for b in UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input)) {
            let channels = Int(b.mNumberChannels)
            guard channels > 0, let src = b.mData, Int(b.mDataByteSize) == frames * channels * MemoryLayout<Float>.size
            else {
                skippedInputs += 1
                continue
            }
            FeedMixer.add(
                UnsafeBufferPointer(start: src.assumingMemoryBound(to: Float.self), count: frames * channels),
                channels: channels, into: out)
        }
        FeedMixer.clamp(out)
        meter.update(UnsafePointer(data.assumingMemoryBound(to: Float.self)), count: out.count)
    }
}
```

- [ ] **Step 4: Run tests**

Run: `scripts/test.sh; echo "exit=$?"`
Expected: `Test run with 108 tests ... passed`, `exit=0`.

- [ ] **Step 5: Commit**

```zsh
git add Sources/DabberCore/Feed/FeedRenderer.swift Tests/DabberCoreTests/FeedRendererTests.swift
git commit -m "feat: add feed renderer mixing aggregate inputs into the feed output"
```

---

### Task 5: Feed engine with restarts, mic-absent mode and driver detection (TDD)

**Files:**
- Create: `Sources/DabberCore/Feed/FeedEngine.swift`, `Tests/DabberCoreTests/FeedEngineTests.swift`

Behaviour, all on one serial queue like `CaptureSource`:
- `apply(config)` starts, reconfigures or (with `nil`) stops the feed asynchronously; `applyAndWait` does the same synchronously (headless, tests). An unchanged config is a no-op.
- Open: if the configured mic is present, the aggregate includes it (`running`); if not, it opens without it (`micMissing`, the feed carries computer audio only).
- System `dev#`: if nothing is open (driver missing, or failed), try again. If the mic's presence differs from what is open, rebuild after the debounce ("mic returned" / "mic gone").
- The recording trigger set on the watched objects (`RestartPolicy`), and system `srst`, tear down at once and rebuild after `restartDelay` (0.5 s).
- `FeedError.driverMissing` sets `driverMissing` without retries; the next `dev#` retries (driver installed while Dabber runs).
- Other open errors are retried after `retryDelay` (2 s), three attempts, then `failed`; the next `dev#` tries again.

- [ ] **Step 1: Write the failing tests `Tests/DabberCoreTests/FeedEngineTests.swift`**

```swift
import CoreAudio
import Foundation
import Synchronization
import Testing
@testable import DabberCore

private final class FeedProbe: Sendable {
    let micPresent = Atomic<Bool>(true)
    let driverPresent = Atomic<Bool>(true)
    let failingOpens = Atomic<Int>(0)
    let opens = Mutex<[Bool]>([])
    let closes = Atomic<Int>(0)
    let ioRunning = Atomic<Bool>(false)
    let handlers = Mutex<[AudioObjectID: PropertyWatcher.Handler]>([:])

    var hooks: FeedHooks {
        FeedHooks(
            micPresent: { [self] _ in micPresent.load(ordering: .relaxed) },
            open: { [self] _, withMic in
                guard driverPresent.load(ordering: .relaxed) else { throw FeedError.driverMissing }
                if failingOpens.load(ordering: .relaxed) > 0 {
                    failingOpens.wrappingSubtract(1, ordering: .relaxed)
                    throw CAError(status: 1, op: "create feed aggregate")
                }
                opens.withLock { $0.append(withMic) }
                return OpenedFeed(device: 77, watched: [(77, .device)]) { [self] in
                    closes.wrappingAdd(1, ordering: .relaxed)
                }
            },
            startIO: { [self] _, _ in
                ioRunning.store(true, ordering: .relaxed)
                return { [self] in ioRunning.store(false, ordering: .relaxed) }
            },
            watch: { [self] objects, handler in
                handlers.withLock { h in for (object, _) in objects { h[object] = handler } }
                return {}
            })
    }

    var openedWithMic: [Bool] { opens.withLock { $0 } }
    var running: Bool { ioRunning.load(ordering: .relaxed) }

    func fire(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) {
        let handler = handlers.withLock { $0[object] }
        handler?(object, selector)
    }
}

private let withMic = FeedConfig(micUID: "ap", computerAudio: true, tapBundleIDs: ["com.apple.Safari"])

private func makeEngine(_ probe: FeedProbe) -> FeedEngine {
    let engine = FeedEngine(hooks: probe.hooks)
    engine.restartDelay = 0.1
    engine.retryDelay = 0.1
    return engine
}

private func waitUntil(_ condition: () -> Bool) -> Bool {
    let end = Date().addingTimeInterval(3)
    while Date() < end {
        if condition() { return true }
        Thread.sleep(forTimeInterval: 0.01)
    }
    return condition()
}

@Test func feedStartsWithTheMicAndStopsCleanly() {
    let probe = FeedProbe()
    let engine = makeEngine(probe)
    engine.applyAndWait(withMic)
    #expect(engine.status == .running)
    #expect(probe.openedWithMic == [true])
    #expect(probe.running)
    engine.applyAndWait(nil)
    #expect(engine.status == .off)
    #expect(!probe.running)
    #expect(probe.closes.load(ordering: .relaxed) == 1)
}

@Test func sameConfigDoesNotReopen() {
    let probe = FeedProbe()
    let engine = makeEngine(probe)
    engine.applyAndWait(withMic)
    engine.applyAndWait(withMic)
    #expect(probe.openedWithMic == [true])
    engine.applyAndWait(nil)
}

@Test func changedConfigReopens() {
    let probe = FeedProbe()
    let engine = makeEngine(probe)
    engine.applyAndWait(withMic)
    var next = withMic
    next.computerAudio = false
    engine.applyAndWait(next)
    #expect(probe.openedWithMic == [true, true])
    #expect(probe.closes.load(ordering: .relaxed) == 1)
    engine.applyAndWait(nil)
}

@Test func absentMicFeedsComputerAudioThenAddsTheMicWhenItConnects() {
    let probe = FeedProbe()
    probe.micPresent.store(false, ordering: .relaxed)
    let engine = makeEngine(probe)
    engine.applyAndWait(withMic)
    #expect(engine.status == .micMissing)
    #expect(probe.openedWithMic == [false])
    probe.micPresent.store(true, ordering: .relaxed)
    probe.fire(systemObject, kAudioHardwarePropertyDevices)
    #expect(waitUntil { engine.status == .running })
    #expect(probe.openedWithMic == [false, true])
    engine.applyAndWait(nil)
}

@Test func micThatDisappearsLeavesComputerAudioRunning() {
    let probe = FeedProbe()
    let engine = makeEngine(probe)
    engine.applyAndWait(withMic)
    probe.micPresent.store(false, ordering: .relaxed)
    probe.fire(systemObject, kAudioHardwarePropertyDevices)
    #expect(waitUntil { engine.status == .micMissing })
    #expect(probe.openedWithMic == [true, false])
    #expect(probe.running)
    engine.applyAndWait(nil)
}

@Test func missingDriverIsReportedAndPickedUpOnceInstalled() {
    let probe = FeedProbe()
    probe.driverPresent.store(false, ordering: .relaxed)
    let engine = makeEngine(probe)
    engine.applyAndWait(withMic)
    #expect(engine.status == .driverMissing)
    #expect(!probe.running)
    probe.driverPresent.store(true, ordering: .relaxed)
    probe.fire(systemObject, kAudioHardwarePropertyDevices)
    #expect(waitUntil { engine.status == .running })
    engine.applyAndWait(nil)
}

@Test func deviceTriggerRebuildsTheAggregate() {
    let probe = FeedProbe()
    let engine = makeEngine(probe)
    engine.applyAndWait(withMic)
    probe.fire(77, kAudioDevicePropertyNominalSampleRate)
    #expect(waitUntil { engine.status == .restarting("nsrt") })
    #expect(waitUntil { engine.status == .running })
    #expect(probe.openedWithMic == [true, true])
    engine.applyAndWait(nil)
}

@Test func serviceRestartRebuildsTheAggregate() {
    let probe = FeedProbe()
    let engine = makeEngine(probe)
    engine.applyAndWait(withMic)
    probe.fire(systemObject, kAudioHardwarePropertyServiceRestarted)
    #expect(waitUntil { probe.openedWithMic.count == 2 && engine.status == .running })
    engine.applyAndWait(nil)
}

@Test func openFailuresAreRetriedThenReported() {
    let probe = FeedProbe()
    probe.failingOpens.store(3, ordering: .relaxed)
    let engine = makeEngine(probe)
    engine.applyAndWait(withMic)
    #expect(waitUntil {
        if case .failed = engine.status { return true }
        return false
    })
    #expect(probe.openedWithMic.isEmpty)
    probe.fire(systemObject, kAudioHardwarePropertyDevices)
    #expect(waitUntil { engine.status == .running })
    engine.applyAndWait(nil)
}

@Test func turningOffDuringAPendingRestartStaysOff() {
    let probe = FeedProbe()
    let engine = makeEngine(probe)
    engine.applyAndWait(withMic)
    probe.fire(77, kAudioDevicePropertyNominalSampleRate)
    #expect(waitUntil { engine.status == .restarting("nsrt") })
    engine.applyAndWait(nil)
    Thread.sleep(forTimeInterval: 0.3)
    #expect(engine.status == .off)
    #expect(probe.openedWithMic == [true])
    #expect(!probe.running)
}
```

- [ ] **Step 2: Run, expect compile failure**

Run: `scripts/test.sh; echo "exit=$?"`
Expected: `cannot find type 'FeedHooks' in scope`, non-zero exit.

- [ ] **Step 3: Write `Sources/DabberCore/Feed/FeedEngine.swift`**

```swift
import CoreAudio
import Foundation
import Synchronization

public struct FeedConfig: Sendable, Equatable {
    public var micUID: String?
    public var computerAudio: Bool
    public var tapBundleIDs: [String]

    public init(micUID: String?, computerAudio: Bool, tapBundleIDs: [String]) {
        self.micUID = micUID
        self.computerAudio = computerAudio
        self.tapBundleIDs = tapBundleIDs
    }
}

public enum FeedStatus: Sendable, Equatable {
    case off
    case running
    case micMissing
    case restarting(String)
    case driverMissing
    case failed(String)
}

public struct OpenedFeed: Sendable {
    public let device: AudioObjectID
    public let watched: [(AudioObjectID, WatchedObject)]
    public let close: CaptureHooks.Stop

    public init(device: AudioObjectID, watched: [(AudioObjectID, WatchedObject)], close: @escaping CaptureHooks.Stop) {
        self.device = device
        self.watched = watched
        self.close = close
    }
}

public struct FeedHooks: Sendable {
    public typealias Open = @Sendable (_ config: FeedConfig, _ withMic: Bool) throws -> OpenedFeed
    public typealias StartIO = @Sendable (AudioObjectID, FeedRenderer) throws -> CaptureHooks.Stop

    public var micPresent: @Sendable (String) -> Bool
    public var open: Open
    public var startIO: StartIO
    public var watch: CaptureHooks.Watch

    public init(
        micPresent: @escaping @Sendable (String) -> Bool, open: @escaping Open, startIO: @escaping StartIO,
        watch: @escaping CaptureHooks.Watch
    ) {
        self.micPresent = micPresent
        self.open = open
        self.startIO = startIO
        self.watch = watch
    }

    public static let live = FeedHooks(
        micPresent: { ((try? deviceID(uid: $0)) ?? kAudioObjectUnknown) != kAudioObjectUnknown },
        open: { config, withMic in
            let aggregate = try FeedAggregate(
                micUID: withMic ? config.micUID : nil,
                tapExcluding: config.computerAudio ? config.tapBundleIDs : nil)
            return OpenedFeed(device: aggregate.aggregateID, watched: aggregate.watched) { aggregate.destroy() }
        },
        startIO: { device, renderer in
            let runner = try DuplexIOProcRunner(device: device) { input, output, time in
                renderer.render(input, output, time)
            }
            return { runner.stop() }
        },
        watch: CaptureHooks.live.watch)
}

public final class FeedEngine: @unchecked Sendable {
    let queue = DispatchQueue(label: "dabber.feed")
    var restartDelay = 0.5
    var retryDelay = 2.0
    private let hooks: FeedHooks
    private var config: FeedConfig?
    private var opened: OpenedFeed?
    private var openedWithMic = false
    private var stopIO: CaptureHooks.Stop?
    private var stopWatcher: CaptureHooks.Stop?
    private var stopSystemWatcher: CaptureHooks.Stop?
    private var kinds: [AudioObjectID: WatchedObject] = [:]
    private var pendingRestart: DispatchWorkItem?
    private var attempts = 0
    private let statusValue = Mutex<FeedStatus>(.off)
    private let rendererValue = Mutex<FeedRenderer?>(nil)

    public init(hooks: FeedHooks = .live) {
        self.hooks = hooks
    }

    public var status: FeedStatus { statusValue.withLock { $0 } }
    public var renderer: FeedRenderer? { rendererValue.withLock { $0 } }
    public var levelDb: Double { renderer?.meter.decibels ?? -160 }

    public func apply(_ next: FeedConfig?) {
        queue.async { self.applyLocked(next) }
    }

    public func applyAndWait(_ next: FeedConfig?) {
        queue.sync { applyLocked(next) }
    }

    private func applyLocked(_ next: FeedConfig?) {
        guard next != config else { return }
        config = next
        pendingRestart?.cancel()
        pendingRestart = nil
        tearDown()
        attempts = 0
        guard next != nil else {
            stopSystemWatcher?()
            stopSystemWatcher = nil
            return setStatus(.off)
        }
        if stopSystemWatcher == nil {
            do {
                stopSystemWatcher = try hooks.watch([(systemObject, RestartPolicy.selectors(for: .system))]) {
                    [weak self] _, selector in
                    guard let self else { return }
                    queue.async { self.handleSystem(selector) }
                }
            } catch {
                return setStatus(.failed("\(error)"))
            }
        }
        openLocked()
    }

    private func openLocked() {
        guard let config else { return }
        let withMic = config.micUID.map(hooks.micPresent) ?? false
        do {
            let opened = try hooks.open(config, withMic)
            self.opened = opened
            openedWithMic = withMic
            let renderer = FeedRenderer()
            stopIO = try hooks.startIO(opened.device, renderer)
            rendererValue.withLock { $0 = renderer }
            kinds = Dictionary(opened.watched.map { ($0.0, $0.1) }, uniquingKeysWith: { a, _ in a })
            stopWatcher = try hooks.watch(opened.watched.map { ($0.0, RestartPolicy.selectors(for: $0.1)) }) {
                [weak self] object, selector in
                guard let self else { return }
                queue.async { self.handle(object: object, selector: selector) }
            }
        } catch FeedError.driverMissing {
            tearDown()
            return setStatus(.driverMissing)
        } catch {
            tearDown()
            attempts += 1
            if attempts < 3 {
                scheduleRestart(reason: "\(error)", after: retryDelay)
            } else {
                setStatus(.failed("\(error)"))
            }
            return
        }
        attempts = 0
        setStatus(config.micUID != nil && !withMic ? .micMissing : .running)
    }

    private func tearDown() {
        stopWatcher?()
        stopWatcher = nil
        stopIO?()
        stopIO = nil
        opened?.close()
        opened = nil
        kinds = [:]
        rendererValue.withLock { $0 = nil }
    }

    private func setStatus(_ s: FeedStatus) { statusValue.withLock { $0 = s } }

    private func handle(object: AudioObjectID, selector: AudioObjectPropertySelector) {
        guard config != nil, let kind = kinds[object], RestartPolicy.shouldRestart(selector, on: kind) else { return }
        scheduleRestart(reason: fourCC(selector), after: restartDelay)
    }

    private func handleSystem(_ selector: AudioObjectPropertySelector) {
        guard let config, pendingRestart == nil else { return }
        if selector != kAudioHardwarePropertyDevices {
            return scheduleRestart(reason: fourCC(selector), after: restartDelay)
        }
        if opened == nil {
            attempts = 0
            return openLocked()
        }
        let micPresent = config.micUID.map(hooks.micPresent) ?? false
        if micPresent != openedWithMic {
            scheduleRestart(reason: micPresent ? "mic returned" : "mic gone", after: restartDelay)
        }
    }

    private func scheduleRestart(reason: String, after delay: Double) {
        guard config != nil else { return }
        setStatus(.restarting(reason))
        tearDown()
        pendingRestart?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            pendingRestart = nil
            openLocked()
        }
        pendingRestart = item
        queue.asyncAfter(deadline: .now() + delay, execute: item)
    }
}
```

- [ ] **Step 4: Run tests**

Run: `scripts/test.sh; echo "exit=$?"`
Expected: `Test run with 118 tests ... passed`, `exit=0`. Run it twice more: these tests use timing (`waitUntil`, 3 s cap), and a flaky pass is not a pass.

- [ ] **Step 5: Commit**

```zsh
git add Sources/DabberCore/Feed/FeedEngine.swift Tests/DabberCoreTests/FeedEngineTests.swift
git commit -m "feat: add feed engine with restarts, mic-absent mode and driver detection"
```

---

### Task 6: Exclusion list, settings and app candidates (pure, TDD)

**Files:**
- Create: `Sources/DabberCore/Feed/FeedSettings.swift`, `Tests/DabberCoreTests/FeedSettingsTests.swift`

- The user-facing list holds app bundle IDs (default `com.apple.Safari`). `ExclusionList.tapBundleIDs` turns it into the tap's set: it adds each app's audio helpers and Dabber's own bundle ID, so Dabber never taps its own feed, whether or not `processes` still applies when `bundleIDs` is set (not tested; Plan 3a Task 10 notes).
- `FeedSettings` is one Codable value stored as JSON under one UserDefaults key. On/off is not stored: like recording, the feed never starts by itself at launch. It would open the mic, which puts AirPods into call profile.
- First launch: the default input becomes the feed mic, unless it is Dabber Mic (the feed would feed itself).
- `AppEntry.candidates`: running regular apps by name, then other audio process bundle IDs, without the excluded ones and without Dabber.

**Depends on Task 1, Step 8.** The code below expands Safari to `com.apple.WebKit.GPU`, which is right when S2 was not silent (whatever S3 showed). **If S2 was silent** (Safari's ID covers its web audio), make these edits to the code below before running Step 4 (this variant was also compiled: 138 tests, exit 0):
- `FeedSettings.swift`: replace `    static let helpers = ["com.apple.Safari": ["com.apple.WebKit.GPU"]]` with `    static let helpers: [String: [String]] = [:]`
- `FeedSettingsTests.swift`: rename `safariExpandsToItsWebKitAudioHelperAndDabberIsAlwaysExcluded` to `safariNeedsNoHelperAndDabberIsAlwaysExcluded`, and replace `== ["com.apple.Safari", "com.apple.WebKit.GPU", "local.dabber.Dabber"])` with `== ["com.apple.Safari", "local.dabber.Dabber"])`
- in Task 7, `FeedModelTests.swift`: replace `tapBundleIDs: ["com.apple.Safari", "com.apple.WebKit.GPU", "local.dabber.Dabber"]),` with `tapBundleIDs: ["com.apple.Safari", "local.dabber.Dabber"]),`

- [ ] **Step 1: Write the failing tests `Tests/DabberCoreTests/FeedSettingsTests.swift`**

```swift
import Foundation
import Testing
@testable import DabberCore

@Test func safariExpandsToItsWebKitAudioHelperAndDabberIsAlwaysExcluded() {
    #expect(ExclusionList.tapBundleIDs(apps: ["com.apple.Safari"], own: "local.dabber.Dabber")
        == ["com.apple.Safari", "com.apple.WebKit.GPU", "local.dabber.Dabber"])
}

@Test func otherAppsAreExcludedAsIs() {
    #expect(ExclusionList.tapBundleIDs(apps: ["us.zoom.xos", "us.zoom.xos"], own: nil) == ["us.zoom.xos"])
}

@Test func defaultSettingsExcludeSafariAndSendComputerAudio() {
    let s = FeedSettings()
    #expect(s.excludedApps == ["com.apple.Safari"])
    #expect(s.computerAudio)
    #expect(s.micUID == nil)
}

@Test func firstLaunchPicksTheDefaultInputButNeverDabberMic() {
    #expect(FeedSettings.firstLaunch(defaultInput: InputDevice(id: 1, uid: "ap", name: "AirPods")).micUID == "ap")
    #expect(FeedSettings.firstLaunch(defaultInput: InputDevice(id: 2, uid: FeedDevices.micUID, name: "Dabber Mic")).micUID == nil)
    #expect(FeedSettings.firstLaunch(defaultInput: nil).micUID == nil)
}

@Test func settingsRoundTrip() {
    let s = FeedSettings(computerAudio: false, micUID: "ap", micName: "AirPods", excludedApps: ["us.zoom.xos"])
    #expect(FeedSettings.decode(s.encoded()) == s)
    #expect(FeedSettings.decode(nil) == nil)
    #expect(FeedSettings.decode(Data("junk".utf8)) == nil)
}

@Test func candidatesAreRunningAppsThenOtherAudioProcessesWithoutExcludedOrOwn() {
    let list = AppEntry.candidates(
        running: [AppEntry(bundleID: "us.zoom.xos", name: "zoom.us"), AppEntry(bundleID: "com.apple.Music", name: "Music"),
                  AppEntry(bundleID: "com.apple.Safari", name: "Safari")],
        audioBundleIDs: ["com.apple.WebKit.GPU", "us.zoom.xos", "", "local.dabber.Dabber"],
        excluded: ["com.apple.Safari"], own: "local.dabber.Dabber")
    #expect(list.map(\.bundleID) == ["com.apple.Music", "us.zoom.xos", "com.apple.WebKit.GPU"])
}
```

- [ ] **Step 2: Run, expect compile failure**

Run: `scripts/test.sh; echo "exit=$?"`
Expected: `cannot find 'ExclusionList' in scope`, non-zero exit.

- [ ] **Step 3: Write `Sources/DabberCore/Feed/FeedSettings.swift`**

```swift
import Foundation

public enum ExclusionList {
    public static let defaultApps = ["com.apple.Safari"]
    static let helpers = ["com.apple.Safari": ["com.apple.WebKit.GPU"]]

    public static func tapBundleIDs(apps: [String], own: String?) -> [String] {
        var ids = Set(apps)
        for app in apps { ids.formUnion(helpers[app] ?? []) }
        if let own { ids.insert(own) }
        return ids.sorted()
    }
}

public struct FeedSettings: Codable, Equatable, Sendable {
    public var computerAudio = true
    public var micUID: String?
    public var micName: String?
    public var excludedApps = ExclusionList.defaultApps

    public init(computerAudio: Bool = true, micUID: String? = nil, micName: String? = nil,
                excludedApps: [String] = ExclusionList.defaultApps) {
        self.computerAudio = computerAudio
        self.micUID = micUID
        self.micName = micName
        self.excludedApps = excludedApps
    }

    public static func firstLaunch(defaultInput: InputDevice?) -> FeedSettings {
        guard let d = defaultInput, d.uid != FeedDevices.micUID else { return FeedSettings() }
        return FeedSettings(micUID: d.uid, micName: d.name)
    }

    public static func decode(_ data: Data?) -> FeedSettings? {
        data.flatMap { try? JSONDecoder().decode(FeedSettings.self, from: $0) }
    }

    public func encoded() -> Data { (try? JSONEncoder().encode(self)) ?? Data() }
}

public struct AppEntry: Sendable, Equatable, Identifiable {
    public let bundleID: String
    public let name: String
    public var id: String { bundleID }

    public init(bundleID: String, name: String) {
        self.bundleID = bundleID
        self.name = name
    }

    public static func candidates(
        running: [AppEntry], audioBundleIDs: [String], excluded: [String], own: String?
    ) -> [AppEntry] {
        var seen = Set(excluded + [own ?? "", ""])
        var out: [AppEntry] = []
        for app in running.sorted(by: { $0.name.localizedStandardCompare($1.name) == .orderedAscending })
        where seen.insert(app.bundleID).inserted {
            out.append(app)
        }
        for id in audioBundleIDs.sorted() where seen.insert(id).inserted {
            out.append(AppEntry(bundleID: id, name: id))
        }
        return out
    }
}
```

- [ ] **Step 4: Run tests**

Run: `scripts/test.sh; echo "exit=$?"`
Expected: `Test run with 124 tests ... passed`, `exit=0`.

- [ ] **Step 5: Commit**

```zsh
git add Sources/DabberCore/Feed/FeedSettings.swift Tests/DabberCoreTests/FeedSettingsTests.swift
git commit -m "feat: add virtual mic settings, exclusion list and app candidates"
```

---

### Task 7: Feed model for the menu (TDD)

**Files:**
- Create: `Sources/DabberCore/App/FeedModel.swift`, `Tests/DabberCoreTests/FeedModelTests.swift`

`@MainActor @Observable` like `RecorderModel`, with the engine, devices and apps injected:
- Mic picker: all inputs except Dabber Mic; a selected mic that is gone stays listed as "not connected".
- `driverInstalled` = an input with UID `Dabber_UID` exists (spec: "no device with the Dabber Mic UID"). Without it, on is disabled and the status says so.
- Every settings change is persisted and, while on, applied to the engine.
- `tick()` copies status and level from the engine (the 0.2 s app timer).

- [ ] **Step 1: Write the failing tests `Tests/DabberCoreTests/FeedModelTests.swift`**

```swift
import Foundation
import Testing
@testable import DabberCore

private final class FakeFeed: FeedControlling, @unchecked Sendable {
    var applied: [FeedConfig?] = []
    var status: FeedStatus = .off
    var levelDb: Double = -160
    func apply(_ config: FeedConfig?) { applied.append(config) }
}

private final class Devices: DeviceCatalog, @unchecked Sendable {
    var devices: [InputDevice]
    init(_ devices: [InputDevice]) { self.devices = devices }
    func inputs() throws -> [InputDevice] { devices }
    func defaultInputUID() -> String? { nil }
}

private struct Apps: AppCatalog {
    func running() -> [AppEntry] { [AppEntry(bundleID: "us.zoom.xos", name: "zoom.us")] }
    func audioBundleIDs() -> [String] { ["com.apple.WebKit.GPU"] }
    func name(bundleID: String) -> String { bundleID == "com.apple.Safari" ? "Safari" : bundleID }
}

private let airpods = InputDevice(id: 1, uid: "ap", name: "AirPods")
private let dabberMic = InputDevice(id: 9, uid: FeedDevices.micUID, name: "Dabber Mic")

@MainActor
private func makeModel(
    _ feed: FakeFeed, devices: [InputDevice] = [airpods, dabberMic], settings: FeedSettings = FeedSettings(micUID: "ap", micName: "AirPods"),
    saved: @escaping @Sendable (FeedSettings) -> Void = { _ in }
) -> FeedModel {
    let m = FeedModel(
        engine: feed, catalog: Devices(devices), apps: Apps(), ownBundleID: "local.dabber.Dabber", settings: settings,
        persist: saved)
    m.refresh()
    return m
}

@MainActor @Test func micPickerHidesDabberMicAndDetectsTheDriver() {
    let m = makeModel(FakeFeed())
    #expect(m.micChoices.map(\.id) == ["ap"])
    #expect(m.driverInstalled)
    #expect(m.canTurnOn)
}

@MainActor @Test func missingDriverBlocksTurningOnAndSaysSo() {
    let feed = FakeFeed()
    let m = makeModel(feed, devices: [airpods])
    #expect(!m.driverInstalled)
    m.setOn(true)
    #expect(!m.isOn)
    #expect(feed.applied.isEmpty)
    #expect(m.statusText == "Dabber Mic driver not installed")
}

@MainActor @Test func turningOnAppliesTheExpandedConfigAndOffStops() {
    let feed = FakeFeed()
    let m = makeModel(feed)
    m.setOn(true)
    m.setOn(false)
    #expect(feed.applied == [
        FeedConfig(micUID: "ap", computerAudio: true,
                   tapBundleIDs: ["com.apple.Safari", "com.apple.WebKit.GPU", "local.dabber.Dabber"]),
        nil,
    ])
}

@MainActor @Test func settingChangesPersistAndReachARunningFeed() {
    let feed = FakeFeed()
    nonisolated(unsafe) var saved: [FeedSettings] = []
    let m = makeModel(feed) { saved.append($0) }
    m.setComputerAudio(false)
    #expect(feed.applied.isEmpty)
    m.setOn(true)
    m.exclude("us.zoom.xos")
    m.include("com.apple.Safari")
    m.selectMic(nil)
    #expect(saved.last == FeedSettings(computerAudio: false, micUID: nil, micName: nil, excludedApps: ["us.zoom.xos"]))
    #expect(feed.applied.last == FeedConfig(micUID: nil, computerAudio: false, tapBundleIDs: ["local.dabber.Dabber", "us.zoom.xos"]))
    #expect(feed.applied.count == 4)
}

@MainActor @Test func excludedAndCandidateAppsAreListed() {
    let m = makeModel(FakeFeed())
    #expect(m.excluded == [AppEntry(bundleID: "com.apple.Safari", name: "Safari")])
    #expect(m.candidates.map(\.bundleID) == ["us.zoom.xos", "com.apple.WebKit.GPU"])
    m.exclude("us.zoom.xos")
    #expect(m.candidates.map(\.bundleID) == ["com.apple.WebKit.GPU"])
}

@MainActor @Test func disconnectedMicStaysSelectableAndStatusSaysComputerAudioOnly() {
    let feed = FakeFeed()
    let m = makeModel(feed, devices: [dabberMic])
    #expect(m.micChoices == [FeedModel.MicChoice(id: "ap", name: "AirPods", connected: false)])
    m.setOn(true)
    feed.status = .micMissing
    m.tick()
    #expect(m.statusText == "AirPods not connected — computer audio only")
}

@MainActor @Test func statusAndLevelFollowTheEngine() {
    let feed = FakeFeed()
    let m = makeModel(feed)
    feed.levelDb = -12
    m.tick()
    #expect(m.levelDb == -160)
    m.setOn(true)
    feed.status = .running
    m.tick()
    #expect(m.levelDb == -12)
    #expect(m.statusText == "On")
    feed.status = .restarting("nsrt")
    m.tick()
    #expect(m.statusText == "Restarting (nsrt)")
}

@MainActor @Test func nothingSelectedCannotTurnOn() {
    let m = makeModel(FakeFeed(), settings: FeedSettings(computerAudio: false))
    #expect(!m.canTurnOn)
}
```

- [ ] **Step 2: Run, expect compile failure**

Run: `scripts/test.sh; echo "exit=$?"`
Expected: `cannot find type 'FeedControlling' in scope`, non-zero exit.

- [ ] **Step 3: Write `Sources/DabberCore/App/FeedModel.swift`**

```swift
import AppKit
import Foundation
import Observation

public protocol FeedControlling: Sendable {
    func apply(_ config: FeedConfig?)
    var status: FeedStatus { get }
    var levelDb: Double { get }
}

extension FeedEngine: FeedControlling {}

public protocol AppCatalog: Sendable {
    func running() -> [AppEntry]
    func audioBundleIDs() -> [String]
    func name(bundleID: String) -> String
}

public struct LiveAppCatalog: AppCatalog {
    public init() {}

    public func running() -> [AppEntry] {
        NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }.compactMap { app in
            app.bundleIdentifier.map { AppEntry(bundleID: $0, name: app.localizedName ?? $0) }
        }
    }

    public func audioBundleIDs() -> [String] { ((try? audioProcesses()) ?? []).map(\.bundleID) }

    public func name(bundleID: String) -> String {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
            .map { FileManager.default.displayName(atPath: $0.path) } ?? bundleID
    }
}

@MainActor @Observable
public final class FeedModel {
    public struct MicChoice: Identifiable, Equatable, Sendable {
        public let id: String
        public let name: String
        public let connected: Bool
    }

    public private(set) var isOn = false
    public private(set) var settings: FeedSettings
    public private(set) var micChoices: [MicChoice] = []
    public private(set) var driverInstalled = false
    public private(set) var excluded: [AppEntry] = []
    public private(set) var candidates: [AppEntry] = []
    public private(set) var status: FeedStatus = .off
    public private(set) var levelDb: Double = -160

    private let engine: any FeedControlling
    private let catalog: any DeviceCatalog
    private let apps: any AppCatalog
    private let ownBundleID: String?
    private let persist: @Sendable (FeedSettings) -> Void

    public init(
        engine: any FeedControlling, catalog: any DeviceCatalog, apps: any AppCatalog, ownBundleID: String?,
        settings: FeedSettings, persist: @escaping @Sendable (FeedSettings) -> Void
    ) {
        self.engine = engine
        self.catalog = catalog
        self.apps = apps
        self.ownBundleID = ownBundleID
        self.settings = settings
        self.persist = persist
    }

    public var canTurnOn: Bool { driverInstalled && (settings.computerAudio || settings.micUID != nil) }

    public var statusText: String {
        if !driverInstalled { return "Dabber Mic driver not installed" }
        switch status {
        case .off: return "Off"
        case .running: return "On"
        case .micMissing:
            let name = settings.micName ?? settings.micUID ?? "Microphone"
            return "\(name) not connected — " + (settings.computerAudio ? "computer audio only" : "silent")
        case .restarting(let reason): return "Restarting (\(reason))"
        case .driverMissing: return "Dabber Mic driver not installed"
        case .failed(let why): return "Failed: \(why)"
        }
    }

    public func refresh() {
        let inputs = (try? catalog.inputs()) ?? []
        driverInstalled = inputs.contains { $0.uid == FeedDevices.micUID }
        var choices = inputs.filter { $0.uid != FeedDevices.micUID }.map { MicChoice(id: $0.uid, name: $0.name, connected: true) }
        if let uid = settings.micUID {
            if let live = choices.first(where: { $0.id == uid }), live.name != settings.micName {
                settings.micName = live.name
                persist(settings)
            }
            if !choices.contains(where: { $0.id == uid }) {
                choices.append(MicChoice(id: uid, name: settings.micName ?? uid, connected: false))
            }
        }
        micChoices = choices
        refreshApps()
    }

    public func refreshApps() {
        excluded = settings.excludedApps.map { AppEntry(bundleID: $0, name: apps.name(bundleID: $0)) }
        candidates = AppEntry.candidates(
            running: apps.running(), audioBundleIDs: apps.audioBundleIDs(), excluded: settings.excludedApps,
            own: ownBundleID)
    }

    public func setOn(_ on: Bool) {
        guard on != isOn, !on || canTurnOn else { return }
        isOn = on
        engine.apply(on ? config : nil)
    }

    public func setComputerAudio(_ on: Bool) {
        settings.computerAudio = on
        changed()
    }

    public func selectMic(_ uid: String?) {
        settings.micUID = uid
        settings.micName = uid.flatMap { id in micChoices.first { $0.id == id }?.name }
        changed()
    }

    public func exclude(_ bundleID: String) {
        guard !settings.excludedApps.contains(bundleID) else { return }
        settings.excludedApps.append(bundleID)
        changed()
    }

    public func include(_ bundleID: String) {
        settings.excludedApps.removeAll { $0 == bundleID }
        changed()
    }

    public func tick() {
        status = engine.status
        levelDb = isOn ? engine.levelDb : -160
    }

    var config: FeedConfig {
        FeedConfig(
            micUID: settings.micUID, computerAudio: settings.computerAudio,
            tapBundleIDs: ExclusionList.tapBundleIDs(apps: settings.excludedApps, own: ownBundleID))
    }

    private func changed() {
        persist(settings)
        refresh()
        if isOn { engine.apply(config) }
    }
}
```

- [ ] **Step 4: Run tests**

Run: `scripts/test.sh; echo "exit=$?"`
Expected: `Test run with 132 tests ... passed`, `exit=0`.

- [ ] **Step 5: Commit**

```zsh
git add Sources/DabberCore/App/FeedModel.swift Tests/DabberCoreTests/FeedModelTests.swift
git commit -m "feat: add virtual mic model with settings, mic picker and status"
```

---

### Task 8: Zero-run scanner, headless `--scan-input` and `--feed` (TDD for the scanner)

**Files:**
- Create: `Sources/DabberCore/Model/ZeroRunScanner.swift`, `Tests/DabberCoreTests/ZeroRunScannerTests.swift`
- Modify: `Sources/Dabber/Headless.swift`

`ZeroRunScanner` counts runs of frames whose every channel is exactly 0.0, of at least `minFrames`, after the first non-zero frame. It keeps the first 32 runs (capacity reserved up front, so the IO thread does not allocate). `--scan-input` uses it with `minFrames` 16 on a real input device, optionally with the reader's buffer size set, which is what a call app does.

- [ ] **Step 1: Write the failing tests `Tests/DabberCoreTests/ZeroRunScannerTests.swift`**

```swift
import Testing
@testable import DabberCore

private func scan(_ chunks: [[Float]], channels: Int = 1, minFrames: Int = 3) -> ZeroRunScanner {
    var s = ZeroRunScanner(minFrames: minFrames)
    for chunk in chunks { chunk.withUnsafeBufferPointer { s.scan($0, channels: channels) } }
    s.finish()
    return s
}

@Test func leadingSilenceIsNotARun() {
    let s = scan([[0, 0, 0, 0, 0.5, 0.5]])
    #expect(s.firstSignalFrame == 4)
    #expect(s.runCount == 0)
}

@Test func zeroRunAfterSignalIsCountedAcrossChunks() {
    let s = scan([[0.5, 0, 0], [0, 0, 0.5]])
    #expect(s.runs == [ZeroRunScanner.Run(startFrame: 1, frames: 4)])
    #expect(s.longest == 4)
}

@Test func shortZeroRunsAreIgnored() {
    #expect(scan([[0.5, 0, 0, 0.5]]).runCount == 0)
}

@Test func trailingRunIsClosedByFinish() {
    let s = scan([[0.5, 0, 0, 0]])
    #expect(s.runs == [ZeroRunScanner.Run(startFrame: 1, frames: 3)])
}

@Test func aFrameIsZeroOnlyWhenEveryChannelIsZero() {
    let s = scan([[0.5, 0.5, 0, 0.1, 0, 0.1, 0, 0.1]], channels: 2)
    #expect(s.runCount == 0)
    #expect(s.framesScanned == 4)
}

@Test func onlyTheFirstRunsAreKeptButAllAreCounted() {
    var chunk: [Float] = []
    for _ in 0..<40 { chunk += [0.5, 0, 0, 0] }
    let s = scan([chunk])
    #expect(s.runCount == 40)
    #expect(s.runs.count == ZeroRunScanner.keptRuns)
}
```

- [ ] **Step 2: Run, expect compile failure**

Run: `scripts/test.sh; echo "exit=$?"`
Expected: `cannot find type 'ZeroRunScanner' in scope`, non-zero exit.

- [ ] **Step 3: Write `Sources/DabberCore/Model/ZeroRunScanner.swift`**

```swift
public struct ZeroRunScanner: Sendable {
    public struct Run: Sendable, Equatable {
        public let startFrame: Int
        public let frames: Int
    }

    public static let keptRuns = 32
    public let minFrames: Int
    public private(set) var framesScanned = 0
    public private(set) var firstSignalFrame: Int?
    public private(set) var runCount = 0
    public private(set) var longest = 0
    public private(set) var runs: [Run] = []
    private var runStart: Int?

    public init(minFrames: Int) {
        self.minFrames = minFrames
        runs.reserveCapacity(Self.keptRuns)
    }

    public mutating func scan(_ samples: UnsafeBufferPointer<Float>, channels: Int) {
        let frames = samples.count / channels
        for f in 0..<frames {
            var zero = true
            for c in 0..<channels where samples[f * channels + c] != 0 {
                zero = false
                break
            }
            let index = framesScanned + f
            if !zero {
                if firstSignalFrame == nil { firstSignalFrame = index }
                close(at: index)
            } else if firstSignalFrame != nil, runStart == nil {
                runStart = index
            }
        }
        framesScanned += frames
    }

    public mutating func finish() { close(at: framesScanned) }

    private mutating func close(at index: Int) {
        guard let start = runStart else { return }
        runStart = nil
        let frames = index - start
        guard frames >= minFrames else { return }
        runCount += 1
        longest = max(longest, frames)
        if runs.count < Self.keptRuns { runs.append(Run(startFrame: start, frames: frames)) }
    }
}
```

- [ ] **Step 4: Run tests**

Run: `scripts/test.sh; echo "exit=$?"`
Expected: `Test run with 138 tests ... passed`, `exit=0`.

- [ ] **Step 5: Add `--scan-input <uid> <seconds> [bufferFrames]` and `--feed ...` to `Headless.dispatch`**

`--feed --mic <uid> [--computer-audio] [--exclude-bundle id]... --seconds N`: `--mic` is optional, and an absent UID runs the mic-absent mode. `--exclude-bundle` takes app IDs and goes through `ExclusionList.tapBundleIDs`, like the menu. The command exits 0 when the feed was `running` or `micMissing` throughout, 2 when the driver is missing, 1 on any other state (a restart during an automated check counts as a failure).

Insert directly after the `--feed-probe` case:
```swift
        case "--scan-input":
            guard args.count == 3 || args.count == 4, let seconds = Double(args[2]) else { return 64 }
            let device = try deviceID(uid: args[1])
            guard device != kAudioObjectUnknown else {
                log.line("no device with uid \(args[1])")
                return 2
            }
            if args.count == 4 {
                guard var frames = UInt32(args[3]) else { return 64 }
                var a = address(kAudioDevicePropertyBufferFrameSize)
                let status = AudioObjectSetPropertyData(device, &a, 0, nil, UInt32(MemoryLayout<UInt32>.size), &frames)
                guard status == noErr else {
                    log.line("set buffer frame size failed: \(fourCC(status))")
                    return 1
                }
            }
            log.line("buffer frames: \(try getValue(device, address(kAudioDevicePropertyBufferFrameSize), default: UInt32(0)))")
            let probe = InputScan()
            let runner = try IOProcRunner(device: device) { list, time in probe.handle(list, time) }
            Thread.sleep(forTimeInterval: seconds)
            runner.stop()
            probe.scanner.finish()
            let s = probe.scanner
            log.line("SCAN_START_NANOS \(probe.firstNanos)")
            log.line(
                "SCAN frames=\(s.framesScanned) firstSignal=\(s.firstSignalFrame.map(String.init) ?? "none") "
                    + "zeroRuns=\(s.runCount) longest=\(s.longest) discontinuities=\(probe.discontinuities) "
                    + "unexpectedLayouts=\(probe.unexpectedLayouts)")
            for run in s.runs {
                log.line(String(format: "ZERO_RUN at=%.4f frames=%d", Double(run.startFrame) / 48_000, run.frames))
            }
            return 0
        case "--feed":
            var micUID: String?
            var computer = false
            var excluded: [String] = []
            var seconds = 0.0
            var i = 1
            while i < args.count {
                switch args[i] {
                case "--computer-audio":
                    computer = true
                case "--mic":
                    i += 1
                    guard i < args.count else { return 64 }
                    micUID = args[i]
                case "--exclude-bundle":
                    i += 1
                    guard i < args.count else { return 64 }
                    excluded.append(args[i])
                case "--seconds":
                    i += 1
                    guard i < args.count, let s = Double(args[i]) else { return 64 }
                    seconds = s
                default:
                    log.line("unknown option \(args[i])")
                    return 64
                }
                i += 1
            }
            guard seconds > 0 else { return 64 }
            let config = FeedConfig(
                micUID: micUID, computerAudio: computer,
                tapBundleIDs: ExclusionList.tapBundleIDs(apps: excluded, own: Bundle.main.bundleIdentifier))
            log.line("FEED config mic=\(micUID ?? "none") computer=\(computer) tap excludes \(config.tapBundleIDs)")
            let engine = FeedEngine()
            engine.applyAndWait(config)
            log.line("FEED_START_NANOS \(HostClock.nowNanos())")
            var lastNotRunning = engine.status
            for t in 1...max(1, Int(seconds)) {
                Thread.sleep(forTimeInterval: 1)
                let status = engine.status
                if status != .running { lastNotRunning = status }
                log.line("t=\(t) \(status) \(String(format: "%.1f", engine.levelDb)) dB")
            }
            if let r = engine.renderer {
                log.line(
                    "FEED cycles=\(r.cycles) frames=\(r.framesRendered) discontinuities=\(r.discontinuities) "
                        + "unexpectedLayouts=\(r.unexpectedLayouts) skippedInputs=\(r.skippedInputs)")
            }
            engine.applyAndWait(nil)
            switch lastNotRunning {
            case .running, .micMissing: return 0
            case .driverMissing:
                log.line("driver missing: no device with uid \(FeedDevices.feedUID)")
                return 2
            default: return 1
            }
```

Append to the end of `Sources/Dabber/Headless.swift`:
```swift

final class InputScan: @unchecked Sendable {
    var scanner = ZeroRunScanner(minFrames: 16)
    var firstNanos: UInt64 = 0
    var discontinuities = 0
    var unexpectedLayouts = 0
    private var nextSampleTime = -1.0

    func handle(_ list: UnsafePointer<AudioBufferList>, _ time: UnsafePointer<AudioTimeStamp>) {
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: list))
        guard buffers.count == 1, let data = buffers[0].mData, buffers[0].mNumberChannels > 0 else {
            unexpectedLayouts += 1
            return
        }
        let channels = Int(buffers[0].mNumberChannels)
        let count = Int(buffers[0].mDataByteSize) / MemoryLayout<Float>.size
        let t = time.pointee
        if firstNanos == 0 { firstNanos = HostClock.nanos(hostTime: t.mHostTime) }
        if nextSampleTime >= 0, t.mSampleTime != nextSampleTime { discontinuities += 1 }
        nextSampleTime = t.mSampleTime + Double(count / channels)
        scanner.scan(UnsafeBufferPointer(start: data.assumingMemoryBound(to: Float.self), count: count), channels: channels)
    }
}
```

- [ ] **Step 6: Build and run the quick paths**

Run:
```zsh
scripts/build-app.sh
scripts/run-headless.sh "$PWD/build/feed-absent.log" --feed --mic no-such-uid --computer-audio --seconds 3
scripts/run-headless.sh "$PWD/build/scan-missing.log" --scan-input no-such-uid 1; echo "exit=$?"
```
Expected:
- `feed-absent.log`: `FEED config mic=no-such-uid computer=true tap excludes ["local.dabber.Dabber"]`, three `t=N micMissing ...` lines, a `FEED cycles=...` line with `discontinuities=0 unexpectedLayouts=0 skippedInputs=0`, `EXIT 0`.
- `scan-missing.log`: `no device with uid no-such-uid`, `EXIT 2`, `exit=1`.

- [ ] **Step 7: Commit**

```zsh
git add Sources/DabberCore/Model/ZeroRunScanner.swift Tests/DabberCoreTests/ZeroRunScannerTests.swift Sources/Dabber/Headless.swift
git diff --cached --stat
git commit -m "feat: add headless feed and input zero-run scan commands"
```

---

### Task 9: "Virtual mic" menu section (HUMAN: one look)

**Files:**
- Modify: `Sources/Dabber/AppDelegate.swift`, `Sources/Dabber/MenuApp.swift`

Bindings are `Binding(get:set:)` onto model methods, as the recording rows do; no `@State`/`@Bindable`. The candidate list refreshes when an app launches or quits and on every device change. Private aggregates and taps belong to the process (`kAudioAggregateDeviceIsPrivateKey` docs in `AudioHardware.h`), so quitting Dabber needs no feed teardown. That is from the header docs, not tested.

- [ ] **Step 1: Feed model and wiring in `AppDelegate`**

In `Sources/Dabber/AppDelegate.swift` replace
```swift
    private var timer: Timer?
    private var devices: PropertyWatcher?
```
with
```swift
    private static let feedKey = "virtualMic"

    @MainActor static let feed = FeedModel(
        engine: FeedEngine(), catalog: LiveDeviceCatalog(), apps: LiveAppCatalog(),
        ownBundleID: Bundle.main.bundleIdentifier,
        settings: FeedSettings.decode(UserDefaults.standard.data(forKey: feedKey))
            ?? FeedSettings.firstLaunch(defaultInput: defaultInputDeviceUID().flatMap { uid in
                (try? inputDevices())?.first { $0.uid == uid }
            }),
        persist: { UserDefaults.standard.set($0.encoded(), forKey: feedKey) })

    private var timer: Timer?
    private var devices: PropertyWatcher?
    private var appObservers: [NSObjectProtocol] = []
```
and replace
```swift
        Task { @MainActor in Self.model.refreshDevices() }
        timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { _ in
            Task { @MainActor in Self.model.tick() }
        }
        devices = try? PropertyWatcher(objects: [(systemObject, [kAudioHardwarePropertyDevices])]) { _, _ in
            Task { @MainActor in Self.model.refreshDevices() }
        }
```
with
```swift
        Task { @MainActor in
            Self.model.refreshDevices()
            Self.feed.refresh()
        }
        timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { _ in
            Task { @MainActor in
                Self.model.tick()
                Self.feed.tick()
            }
        }
        devices = try? PropertyWatcher(objects: [(systemObject, [kAudioHardwarePropertyDevices])]) { _, _ in
            Task { @MainActor in
                Self.model.refreshDevices()
                Self.feed.refresh()
            }
        }
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            appObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { _ in
                Task { @MainActor in Self.feed.refreshApps() }
            })
        }
```

- [ ] **Step 2: The section in `MenuApp.swift`**

In `Sources/Dabber/MenuApp.swift`:
- replace `MenuContent(model: AppDelegate.model)` with `MenuContent(model: AppDelegate.model, feed: AppDelegate.feed)`;
- in `struct MenuContent`, after `let model: RecorderModel` add `let feed: FeedModel`;
- replace
```swift
            Divider()
            Button("Show in Finder") {
```
with
```swift
            Divider()
            VirtualMicSection(model: feed)
            Divider()
            Button("Show in Finder") {
```
- append to the end of the file:
```swift

struct VirtualMicSection: View {
    let model: FeedModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle("Virtual mic", isOn: Binding(get: { model.isOn }, set: { model.setOn($0) }))
                .disabled(!model.isOn && !model.canTurnOn)
            Toggle("Computer audio", isOn: Binding(get: { model.settings.computerAudio }, set: { model.setComputerAudio($0) }))
            Picker("Microphone", selection: Binding(get: { model.settings.micUID ?? "" }, set: { model.selectMic($0.isEmpty ? nil : $0) })) {
                Text("None").tag("")
                ForEach(model.micChoices) { choice in
                    Text(choice.connected ? choice.name : "\(choice.name) (not connected)").tag(choice.id)
                }
            }
            Text("Not sent to the virtual mic:").font(.caption).foregroundStyle(.secondary)
            ForEach(model.excluded) { app in
                HStack {
                    Text(app.name)
                    Spacer()
                    Button { model.include(app.bundleID) } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.borderless)
                }
            }
            Menu("Add app") {
                ForEach(model.candidates) { app in
                    Button(app.name) { model.exclude(app.bundleID) }
                }
            }
            .disabled(model.candidates.isEmpty)
            ProgressView(value: max(0, min(1, (model.levelDb + 60) / 60)))
            Text(model.statusText).font(.caption).foregroundStyle(.secondary)
        }
    }
}
```

- [ ] **Step 3: Tests and build**

Run: `scripts/test.sh; echo "exit=$?"`, then `scripts/build-app.sh`.
Expected: `Test run with 138 tests ... passed`, `exit=0`; the build prints the designated line.

- [ ] **Step 4: Look at it (HUMAN)**

Tell the user:
> Quit any running Dabber, then run `open build/Dabber.app` and click the menu bar icon.
> Under the recording controls there is a "Virtual mic" section. Check: the mic picker lists your mics but not Dabber Mic; Safari is listed as not sent; "Add app" lists running apps.
> Turn Virtual mic on, play something in Music, watch the level bar move, then turn it off.
> Tell me what looks wrong, if anything (a screenshot helps).

Fix layout issues the user reports in `MenuApp.swift` only; rerun Step 3 after each fix.

- [ ] **Step 5: Commit**

```zsh
git add Sources/Dabber/AppDelegate.swift Sources/Dabber/MenuApp.swift
git diff --cached --stat
git commit -m "feat: add virtual mic section to the menu"
```

---

### Task 10: Hardware check of the live feed (automated, beeps)

**Files:**
- Create: `docs/spikes/2026-09-23-feed-hardware-check.md`

Precondition: the finalizer fix `0dbebb1` is in the branch (`git merge-base --is-ancestor 0dbebb1 HEAD && echo ok` prints `ok`). The recording checks rely on it (Spike B run 1).

Four runs:
- **A**: tone helper plays; feed = computer audio only; the Dabber Mic is recorded 60 s and scanned 60 s at reader buffers 128, 512 and 4096 at the same time.
- **B**: same with the built-in mic in the feed; 30 s scans at the three sizes.
- **C**: tone helper plays; feed excludes it; the Dabber Mic recording must be silent.
- **D**: mic absent: feed with a UID that does not exist runs computer audio only.

- [ ] **Step 1: Build**

Run: `scripts/build-app.sh && scripts/build-tone-helper.sh`
Expected: two designated lines (`local.dabber.Dabber`, `local.dabber.tonehelper`).

- [ ] **Step 2: Run A**

```zsh
H=build/ToneHelper.app
rm -rf build/feedA
DABBER_APP=$H scripts/run-headless.sh "$PWD/build/toneA.log" --play-tone default 80 0 > /dev/null &
sleep 2
scripts/run-headless.sh "$PWD/build/feedA.log" --feed --computer-audio --seconds 72 > /dev/null &
sleep 3
for f in 128 512 4096; do
  scripts/run-headless.sh "$PWD/build/scanA-$f.log" --scan-input Dabber_UID 60 $f > /dev/null &
done
scripts/run-headless.sh "$PWD/build/recA.log" --record --mic Dabber_UID --seconds 60 --out "$PWD/build/feedA" | tail -2
wait
grep -h -E 'SCAN |ZERO_RUN|EXIT' build/scanA-*.log
grep -E 'FEED |EXIT' build/feedA.log; tail -1 build/toneA.log
```
Expected:
- each scan: `buffer frames: 128|512|4096`, `SCAN frames=` about 2,880,000, `firstSignal=0`, `zeroRuns=0 longest=0 discontinuities=0 unexpectedLayouts=0`, no `ZERO_RUN` line, `EXIT 0`;
- `feedA.log`: every `t=` line `running`, `FEED ... discontinuities=0 unexpectedLayouts=0 skippedInputs=0`, `EXIT 0`;
- `recA.log`: `FINALIZED ... gaps=1 resampled=0` or `gaps=0`, `EXIT 0`; tone log `EXIT 0`.

- [ ] **Step 3: Checks on the Run A recording**

The 3a Task 8 checks, with the onset defaulting to 0 because the tone is already on when the recording starts.
```zsh
S=$(ls -d build/feedA/*/ | tail -1); M="$S/mic - Dabber Mic.m4a"
ffmpeg -hide_banner -nostats -i "$M" -af silencedetect=n=-50dB:d=0.005 -f null - 2>&1 | grep -oE 'silence_(start|end): [0-9.]+'
ONSET=$(ffmpeg -hide_banner -nostats -i "$M" -af silencedetect=n=-50dB:d=0.005 -f null - 2>&1 | grep -m1 -oE 'silence_end: [0-9.]+' | awk '{print $2}'); ONSET=${ONSET:-0}
ffmpeg -hide_banner -nostats -ss $(( ONSET + 1 )) -t 50 -i "$M" -af astats=metadata=0:measure_perchannel=0:measure_overall=Peak_level+RMS_level -f null - 2>&1 | grep -oE '(Peak|RMS) level dB: .*'
DUR=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$M")
ffmpeg -hide_banner -nostats -i "$M" -af "highpass=f=2000,highpass=f=2000,asetnsamples=48000,astats=metadata=1:reset=1,ametadata=mode=print:key=lavfi.astats.Overall.Peak_level:file=-" -f null - 2>/dev/null \
  | paste - - | awk -v o=$ONSET -v d=$DUR '{sub("pts_time:","",$3); sub(".*=","",$4); if ($4 != "-inf" && $3+0 >= o+1 && $3+0 < d-2 && $4+0 > -30) print "click second", $3, "peak", $4}'
```
Expected:
- silencedetect: at most a `silence_start: 0` with a `silence_end` under 1 s (recorder start-up), nothing after;
- Peak and RMS steady, about 3 dB apart (a sine); their absolute values depend on the output volume if the tap is post-volume, which is not known, so no absolute threshold;
- **no** `click second` lines.

Room sounds are not in Run A (no mic), so any click line is a real finding.

- [ ] **Step 4: Run B (built-in mic in the feed)**

```zsh
DABBER_APP=$H scripts/run-headless.sh "$PWD/build/toneB.log" --play-tone default 45 0 > /dev/null &
sleep 2
scripts/run-headless.sh "$PWD/build/feedB3.log" --feed --mic BuiltInMicrophoneDevice --computer-audio --seconds 38 > /dev/null &
sleep 3
for f in 128 512 4096; do
  scripts/run-headless.sh "$PWD/build/scanB-$f.log" --scan-input Dabber_UID 30 $f > /dev/null &
done
wait
grep -h -E 'SCAN |ZERO_RUN|EXIT' build/scanB-*.log
grep -E 'FEED |EXIT' build/feedB3.log
```
Expected: like Run A with `SCAN frames=` about 1,440,000 each; `feedB3.log` all `running`.

- [ ] **Step 5: Run C (the helper is excluded from the feed)**

```zsh
rm -rf build/feedC
DABBER_APP=$H scripts/run-headless.sh "$PWD/build/toneC.log" --play-tone default 40 0 > /dev/null &
sleep 2
scripts/run-headless.sh "$PWD/build/feedC.log" --feed --computer-audio --exclude-bundle local.dabber.tonehelper --seconds 33 > /dev/null &
sleep 3
scripts/run-headless.sh "$PWD/build/recC.log" --record --mic Dabber_UID --seconds 25 --out "$PWD/build/feedC" | tail -2
wait
grep -E 'tap excludes|t=5 |EXIT' build/feedC.log
S=$(ls -d build/feedC/*/ | tail -1)
ffmpeg -hide_banner -nostats -i "$S/mic - Dabber Mic.m4a" -af silencedetect=n=-50dB:d=1 -f null - 2>&1 | grep -oE 'silence_(start|end): [0-9.]+' | paste - -
```
Expected: `tap excludes ["local.dabber.Dabber", "local.dabber.tonehelper"]`; the feed level at about -160 dB (or only short notification sounds); silencedetect: `silence_start: 0` and no `silence_end` before the end. If E2 in Task 1 was silent but this is not, the feed path loses the exclusion: record it and stop.

- [ ] **Step 6: Run D (mic absent)**

Run: `scripts/run-headless.sh "$PWD/build/feedD.log" --feed --mic no-such-uid --computer-audio --seconds 5`
Expected: every `t=` line `micMissing`, `EXIT 0`.

- [ ] **Step 7: Decide on the driver latency**

If every scan in Runs A and B shows `zeroRuns=0`, Run A's silencedetect shows nothing after start-up, and there are no click lines: **skip Task 11** and write "driver latency not needed, measured" in the doc.

If any scan shows a `ZERO_RUN`, run the same scans once more to rule out a one-off. If it repeats, Task 11 applies. Record the `ZERO_RUN` lines (position, length) and the reader buffer sizes where they occur.

- [ ] **Step 8: Write `docs/spikes/2026-09-23-feed-hardware-check.md` and commit**

Record every `SCAN`, `ZERO_RUN`, `FEED` and `t=` summary line (first/last), the silencedetect, peak/RMS and click-locator outputs, Run C's tap list and level, Run D's status, and the Step 7 decision.
```zsh
git add docs/spikes/2026-09-23-feed-hardware-check.md
git commit -m "docs: record virtual mic feed hardware check"
```

---

### Task 11 (only if Task 10 Step 7 says so): driver latency (HUMAN: reinstall)

**Files:**
- Modify: `Driver/BlackHole/BlackHole/BlackHole.c` (upstream line 235), `scripts/build-driver.sh`, `Driver/NOTICE`

`kLatency_Frame_Size` sets both devices' safety offset (`:2739`) and stream latency (`:3163`) and grows the ring (`:337`). With `N` frames the Mic reads `N` frames further back and the Feed writes `N` frames further ahead, so the underrun margin grows by `2N` and the Feed-to-Mic delay grows by about `2N` frames (256: about 10.7 ms). Upstream defines it without `#ifndef`, so a `-D` alone would be overridden: the define needs a guard.

- [ ] **Step 1: Make the latency a build-time define**

In `Driver/BlackHole/BlackHole/BlackHole.c` replace line 235
```c
#define                             kLatency_Frame_Size                 0
```
with
```c
#ifndef kLatency_Frame_Size
#define                             kLatency_Frame_Size                 0
#endif
```
In `scripts/build-driver.sh`, add the line `  -DkLatency_Frame_Size=256` directly after `  -DkSampleRates=48000` (last entry of `defines=(`).
Append to the change list in `Driver/NOTICE`:
```
- 2026-09-23: kLatency_Frame_Size can be set at build time (#ifndef guard); Dabber builds it with 256.
```

- [ ] **Step 2: Build and inspect**

Run: `scripts/build-driver.sh; echo "exit=$?"; git diff --numstat -- Driver/BlackHole`
Expected, as in a scratch run: `build/DabberMic.driver: replacing existing signature`, the Plan 3a designated line, `exit=0`, no warnings; numstat `2	0	Driver/BlackHole/BlackHole/BlackHole.c` (two guard lines added).

- [ ] **Step 3: Reinstall (HUMAN)**

Tell the user:
> In Terminal: `cd dabber && scripts/install-driver.sh`
> Type your password when asked. Sound stops for a few seconds, then comes back.
> Tell me when it prints `installed`.

- [ ] **Step 4: Measure again**

Run `--play-tone Dabber_2_UID 2 0` (the Plan 3a self-test; expect `EXIT 0`), then Task 10 Steps 2 and 4 again. Expected: no `ZERO_RUN` lines. Add the before/after scans to the Task 10 doc.

- [ ] **Step 5: Commit**

```zsh
git add Driver/BlackHole/BlackHole/BlackHole.c scripts/build-driver.sh Driver/NOTICE docs/spikes/2026-09-23-feed-hardware-check.md
git diff --cached --stat
git commit -m "fix: give the dabber mic driver 256 frames of latency against feed underruns"
```

If zero runs remain with 256, stop and report the numbers; do not raise `N` without the user.

---

### Task 12: Final test, a real call and OBS (HUMAN)

**Files:**
- Modify: `docs/spikes/2026-09-23-feed-hardware-check.md`

- [ ] **Step 1: Call test (HUMAN)**

Tell the user:
> Open Dabber from the menu bar: Virtual mic on, Computer audio on, mic = your AirPods, Safari in the "not sent" list. If the call runs in an app, not Safari, add that app with "Add app".
> Start a call (Safari or the app) with a second device or a person; in the call pick "Dabber Mic" as the microphone. Play music on the Mac and talk.
> Ask the other side: do they hear the music and your voice, and do they hear themselves back (echo)?
> Then disconnect the AirPods (Control Center, Bluetooth, click them), wait 10 s, connect again. The status should say "not connected — computer audio only", then "On"; the other side should hear the music throughout.
> Tell me the answers.

- [ ] **Step 2: OBS (HUMAN)**

Tell the user:
> In OBS: Sources, +, Audio Input Capture, device "Dabber Mic". Play something on the Mac.
> Does the OBS mixer bar for it move? yes/no.

- [ ] **Step 3: Record and commit**

Add a "Final human test" section to `docs/spikes/2026-09-23-feed-hardware-check.md`: call app, what the other side heard, echo yes/no, the AirPods disconnect behaviour, OBS yes/no. Every "no" is a finding to report to the user, with what was running at the time.
```zsh
git add docs/spikes/2026-09-23-feed-hardware-check.md
git commit -m "docs: record virtual mic call and obs test"
```

## After this plan

- Part 3 is done when Task 12 passes. Keep `--play-tone Dabber_2_UID 2 0` as the post-install driver self-test and `--feed --computer-audio --seconds 3` as the feed self-test.
- Out of scope, from the spec: per-source volume in the feed, more than one mic, monitoring the feed, rates other than 48 kHz.
- Not handled here: a feed that starts on its own when a call app opens Dabber Mic (`kAudioDevicePropertyDeviceIsRunningSomewhere` on Dabber Mic would allow it, so the AirPods would stay out of call profile when no call runs). Worth a note for later if the manual on/off turns out to be forgotten.
