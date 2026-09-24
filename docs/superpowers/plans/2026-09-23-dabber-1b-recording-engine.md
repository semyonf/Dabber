# Dabber 1b: Recording Engine and Menu Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Dabber records computer audio and any number of input devices into per-source 48 kHz CAF segments through a lock-free ring buffer, survives device format changes and disconnects by restarting the affected source alone (Spike 1 trigger set), finalizes every session into `mix.m4a` + one `.m4a` per source + `session.json`, recovers unfinished sessions on launch, and exposes all of it through a menu bar window and a headless `--record` command.

**Architecture:** `DabberCore` gains the engine: `RingBuffer` (SPSC, `Synchronization.Atomic`) fed by the HAL IOProc; `TrackWriter` (serial queue, 50 ms drain, `AVAudioConverter` to 48 kHz float32, `ExtAudioFile` CAF per segment); `CaptureSource` base with `InputDeviceSource` / `ComputerAudioSource` subclasses owning restart (debounced, cancellable); `SessionRecorder` (state machine, manifest, disk check, sleep/wake, silence rule); `Finalizer` (chunked timeline read, gap padding, drift resample, mix, AAC, verify, delete CAFs). `Dabber` gets `RecorderModel` (`@MainActor @Observable`) under a thin SwiftUI `MenuBarExtra` window and `--record`. Pure logic is separated from Core Audio so it is tested with synthetic buffers and temp dirs.

**Tech Stack:** Swift 6.4 (Command Line Tools, SDK `MacOSX27.0.sdk`), SwiftPM, Swift Testing, `Synchronization` (Atomic), CoreAudio (process taps, HAL IOProc, property listeners), AudioToolbox (ExtAudioFile), AVFAudio (AVAudioConverter, AVAudioFile), SwiftUI MenuBarExtra, Observation, ffmpeg/ffprobe for checks.

Spec: `docs/superpowers/specs/2026-09-23-dabber-part1-design.md`. Plan 1a: `docs/superpowers/plans/2026-09-23-dabber-1a-foundation-and-spikes.md`. Spikes: `docs/spikes/2026-09-23-spike0-tap-permission.md`, `docs/spikes/2026-09-23-spike1-airpods-switch.md`.

## Ground rules for implementers

- Repo root: the repository root. Branch `part1a` (continue on it). No remote. Never push.
- Commit messages: one line, `type: description`, no body, no trailers. `git add` by explicit path.
- Tests: `scripts/test.sh` only (bare `swift test` cannot find the Swift Testing macro plugin). Success is exit code 0. Shell is zsh.
- Hardware checks: `scripts/build-app.sh` then `scripts/run-headless.sh <log> <args>`; the log's last line must end in ` EXIT 0`.
- Code: English, no comments unless the code cannot say it. KISS, YAGNI. Part 2 items (per-app filter, volume/pan/mute, format choice, hotkey, launch at login, output folder choice) are out of scope.
- Swift 6 language mode. Core Audio callbacks run off the main actor. Classes crossing into IOProc, listener or queue blocks are `final class ...: @unchecked Sendable` (or `class` for the one base class) and protect mutable state with one serial queue or one lock, named in the file.
- Realtime rule: `RingBuffer.push` is the only code that runs on the IO thread. It does memcpy and atomics, nothing else.
- API spellings marked **verified** were compiled and run in a scratch dir on this machine on 2026-09-23 (`swiftc -swift-version 6 -target arm64-apple-macos26.0`, and a scratch `swift build` for SwiftUI). Facts learned there and relied on below:
  - `Synchronization.Atomic<Int>` with `load/store/wrappingAdd(_:ordering:)` compiles and runs.
  - `@State` is a macro on this SDK and the `SwiftUIMacros` plugin is not in the CLT toolchain: **never use `@State`/`@Bindable`**. `@Observable` (Observation macros) works. Hold the model as a `let` on the `App` struct and build bindings with `Binding(get:set:)`.
  - `AVAudioConverter.convert(to:error:withInputFrom:)` keeps 32 frames of latency; feeding `.endOfStream` flushes them. 2400 frames at 24 kHz produced 4768 + 32 = 4800 frames at 48 kHz.
  - `AVAudioConverter` 2 ch -> 1 ch keeps only the left channel unless `converter.downmix = true`, which averages (`AVAudioConverter.h` line 215).
  - `ExtAudioFileRead` after `ExtAudioFileSeek` returned 0 frames in the scratch; `AVAudioFile(forReading:commonFormat:interleaved:)` + `framePosition` + `read(into:frameCount:)` works, so CAFs are read with `AVAudioFile`.
  - `AVAudioFile.length` of an AAC `.m4a` equals the frames written exactly (145,234 == 145,234); `ffprobe` duration includes AAC priming (3.072 s for 3.026 s of audio). Verify duration with `AVAudioFile.length`.
  - Host time ticks at 24,000,000 per second on this machine; convert with `AudioConvertHostTimeToNanos` / `AudioConvertNanosToHostTime` (`HostTime.h` lines 81, 91).
  - Selectors (`AudioHardwareBase.h`, `AudioHardware.h`): `kAudioDevicePropertyNominalSampleRate` 'nsrt', `kAudioDevicePropertyDeviceHasChanged` 'diff', `kAudioDevicePropertyDeviceIsAlive` 'livn', `kAudioDevicePropertyIOStoppedAbnormally` 'stpd', `kAudioStreamPropertyVirtualFormat` 'sfmt', `kAudioHardwarePropertyDevices` 'dev#', `kAudioHardwarePropertyServiceRestarted` 'srst', `kAudioTapPropertyFormat` 'tfmt'.
  - `NSWorkspace.willSleepNotification` / `didWakeNotification` (`NSWorkspace.h` lines 322-323). `URL.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])` works. `NSWorkspace.shared.activateFileViewerSelecting([URL])` compiles.
- Anything not marked verified was written from the SDK headers, not compiled. If a name does not compile, fix the spelling from the header named next to it; do not change behaviour.
- Tasks marked **HUMAN** need the user. Stop there and tell the user exactly what to do, in short steps.
- Spike code: `Sources/DabberCore/Spike/CAFRecorder.swift` and the `--spike-tap` / `--spike-mic` commands are removed in Task 13, after `--record` replaces them as the hardware diagnostic. Until then they stay untouched.

## File structure

```
Sources/DabberCore/CoreAudio/Property.swift          (modify) getArray trims to the second size
Sources/DabberCore/CoreAudio/Devices.swift           (modify) inputDevices skips a device that fails mid-read; collectInputDevices(ids:describe:); defaultInputDeviceUID() (Task 12)
Sources/DabberCore/CoreAudio/IOProcRunner.swift      (modify) IOProc block runs directly on the HAL IO thread (nil queue)
Sources/DabberCore/CoreAudio/PropertyWatcher.swift   (new) per-selector listener blocks on an own queue, remove()
Sources/DabberCore/CoreAudio/HostClock.swift         (new) nowNanos(), nanos(hostTime:)
Sources/DabberCore/Engine/RingBuffer.swift           (new) SlotHeader, SPSC slot ring, overrun count
Sources/DabberCore/Engine/SegmentTracker.swift       (new) per-slot boundary classification (mismatch / sample-time jump)
Sources/DabberCore/Engine/RestartPolicy.swift        (new) WatchedObject, selector sets, shouldRestart
Sources/DabberCore/Engine/TrackWriter.swift          (new) drain ring, convert, write CAF segments, LevelMeter
Sources/DabberCore/Engine/CaptureSource.swift        (new) base class: ring+writer+watchers, CaptureHooks seam, debounced restart, status
Sources/DabberCore/Engine/InputDeviceSource.swift    (new) mic by UID, re-find on dev#
Sources/DabberCore/Engine/ComputerAudioSource.swift  (new) GlobalTap + aggregate, tap format watch
Sources/DabberCore/Engine/SessionRecorder.swift      (new) state machine, sources, manifest writes, disk check, sleep/wake, silence rule
Sources/DabberCore/Engine/SleepWatcher.swift         (new) NSWorkspace sleep/wake -> callbacks
Sources/DabberCore/Model/SessionManifest.swift       (new) session.json Codable types, load/save
Sources/DabberCore/Model/SessionNaming.swift         (new) folder, track and segment file names
Sources/DabberCore/Model/DiskCheck.swift             (new) fixed 2 GB minimum, free bytes
Sources/DabberCore/Model/SessionState.swift          (new) idle/recording/stopping transitions
Sources/DabberCore/Model/SilenceRule.swift           (new) mic < -60 dBFS for 10 s while computer audio has signal
Sources/DabberCore/Model/Segment.swift               (modify) Gap, Timeline.gaps(placements)
Sources/DabberCore/Finalize/SegmentSource.swift      (new) protocol, MemorySegment, DriftResampler
Sources/DabberCore/Finalize/TimelineReader.swift     (new) chunked read of placed segments with zero gaps
Sources/DabberCore/Finalize/FinalizePlan.swift       (new) per-segment frames from file length, resample decision
Sources/DabberCore/Finalize/CAFSegment.swift         (new) SegmentSource over AVAudioFile
Sources/DabberCore/Finalize/AACWriter.swift          (new) AVAudioFile AAC writer, close, verified length
Sources/DabberCore/Finalize/Finalizer.swift          (new) one-pass render + mix, report, delete CAFs, recoverAll
Sources/DabberCore/App/AppPaths.swift                (new) recordings root, app version
Sources/DabberCore/App/RecorderModel.swift           (new) @MainActor @Observable model; RecordingEngine, DeviceCatalog protocols
Sources/Dabber/MenuApp.swift                         (modify) MenuBarExtra window: sources, meters, Start/Stop, elapsed, warning, Show in Finder, Quit
Sources/Dabber/AppDelegate.swift                     (new) shared model, tick timer, device list refresh, quit-while-recording, recovery on launch
Sources/Dabber/Headless.swift                        (modify) --record; spike commands removed in Task 13
Sources/DabberCore/Spike/CAFRecorder.swift           (delete in Task 13)
Tests/DabberCoreTests/TestSupport.swift              (new) slot push helpers, synthetic formats
Tests/DabberCoreTests/DevicesTests.swift             (new)
Tests/DabberCoreTests/RingBufferTests.swift          (new)
Tests/DabberCoreTests/SegmentTrackerTests.swift      (new)
Tests/DabberCoreTests/RestartPolicyTests.swift       (new)
Tests/DabberCoreTests/ManifestTests.swift            (new) manifest, naming, disk check
Tests/DabberCoreTests/SessionStateTests.swift        (new) state machine, silence rule
Tests/DabberCoreTests/TrackWriterTests.swift         (new) synthetic slots -> CAF segments
Tests/DabberCoreTests/CaptureSourceTests.swift       (new) restart logic over fake hooks
Tests/DabberCoreTests/SessionRecorderTests.swift     (new) recorder over fake sources
Tests/DabberCoreTests/TimelineReaderTests.swift      (new) reader, resampler, gaps, plan
Tests/DabberCoreTests/FinalizerTests.swift           (new) temp-dir sessions, recovery
Tests/DabberCoreTests/RecorderModelTests.swift       (new) model over a fake engine
```

---

### Task 1: Review fixes from 1a (getArray trim, inputDevices skip)

**Files:**
- Modify: `Sources/DabberCore/CoreAudio/Property.swift`, `Sources/DabberCore/CoreAudio/Devices.swift`
- Create: `Tests/DabberCoreTests/DevicesTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
import Testing
import CoreAudio
@testable import DabberCore

struct Boom: Error {}

@Test func deviceFailingMidReadIsSkipped() {
    let ids: [AudioObjectID] = [1, 2, 3]
    let devices = collectInputDevices(ids: ids) { id in
        if id == 2 { throw Boom() }
        if id == 3 { return nil }
        return InputDevice(id: id, uid: "u\(id)", name: "n\(id)")
    }
    #expect(devices == [InputDevice(id: 1, uid: "u1", name: "n1")])
}
```

- [ ] **Step 2: Run, expect compile failure**

Run: `scripts/test.sh`
Expected: FAIL, `cannot find 'collectInputDevices' in scope`.

- [ ] **Step 3: Change `inputDevices()` in `Devices.swift`**

Replace the `inputDevices` function with:

```swift
public func inputDevices() throws -> [InputDevice] {
    let ids = try getArray(systemObject, address(kAudioHardwarePropertyDevices), filler: AudioObjectID(0))
    return collectInputDevices(ids: ids, describe: describeInputDevice)
}

public func collectInputDevices(
    ids: [AudioObjectID], describe: (AudioObjectID) throws -> InputDevice?
) -> [InputDevice] {
    ids.compactMap { id in (try? describe(id)) ?? nil }
}

func describeInputDevice(_ id: AudioObjectID) throws -> InputDevice? {
    let streams = try getArray(
        id, address(kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeInput), filler: AudioObjectID(0))
    guard !streams.isEmpty else { return nil }
    return InputDevice(
        id: id,
        uid: try getString(id, address(kAudioDevicePropertyDeviceUID)),
        name: try getString(id, address(kAudioObjectPropertyName)))
}
```

- [ ] **Step 4: Trim in `getArray` (`Property.swift`)**

Replace the body of `getArray` with:

```swift
    var a = addr
    var size: UInt32 = 0
    try check(AudioObjectGetPropertyDataSize(object, &a, 0, nil, &size), "size \(fourCC(addr.mSelector))")
    var values = [T](repeating: filler, count: Int(size) / MemoryLayout<T>.stride)
    try check(AudioObjectGetPropertyData(object, &a, 0, nil, &size, &values), "get \(fourCC(addr.mSelector))")
    values.removeSubrange((Int(size) / MemoryLayout<T>.stride)...)
    return values
```

- [ ] **Step 5: Run tests**

Run: `scripts/test.sh`
Expected: exit 0, all pass (the trim has no unit test; the existing hardware tests `inputDevicesHaveUIDs` and `deviceUIDRoundTrips` exercise it).

- [ ] **Step 6: Commit**

```bash
git add Sources/DabberCore/CoreAudio/Property.swift Sources/DabberCore/CoreAudio/Devices.swift Tests/DabberCoreTests/DevicesTests.swift
git commit -m "fix: skip input devices that fail mid-read and trim property arrays"
```

---

### Task 2: Ring buffer (pure, Atomic)

**Files:**
- Create: `Sources/DabberCore/Engine/RingBuffer.swift`, `Tests/DabberCoreTests/TestSupport.swift`, `Tests/DabberCoreTests/RingBufferTests.swift`

Design: fixed slots, one IOProc callback per slot, header (host time, sample time, buffer count, bytes per buffer) beside the bytes. Producer drops the callback and counts an overrun when the ring is full, the buffer list is larger than a slot, or its buffers differ in size. `head`/`tail` grow monotonically (Int, never wrap in practice). **verified** in scratch, including the deinit-free run.

- [ ] **Step 1: Write `Tests/DabberCoreTests/TestSupport.swift`**

```swift
import CoreAudio
@testable import DabberCore

func pushSlot(_ ring: RingBuffer, bytes: [UInt8], sampleTime: Double, hostNanos: UInt64) {
    var b = bytes
    b.withUnsafeMutableBytes { raw in
        var list = AudioBufferList(
            mNumberBuffers: 1,
            mBuffers: AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(raw.count), mData: raw.baseAddress))
        var ts = AudioTimeStamp()
        ts.mSampleTime = sampleTime
        ts.mHostTime = AudioConvertNanosToHostTime(hostNanos)
        ts.mFlags = [.sampleTimeValid, .hostTimeValid]
        withUnsafePointer(to: &list) { l in withUnsafePointer(to: &ts) { t in ring.push(l, t) } }
    }
}

func pushSlot(_ ring: RingBuffer, samples: [Int16], sampleTime: Double, hostNanos: UInt64) {
    var bytes = [UInt8](repeating: 0, count: samples.count * 2)
    bytes.withUnsafeMutableBytes { raw in
        samples.withUnsafeBytes { raw.copyMemory(from: $0) }
    }
    pushSlot(ring, bytes: bytes, sampleTime: sampleTime, hostNanos: hostNanos)
}

func int16Mono(rate: Double) -> AudioStreamBasicDescription {
    AudioStreamBasicDescription(
        mSampleRate: rate, mFormatID: kAudioFormatLinearPCM,
        mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
        mBytesPerPacket: 2, mFramesPerPacket: 1, mBytesPerFrame: 2, mChannelsPerFrame: 1, mBitsPerChannel: 16,
        mReserved: 0)
}

func tone(frames: Int, rate: Double, hz: Double = 440, amplitude: Double = 16_000) -> [Int16] {
    (0..<frames).map { Int16(sin(Double($0) / rate * 2 * .pi * hz) * amplitude) }
}
```

- [ ] **Step 2: Write the failing tests `Tests/DabberCoreTests/RingBufferTests.swift`**

```swift
import Testing
@testable import DabberCore

@Test func pushedBytesComeBackInOrder() {
    let ring = RingBuffer(slotCount: 4, slotBytes: 16)
    pushSlot(ring, bytes: [1, 2, 3], sampleTime: 0, hostNanos: 10)
    pushSlot(ring, bytes: [4, 5], sampleTime: 3, hostNanos: 20)
    var seen: [(SlotHeader, [UInt8])] = []
    while ring.pop({ h, p in seen.append((h, Array(UnsafeRawBufferPointer(start: p, count: h.bytesPerBuffer)))) }) {}
    #expect(seen.map(\.1) == [[1, 2, 3], [4, 5]])
    #expect(seen.map(\.0.sampleTime) == [0, 3])
    #expect(seen[0].0.bufferCount == 1)
    #expect(ring.overruns == 0)
}

@Test func fullRingDropsAndCountsOverrun() {
    let ring = RingBuffer(slotCount: 2, slotBytes: 16)
    for i in 0..<3 { pushSlot(ring, bytes: [UInt8(i)], sampleTime: Double(i), hostNanos: 0) }
    #expect(ring.overruns == 1)
    var count = 0
    while ring.pop({ _, _ in count += 1 }) {}
    #expect(count == 2)
}

@Test func oversizedBufferIsDropped() {
    let ring = RingBuffer(slotCount: 2, slotBytes: 4)
    pushSlot(ring, bytes: [1, 2, 3, 4, 5], sampleTime: 0, hostNanos: 0)
    #expect(ring.overruns == 1)
    #expect(ring.pop({ _, _ in }) == false)
}

@Test func popOnEmptyRingReturnsFalse() {
    #expect(RingBuffer(slotCount: 1, slotBytes: 1).pop({ _, _ in }) == false)
}

@Test func slotsAreReusedAfterPop() {
    let ring = RingBuffer(slotCount: 2, slotBytes: 8)
    for i in 0..<10 {
        pushSlot(ring, bytes: [UInt8(i)], sampleTime: Double(i), hostNanos: 0)
        var got: UInt8 = 255
        #expect(ring.pop({ _, p in got = p.load(as: UInt8.self) }))
        #expect(got == UInt8(i))
    }
    #expect(ring.overruns == 0)
}
```

- [ ] **Step 3: Run, expect compile failure**

Run: `scripts/test.sh`
Expected: FAIL, `cannot find 'RingBuffer' in scope`.

- [ ] **Step 4: Write `Sources/DabberCore/Engine/RingBuffer.swift`**

```swift
import CoreAudio
import Synchronization

public struct SlotHeader: Sendable, Equatable {
    public var hostTime: UInt64
    public var sampleTime: Double
    public var bufferCount: Int
    public var bytesPerBuffer: Int

    public init(hostTime: UInt64, sampleTime: Double, bufferCount: Int, bytesPerBuffer: Int) {
        self.hostTime = hostTime
        self.sampleTime = sampleTime
        self.bufferCount = bufferCount
        self.bytesPerBuffer = bytesPerBuffer
    }
}

public final class RingBuffer: @unchecked Sendable {
    public let slotCount: Int
    public let slotBytes: Int
    private let data: UnsafeMutableRawPointer
    private let headers: UnsafeMutablePointer<SlotHeader>
    private let head = Atomic<Int>(0)
    private let tail = Atomic<Int>(0)
    private let dropped = Atomic<Int>(0)

    public init(slotCount: Int, slotBytes: Int) {
        self.slotCount = slotCount
        self.slotBytes = slotBytes
        data = .allocate(byteCount: slotCount * slotBytes, alignment: 16)
        headers = .allocate(capacity: slotCount)
        headers.initialize(
            repeating: SlotHeader(hostTime: 0, sampleTime: 0, bufferCount: 0, bytesPerBuffer: 0), count: slotCount)
    }

    deinit {
        data.deallocate()
        headers.deallocate()
    }

    public var overruns: Int { dropped.load(ordering: .relaxed) }

    public func push(_ list: UnsafePointer<AudioBufferList>, _ time: UnsafePointer<AudioTimeStamp>) {
        let h = head.load(ordering: .relaxed)
        let t = tail.load(ordering: .acquiring)
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: list))
        let count = buffers.count
        let bytes = count > 0 ? Int(buffers[0].mDataByteSize) : 0
        guard h - t < slotCount, bytes > 0, count * bytes <= slotBytes else {
            dropped.wrappingAdd(1, ordering: .relaxed)
            return
        }
        let slot = data + (h % slotCount) * slotBytes
        for i in 0..<count {
            guard let src = buffers[i].mData, Int(buffers[i].mDataByteSize) == bytes else {
                dropped.wrappingAdd(1, ordering: .relaxed)
                return
            }
            (slot + i * bytes).copyMemory(from: src, byteCount: bytes)
        }
        headers[h % slotCount] = SlotHeader(
            hostTime: time.pointee.mHostTime, sampleTime: time.pointee.mSampleTime,
            bufferCount: count, bytesPerBuffer: bytes)
        head.store(h + 1, ordering: .releasing)
    }

    public func pop(_ body: (SlotHeader, UnsafeRawPointer) -> Void) -> Bool {
        let t = tail.load(ordering: .relaxed)
        let h = head.load(ordering: .acquiring)
        guard t < h else { return false }
        body(headers[t % slotCount], UnsafeRawPointer(data + (t % slotCount) * slotBytes))
        tail.store(t + 1, ordering: .releasing)
        return true
    }
}
```

- [ ] **Step 5: Run tests**

Run: `scripts/test.sh`
Expected: exit 0.

- [ ] **Step 6: Commit**

```bash
git add Sources/DabberCore/Engine/RingBuffer.swift Tests/DabberCoreTests/TestSupport.swift Tests/DabberCoreTests/RingBufferTests.swift
git commit -m "feat: add lock-free slot ring buffer for ioproc handoff"
```

---

### Task 3: Segment tracker and restart policy (pure)

**Files:**
- Create: `Sources/DabberCore/Engine/SegmentTracker.swift`, `Sources/DabberCore/Engine/RestartPolicy.swift`, `Tests/DabberCoreTests/SegmentTrackerTests.swift`, `Tests/DabberCoreTests/RestartPolicyTests.swift`

- [ ] **Step 1: Write the failing tests**

`Tests/DabberCoreTests/SegmentTrackerTests.swift`:

```swift
import Testing
@testable import DabberCore

private func header(_ sampleTime: Double, bytes: Int, buffers: Int = 1) -> SlotHeader {
    SlotHeader(hostTime: 0, sampleTime: sampleTime, bufferCount: buffers, bytesPerBuffer: bytes)
}

@Test func contiguousSlotsContinue() {
    var t = SegmentTracker(bytesPerFrame: 2, bufferCount: 1)
    #expect(t.classify(header(0, bytes: 960)) == .continues)
    #expect(t.classify(header(480, bytes: 960)) == .continues)
    #expect(t.classify(header(960.5, bytes: 960)) == .continues)
}

@Test func sampleTimeJumpIsAGap() {
    var t = SegmentTracker(bytesPerFrame: 2, bufferCount: 1)
    _ = t.classify(header(0, bytes: 960))
    #expect(t.classify(header(1000, bytes: 960)) == .gap(frames: 520))
    #expect(t.classify(header(1480, bytes: 960)) == .continues)
}

@Test func byteSizeNotDivisibleByFrameIsAMismatch() {
    var t = SegmentTracker(bytesPerFrame: 4, bufferCount: 1)
    #expect(t.classify(header(0, bytes: 6)) == .formatMismatch)
}

@Test func bufferCountChangeIsAMismatch() {
    var t = SegmentTracker(bytesPerFrame: 4, bufferCount: 2)
    #expect(t.classify(header(0, bytes: 8, buffers: 1)) == .formatMismatch)
}

@Test func framesAreDerivedFromBytes() {
    let t = SegmentTracker(bytesPerFrame: 8, bufferCount: 1)
    #expect(t.frames(in: header(0, bytes: 4096)) == 512)
}
```

`Tests/DabberCoreTests/RestartPolicyTests.swift`:

```swift
import Testing
import CoreAudio
@testable import DabberCore

@Test func spikeOneTriggersRestart() {
    #expect(RestartPolicy.shouldRestart(kAudioDevicePropertyNominalSampleRate, on: .device))
    #expect(RestartPolicy.shouldRestart(kAudioDevicePropertyDeviceHasChanged, on: .device))
    #expect(RestartPolicy.shouldRestart(kAudioDevicePropertyDeviceIsAlive, on: .device))
    #expect(RestartPolicy.shouldRestart(kAudioDevicePropertyIOStoppedAbnormally, on: .device))
    #expect(RestartPolicy.shouldRestart(kAudioStreamPropertyVirtualFormat, on: .inputStream))
    #expect(RestartPolicy.shouldRestart(kAudioHardwarePropertyServiceRestarted, on: .system))
    #expect(RestartPolicy.shouldRestart(kAudioTapPropertyFormat, on: .tap))
}

@Test func spikeOneNoiseDoesNotRestart() {
    for s in ["cfgb", "cfge", "stm#", "goin", "gone", "went", "mute"] {
        let sel = s.utf8.reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        #expect(!RestartPolicy.shouldRestart(sel, on: .device), "\(s)")
    }
    #expect(!RestartPolicy.shouldRestart(kAudioStreamPropertyVirtualFormat, on: .device))
    #expect(!RestartPolicy.shouldRestart(kAudioHardwarePropertyDevices, on: .system))
}

@Test func watchedSelectorsCoverTheTriggerSet() {
    #expect(RestartPolicy.selectors(for: .system) == [kAudioHardwarePropertyServiceRestarted, kAudioHardwarePropertyDevices])
    #expect(RestartPolicy.selectors(for: .inputStream) == [kAudioStreamPropertyVirtualFormat])
}
```

- [ ] **Step 2: Run, expect compile failure**

Run: `scripts/test.sh`
Expected: FAIL, `cannot find 'SegmentTracker' in scope`.

- [ ] **Step 3: Write `Sources/DabberCore/Engine/SegmentTracker.swift`** (**verified**)

```swift
public enum Boundary: Equatable, Sendable {
    case continues
    case gap(frames: Double)
    case formatMismatch
}

public struct SegmentTracker: Sendable {
    public let bytesPerFrame: Int
    public let bufferCount: Int
    private var nextSampleTime: Double?

    public init(bytesPerFrame: Int, bufferCount: Int) {
        self.bytesPerFrame = bytesPerFrame
        self.bufferCount = bufferCount
    }

    public func frames(in header: SlotHeader) -> Int { header.bytesPerBuffer / bytesPerFrame }

    public mutating func classify(_ header: SlotHeader) -> Boundary {
        guard header.bufferCount == bufferCount, header.bytesPerBuffer > 0,
              header.bytesPerBuffer % bytesPerFrame == 0
        else { return .formatMismatch }
        let expected = nextSampleTime
        nextSampleTime = header.sampleTime + Double(frames(in: header))
        guard let expected else { return .continues }
        let jump = header.sampleTime - expected
        return abs(jump) <= 1 ? .continues : .gap(frames: jump)
    }
}
```

- [ ] **Step 4: Write `Sources/DabberCore/Engine/RestartPolicy.swift`**

`dev#` is watched on the system object but is not a restart trigger by itself: `InputDeviceSource` handles it by re-resolving the UID (Task 6).

```swift
import CoreAudio

public enum WatchedObject: Sendable, Equatable {
    case device
    case inputStream
    case tap
    case system
}

public enum RestartPolicy {
    public static func selectors(for object: WatchedObject) -> [AudioObjectPropertySelector] {
        switch object {
        case .device:
            return [
                kAudioDevicePropertyNominalSampleRate, kAudioDevicePropertyDeviceHasChanged,
                kAudioDevicePropertyDeviceIsAlive, kAudioDevicePropertyIOStoppedAbnormally,
            ]
        case .inputStream: return [kAudioStreamPropertyVirtualFormat]
        case .tap: return [kAudioTapPropertyFormat]
        case .system: return [kAudioHardwarePropertyServiceRestarted, kAudioHardwarePropertyDevices]
        }
    }

    public static func shouldRestart(_ selector: AudioObjectPropertySelector, on object: WatchedObject) -> Bool {
        selector != kAudioHardwarePropertyDevices && selectors(for: object).contains(selector)
    }
}
```

- [ ] **Step 5: Run tests**

Run: `scripts/test.sh`
Expected: exit 0.

- [ ] **Step 6: Commit**

```bash
git add Sources/DabberCore/Engine/SegmentTracker.swift Sources/DabberCore/Engine/RestartPolicy.swift Tests/DabberCoreTests/SegmentTrackerTests.swift Tests/DabberCoreTests/RestartPolicyTests.swift
git commit -m "feat: add segment boundary tracker and spike 1 restart policy"
```

---

### Task 4: Manifest, naming, disk check, state machine, silence rule (pure)

**Files:**
- Create: `Sources/DabberCore/Model/SessionManifest.swift`, `Sources/DabberCore/Model/SessionNaming.swift`, `Sources/DabberCore/Model/DiskCheck.swift`, `Sources/DabberCore/Model/SessionState.swift`, `Sources/DabberCore/Model/SilenceRule.swift`, `Sources/DabberCore/CoreAudio/HostClock.swift`, `Tests/DabberCoreTests/ManifestTests.swift`, `Tests/DabberCoreTests/SessionStateTests.swift`

Disk decision: a fixed minimum of 2 GB free before start. Duration is unknown at start, so "per expected hour" cannot be computed; 2 GB is one hour of one float32 mono track (691 MB) plus one stereo track (1.38 GB), the common case. A write error during recording stops cleanly anyway (Task 7), so the pre-check only avoids starting a session that cannot last an hour.

- [ ] **Step 1: Write the failing tests**

`Tests/DabberCoreTests/ManifestTests.swift`:

```swift
import Foundation
import Testing
@testable import DabberCore

@Test func manifestRoundTripsThroughJSON() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("m-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    var m = SessionManifest(appVersion: "0.1.0", startedAt: Date(timeIntervalSince1970: 1_000), sessionStartNanos: 42)
    m.sources = [
        SourceManifest(
            kind: .mic, uid: "u", name: "AirPods", file: "mic - AirPods.m4a", channels: 1,
            segments: [SegmentRecord(file: "mic - AirPods.seg000.caf", startNanos: 50, frames: 480, endNanos: 60,
                                     sourceRate: 24_000, sourceChannels: 1, reason: "start")],
            restarts: [RestartEvent(atNanos: 55, reason: "nsrt")], overruns: 2),
    ]
    try m.save(to: dir)
    let text = try String(contentsOf: dir.appendingPathComponent("session.json"), encoding: .utf8)
    #expect(text.contains("\"reason\" : \"nsrt\""))
    #expect(try SessionManifest.load(from: dir) == m)
}

@Test func folderNameIsSortableLocalTime() {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: "Europe/Moscow")!
    let date = cal.date(from: DateComponents(year: 2026, month: 9, day: 23, hour: 5, minute: 53, second: 11))!
    #expect(SessionNaming.folderName(date, timeZone: cal.timeZone) == "2026-09-23 05-53-11")
}

@Test func trackNamesFollowTheSpec() {
    #expect(SessionNaming.trackBase(kind: .computer, name: "x", taken: []) == "computer audio")
    #expect(SessionNaming.trackBase(kind: .mic, name: "Alex’s AirPods", taken: []) == "mic - Alex’s AirPods")
    #expect(SessionNaming.trackBase(kind: .mic, name: "USB: In/Out", taken: []) == "mic - USB- In-Out")
    #expect(SessionNaming.trackBase(kind: .mic, name: "A", taken: ["mic - A"]) == "mic - A 2")
    #expect(SessionNaming.segmentFile(base: "mic - A", index: 7) == "mic - A.seg007.caf")
}

@Test func diskCheckNeedsTwoGigabytes() throws {
    #expect(DiskCheck.hasRoom(freeBytes: 2_000_000_000))
    #expect(!DiskCheck.hasRoom(freeBytes: 1_999_999_999))
    #expect(try DiskCheck.freeBytes(at: URL(fileURLWithPath: NSHomeDirectory())) > 0)
}
```

`Tests/DabberCoreTests/SessionStateTests.swift`:

```swift
import Testing
@testable import DabberCore

@Test func stateMachineFollowsIdleRecordingStopping() {
    var m = SessionState()
    #expect(m.phase == .idle)
    #expect(m.start() == true)
    #expect(m.start() == false)
    #expect(m.phase == .recording)
    #expect(m.stop() == true)
    #expect(m.stop() == false)
    #expect(m.phase == .stopping)
    m.finished()
    #expect(m.phase == .idle)
    #expect(m.stop() == false)
}

@Test func silenceWarningNeedsTenSecondsOfQuietMicWithComputerSignal() {
    var r = SilenceRule()
    #expect(r.update(micDb: -70, computerDb: -20, now: 0) == false)
    #expect(r.update(micDb: -70, computerDb: -20, now: 9.9) == false)
    #expect(r.update(micDb: -70, computerDb: -20, now: 10) == true)
    #expect(r.update(micDb: -30, computerDb: -20, now: 11) == false)
    #expect(r.update(micDb: -70, computerDb: -20, now: 12) == false)
}

@Test func quietComputerAudioResetsTheSilenceWindow() {
    var r = SilenceRule()
    _ = r.update(micDb: -70, computerDb: -20, now: 0)
    #expect(r.update(micDb: -70, computerDb: -80, now: 5) == false)
    #expect(r.update(micDb: -70, computerDb: -20, now: 14) == false)
    #expect(r.update(micDb: -70, computerDb: -20, now: 24) == true)
}
```

- [ ] **Step 2: Run, expect compile failure**

Run: `scripts/test.sh`
Expected: FAIL, `cannot find 'SessionManifest' in scope`.

- [ ] **Step 3: Write `Sources/DabberCore/Model/SessionManifest.swift`**

```swift
import Foundation

public enum SourceKind: String, Codable, Sendable { case mic, computer }

public struct SegmentRecord: Codable, Equatable, Sendable {
    public var file: String
    public var startNanos: UInt64
    public var frames: Int
    public var endNanos: UInt64?
    public var sourceRate: Double
    public var sourceChannels: Int
    public var reason: String

    public init(file: String, startNanos: UInt64, frames: Int, endNanos: UInt64?, sourceRate: Double,
                sourceChannels: Int, reason: String) {
        self.file = file
        self.startNanos = startNanos
        self.frames = frames
        self.endNanos = endNanos
        self.sourceRate = sourceRate
        self.sourceChannels = sourceChannels
        self.reason = reason
    }

    public var segment: Segment { Segment(startNanos: startNanos, frames: frames, endNanos: endNanos) }
}

public struct RestartEvent: Codable, Equatable, Sendable {
    public var atNanos: UInt64
    public var reason: String
    public init(atNanos: UInt64, reason: String) {
        self.atNanos = atNanos
        self.reason = reason
    }
}

public struct SourceManifest: Codable, Equatable, Sendable {
    public var kind: SourceKind
    public var uid: String?
    public var name: String
    public var file: String
    public var channels: Int
    public var segments: [SegmentRecord]
    public var restarts: [RestartEvent]
    public var overruns: Int

    public init(kind: SourceKind, uid: String?, name: String, file: String, channels: Int,
                segments: [SegmentRecord], restarts: [RestartEvent], overruns: Int) {
        self.kind = kind
        self.uid = uid
        self.name = name
        self.file = file
        self.channels = channels
        self.segments = segments
        self.restarts = restarts
        self.overruns = overruns
    }

    public var trackBase: String { String(file.dropLast(4)) }
}

public struct GapRecord: Codable, Equatable, Sendable {
    public var track: String
    public var atFrame: Int
    public var frames: Int
    public init(track: String, atFrame: Int, frames: Int) {
        self.track = track
        self.atFrame = atFrame
        self.frames = frames
    }
}

public struct FinalizeReport: Codable, Equatable, Sendable {
    public var totalFrames: Int
    public var gaps: [GapRecord]
    public var driftMillis: [String: Double]
    public var resampled: [String]
    public init(totalFrames: Int, gaps: [GapRecord], driftMillis: [String: Double], resampled: [String]) {
        self.totalFrames = totalFrames
        self.gaps = gaps
        self.driftMillis = driftMillis
        self.resampled = resampled
    }
}

public struct SessionManifest: Codable, Equatable, Sendable {
    public static let fileName = "session.json"

    public var appVersion: String
    public var startedAt: Date
    public var sessionStartNanos: UInt64
    public var sources: [SourceManifest] = []
    public var finalize: FinalizeReport?

    public init(appVersion: String, startedAt: Date, sessionStartNanos: UInt64) {
        self.appVersion = appVersion
        self.startedAt = startedAt
        self.sessionStartNanos = sessionStartNanos
    }

    public func save(to dir: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(self).write(to: dir.appendingPathComponent(Self.fileName), options: .atomic)
    }

    public static func load(from dir: URL) throws -> SessionManifest {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(SessionManifest.self, from: Data(contentsOf: dir.appendingPathComponent(fileName)))
    }
}
```

- [ ] **Step 4: Write `Sources/DabberCore/Model/SessionNaming.swift`**

```swift
import Foundation

public enum SessionNaming {
    public static func folderName(_ date: Date, timeZone: TimeZone = .current) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = timeZone
        f.dateFormat = "yyyy-MM-dd HH-mm-ss"
        return f.string(from: date)
    }

    public static func trackBase(kind: SourceKind, name: String, taken: [String]) -> String {
        let base: String
        switch kind {
        case .computer: base = "computer audio"
        case .mic: base = "mic - " + String(name.map { "/:\\".contains($0) ? Character("-") : $0 })
        }
        var candidate = base
        var n = 2
        while taken.contains(candidate) {
            candidate = "\(base) \(n)"
            n += 1
        }
        return candidate
    }

    public static func segmentFile(base: String, index: Int) -> String {
        base + ".seg" + String(format: "%03d", index) + ".caf"
    }
}
```

- [ ] **Step 5: Write `Sources/DabberCore/Model/DiskCheck.swift`** (**verified** key)

```swift
import Foundation

public enum DiskCheck {
    public static let minimumFreeBytes: Int64 = 2_000_000_000

    public static func hasRoom(freeBytes: Int64) -> Bool { freeBytes >= minimumFreeBytes }

    public static func freeBytes(at url: URL) throws -> Int64 {
        let values = try url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values.volumeAvailableCapacityForImportantUsage ?? 0
    }
}
```

- [ ] **Step 6: Write `Sources/DabberCore/Model/SessionState.swift`**

```swift
public enum RecorderPhase: String, Sendable, Equatable { case idle, recording, stopping }

public struct SessionState: Sendable, Equatable {
    public private(set) var phase: RecorderPhase = .idle

    public init() {}

    public mutating func start() -> Bool {
        guard phase == .idle else { return false }
        phase = .recording
        return true
    }

    public mutating func stop() -> Bool {
        guard phase == .recording else { return false }
        phase = .stopping
        return true
    }

    public mutating func finished() { phase = .idle }
}
```

- [ ] **Step 7: Write `Sources/DabberCore/Model/SilenceRule.swift`**

```swift
public struct SilenceRule: Sendable, Equatable {
    public static let thresholdDb: Double = -60
    public static let windowSeconds: Double = 10
    private var silentSince: Double?

    public init() {}

    public mutating func update(micDb: Double, computerDb: Double, now: Double) -> Bool {
        guard micDb < Self.thresholdDb, computerDb >= Self.thresholdDb else {
            silentSince = nil
            return false
        }
        let since = silentSince ?? now
        silentSince = since
        return now - since >= Self.windowSeconds
    }
}
```

- [ ] **Step 8: Write `Sources/DabberCore/CoreAudio/HostClock.swift`** (**verified** functions)

```swift
import CoreAudio

public enum HostClock {
    public static func nowNanos() -> UInt64 { AudioConvertHostTimeToNanos(AudioGetCurrentHostTime()) }
    public static func nanos(hostTime: UInt64) -> UInt64 { AudioConvertHostTimeToNanos(hostTime) }
}
```

- [ ] **Step 9: Run tests**

Run: `scripts/test.sh`
Expected: exit 0.

- [ ] **Step 10: Commit**

```bash
git add Sources/DabberCore/Model Sources/DabberCore/CoreAudio/HostClock.swift Tests/DabberCoreTests/ManifestTests.swift Tests/DabberCoreTests/SessionStateTests.swift
git commit -m "feat: add session manifest, naming, disk check, state machine and silence rule"
```

---

### Task 5: TrackWriter (ring -> 48 kHz CAF segments)

**Files:**
- Create: `Sources/DabberCore/Engine/TrackWriter.swift`, `Tests/DabberCoreTests/TrackWriterTests.swift`

Design (**verified** end-to-end in scratch with synthetic Int16 24 kHz slots): a serial queue drains the ring every 50 ms. Each slot is classified by `SegmentTracker`; `.gap` closes the segment and opens the next one with the same format (reason `sample time jump`); `.formatMismatch` closes the segment, drops slots until a new one is opened, and reports through `onFormatMismatch` so the source restarts. Conversion is one `AVAudioConverter` per segment with `downmix = true`, output interleaved float32 at 48 kHz with `channels` channels (1 for mic, 2 for computer audio). `startNanos` is the host time of the first slot; `endNanos` = host time of the last slot + its duration. Callbacks run on `events`, a second serial queue, so a handler may call back into the writer without deadlocking. Segment records passed to `onSegmentsChanged` are a snapshot; the recorder keeps its own copy and never calls `segments` from the callback.

- [ ] **Step 1: Write the failing tests `Tests/DabberCoreTests/TrackWriterTests.swift`**

```swift
import AVFoundation
import Foundation
import Synchronization
import Testing
@testable import DabberCore

private func tempDir() throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tw-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

private func cafLength(_ url: URL) throws -> (frames: Int64, rate: Double, channels: Int) {
    let f = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: true)
    return (f.length, f.processingFormat.sampleRate, Int(f.processingFormat.channelCount))
}

@Test func slotsBecomeOne48kMonoSegment() throws {
    let dir = try tempDir()
    let ring = RingBuffer(slotCount: 64, slotBytes: 4096)
    let w = TrackWriter(dir: dir, baseName: "mic - T", channels: 1, ring: ring)
    try w.openSegment(format: int16Mono(rate: 24_000), reason: "start")
    let t = tone(frames: 480, rate: 24_000)
    for i in 0..<10 {
        pushSlot(ring, samples: t, sampleTime: Double(i * 480), hostNanos: 1_000_000_000 + UInt64(i) * 20_000_000)
    }
    w.stop()
    let s = w.segments
    #expect(s.count == 1)
    #expect(s[0].frames == 9600)
    #expect(s[0].reason == "start")
    #expect(s[0].startNanos == 1_000_000_000)
    #expect(s[0].endNanos == 1_000_000_000 + 200_000_000)
    let info = try cafLength(dir.appendingPathComponent("mic - T.seg000.caf"))
    #expect(info.frames == 9600 && info.rate == 48_000 && info.channels == 1)
    #expect(w.meter.decibels > -20 && w.meter.decibels < 0)
}

@Test func sampleTimeJumpSplitsTheSegment() throws {
    let dir = try tempDir()
    let ring = RingBuffer(slotCount: 64, slotBytes: 4096)
    let w = TrackWriter(dir: dir, baseName: "mic - T", channels: 1, ring: ring)
    try w.openSegment(format: int16Mono(rate: 24_000), reason: "start")
    let t = tone(frames: 480, rate: 24_000)
    pushSlot(ring, samples: t, sampleTime: 0, hostNanos: 1_000_000_000)
    pushSlot(ring, samples: t, sampleTime: 480, hostNanos: 1_020_000_000)
    pushSlot(ring, samples: t, sampleTime: 100_000, hostNanos: 5_000_000_000)
    w.stop()
    let s = w.segments
    #expect(s.map(\.frames) == [1920, 960])
    #expect(s.map(\.reason) == ["start", "sample time jump"])
    #expect(s[1].startNanos == 5_000_000_000)
    #expect(s.map(\.file) == ["mic - T.seg000.caf", "mic - T.seg001.caf"])
}

@Test func formatMismatchClosesSegmentAndReports() throws {
    let dir = try tempDir()
    let ring = RingBuffer(slotCount: 64, slotBytes: 4096)
    let w = TrackWriter(dir: dir, baseName: "mic - T", channels: 1, ring: ring)
    let reported = Atomic<Int>(0)
    w.onFormatMismatch = { reported.wrappingAdd(1, ordering: .relaxed) }
    try w.openSegment(format: int16Mono(rate: 24_000), reason: "start")
    pushSlot(ring, samples: tone(frames: 480, rate: 24_000), sampleTime: 0, hostNanos: 1_000_000_000)
    pushSlot(ring, bytes: [1, 2, 3], sampleTime: 480, hostNanos: 1_020_000_000)
    pushSlot(ring, samples: tone(frames: 480, rate: 24_000), sampleTime: 483, hostNanos: 1_040_000_000)
    w.closeSegment()
    Thread.sleep(forTimeInterval: 0.1)
    #expect(reported.load(ordering: .relaxed) == 1)
    #expect(w.segments.map(\.frames) == [960])
    try w.openSegment(format: int16Mono(rate: 48_000), reason: "restart: test")
    pushSlot(ring, samples: tone(frames: 480, rate: 48_000), sampleTime: 0, hostNanos: 2_000_000_000)
    w.stop()
    #expect(w.segments.map(\.frames) == [960, 480])
    #expect(w.segments[1].sourceRate == 48_000)
}

@Test func stereoSourceIsAveragedIntoMonoTrack() throws {
    let dir = try tempDir()
    let ring = RingBuffer(slotCount: 8, slotBytes: 4096)
    let w = TrackWriter(dir: dir, baseName: "mic - S", channels: 1, ring: ring)
    let f = AudioStreamBasicDescription(
        mSampleRate: 48_000, mFormatID: kAudioFormatLinearPCM,
        mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
        mBytesPerPacket: 8, mFramesPerPacket: 1, mBytesPerFrame: 8, mChannelsPerFrame: 2, mBitsPerChannel: 32,
        mReserved: 0)
    try w.openSegment(format: f, reason: "start")
    var bytes = [UInt8](repeating: 0, count: 8 * 100)
    let samples = [Float](repeating: 0, count: 200).enumerated().map { $0.offset % 2 == 0 ? Float(0.5) : Float(-0.25) }
    bytes.withUnsafeMutableBytes { raw in samples.withUnsafeBytes { raw.copyMemory(from: $0) } }
    pushSlot(ring, bytes: bytes, sampleTime: 0, hostNanos: 1_000_000_000)
    w.stop()
    let file = try AVAudioFile(forReading: dir.appendingPathComponent("mic - S.seg000.caf"), commonFormat: .pcmFormatFloat32, interleaved: true)
    let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 100)!
    try file.read(into: buf)
    #expect(buf.frameLength == 100)
    #expect(abs(buf.floatChannelData![0][50] - 0.125) < 0.001)
}
```

- [ ] **Step 2: Run, expect compile failure**

Run: `scripts/test.sh`
Expected: FAIL, `cannot find 'TrackWriter' in scope`.

- [ ] **Step 3: Write `Sources/DabberCore/Engine/TrackWriter.swift`**

```swift
import AVFoundation
import AudioToolbox
import CoreAudio
import Foundation

public final class LevelMeter: @unchecked Sendable {
    private let lock = NSLock()
    private var db: Double = -160

    public var decibels: Double {
        lock.lock(); defer { lock.unlock() }
        return db
    }

    func update(_ samples: UnsafePointer<Float>, count: Int) {
        guard count > 0 else { return }
        var sum: Float = 0
        for i in 0..<count { sum += samples[i] * samples[i] }
        let rms = (sum / Float(count)).squareRoot()
        lock.lock(); defer { lock.unlock() }
        db = rms > 0 ? Double(20 * log10(rms)) : -160
    }
}

public struct WriteFailure: Error, CustomStringConvertible {
    public let status: OSStatus
    public var description: String { "caf write failed: \(fourCC(status))" }
}

public final class TrackWriter: @unchecked Sendable {
    public let baseName: String
    public let channels: Int
    public let meter = LevelMeter()
    public var onFormatMismatch: (@Sendable () -> Void)?
    public var onWriteError: (@Sendable (Error) -> Void)?
    public var onSegmentsChanged: (@Sendable ([SegmentRecord]) -> Void)?

    private let ring: RingBuffer
    private let dir: URL
    private let queue = DispatchQueue(label: "dabber.writer")
    private let events = DispatchQueue(label: "dabber.writer.events")
    private var timer: DispatchSourceTimer?
    private var current: OpenSegment?
    private var records: [SegmentRecord] = []

    private struct OpenSegment {
        var record: SegmentRecord
        let file: ExtAudioFileRef
        let converter: AVAudioConverter
        let input: AVAudioPCMBuffer
        let output: AVAudioPCMBuffer
        var tracker: SegmentTracker
        var lastHeader: SlotHeader?
    }

    public init(dir: URL, baseName: String, channels: Int, ring: RingBuffer) {
        self.dir = dir
        self.baseName = baseName
        self.channels = channels
        self.ring = ring
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(50))
        timer.setEventHandler { [weak self] in self?.drain() }
        timer.resume()
        self.timer = timer
    }

    public var segments: [SegmentRecord] { queue.sync { allRecords() } }

    public func openSegment(format: AudioStreamBasicDescription, reason: String) throws {
        try queue.sync {
            finishCurrent()
            try open(format: format, reason: reason)
        }
    }

    public func closeSegment() {
        queue.sync {
            drain()
            finishCurrent()
        }
    }

    public func stop() {
        closeSegment()
        timer?.cancel()
        timer = nil
    }

    private func allRecords() -> [SegmentRecord] { records + (current.map { [$0.record] } ?? []) }

    private func notifySegments() {
        let snapshot = allRecords()
        events.async { [self] in onSegmentsChanged?(snapshot) }
    }

    private func open(format: AudioStreamBasicDescription, reason: String) throws {
        var asbd = format
        guard let sourceFormat = AVAudioFormat(streamDescription: &asbd),
              let targetFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: AVAudioChannelCount(channels),
                interleaved: true),
              let converter = AVAudioConverter(from: sourceFormat, to: targetFormat)
        else {
            throw CAError(status: kAudioFormatUnsupportedDataFormatError,
                          op: "converter for \(format.mSampleRate) Hz \(format.mChannelsPerFrame) ch")
        }
        converter.downmix = true
        let bufferCount = sourceFormat.isInterleaved ? 1 : Int(format.mChannelsPerFrame)
        let slotFrames = ring.slotBytes / Int(format.mBytesPerFrame) / bufferCount
        guard let input = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: AVAudioFrameCount(slotFrames)),
              let output = AVAudioPCMBuffer(
                pcmFormat: targetFormat,
                frameCapacity: AVAudioFrameCount(Double(slotFrames) * 48_000 / format.mSampleRate) + 64)
        else { throw CAError(status: kAudio_MemFullError, op: "pcm buffers") }
        let file = SessionNaming.segmentFile(base: baseName, index: records.count)
        var fileFormat = targetFormat.streamDescription.pointee
        var ref: ExtAudioFileRef?
        try check(
            ExtAudioFileCreateWithURL(
                dir.appendingPathComponent(file) as CFURL, kAudioFileCAFType, &fileFormat, nil,
                AudioFileFlags.eraseFile.rawValue, &ref),
            "create caf")
        var client = fileFormat
        try check(
            ExtAudioFileSetProperty(
                ref!, kExtAudioFileProperty_ClientDataFormat,
                UInt32(MemoryLayout<AudioStreamBasicDescription>.size), &client),
            "set client format")
        current = OpenSegment(
            record: SegmentRecord(
                file: file, startNanos: 0, frames: 0, endNanos: nil, sourceRate: format.mSampleRate,
                sourceChannels: Int(format.mChannelsPerFrame), reason: reason),
            file: ref!, converter: converter, input: input, output: output,
            tracker: SegmentTracker(bytesPerFrame: Int(format.mBytesPerFrame), bufferCount: bufferCount),
            lastHeader: nil)
        notifySegments()
    }

    private func drain() {
        while ring.pop({ header, bytes in handle(header, bytes) }) {}
    }

    private func handle(_ header: SlotHeader, _ bytes: UnsafeRawPointer) {
        guard current != nil else { return }
        switch current!.tracker.classify(header) {
        case .formatMismatch:
            finishCurrent()
            events.async { [self] in onFormatMismatch?() }
            return
        case .gap:
            let format = current!.input.format.streamDescription.pointee
            finishCurrent()
            do {
                try open(format: format, reason: "sample time jump")
            } catch {
                events.async { [self] in onWriteError?(error) }
                return
            }
            _ = current!.tracker.classify(header)
        case .continues:
            break
        }
        write(header, bytes)
    }

    private func write(_ header: SlotHeader, _ bytes: UnsafeRawPointer) {
        guard var seg = current else { return }
        if seg.lastHeader == nil { seg.record.startNanos = HostClock.nanos(hostTime: header.hostTime) }
        seg.lastHeader = header
        let list = UnsafeMutableAudioBufferListPointer(seg.input.mutableAudioBufferList)
        for i in 0..<header.bufferCount {
            list[i].mData!.copyMemory(from: bytes + i * header.bytesPerBuffer, byteCount: header.bytesPerBuffer)
            list[i].mDataByteSize = UInt32(header.bytesPerBuffer)
        }
        seg.input.frameLength = AVAudioFrameCount(seg.tracker.frames(in: header))
        current = seg
        convert(endOfStream: false)
    }

    private func convert(endOfStream: Bool) {
        guard var seg = current else { return }
        var fed = false
        var error: NSError?
        seg.output.frameLength = 0
        let input = seg.input
        seg.converter.convert(to: seg.output, error: &error) { _, status in
            if endOfStream { status.pointee = .endOfStream; return nil }
            if fed { status.pointee = .noDataNow; return nil }
            fed = true
            status.pointee = .haveData
            return input
        }
        let produced = seg.output.frameLength
        if produced > 0 {
            let status = ExtAudioFileWrite(seg.file, produced, seg.output.audioBufferList)
            if status != noErr {
                current = seg
                finishCurrent()
                events.async { [self] in onWriteError?(WriteFailure(status: status)) }
                return
            }
            seg.record.frames += Int(produced)
            meter.update(seg.output.floatChannelData![0], count: Int(produced) * channels)
        }
        current = seg
    }

    private func finishCurrent() {
        guard current != nil else { return }
        convert(endOfStream: true)
        guard var done = current else { return }
        ExtAudioFileDispose(done.file)
        if let last = done.lastHeader {
            let seconds = Double(done.tracker.frames(in: last)) / done.record.sourceRate
            done.record.endNanos = HostClock.nanos(hostTime: last.hostTime) + UInt64(seconds * 1e9)
        }
        records.append(done.record)
        current = nil
        notifySegments()
    }
}
```

- [ ] **Step 4: Run tests**

Run: `scripts/test.sh`
Expected: exit 0. If `stereoSourceIsAveragedIntoMonoTrack` fails on the value, print the first ten samples in the test and report; do not change `downmix`.

- [ ] **Step 5: Commit**

```bash
git add Sources/DabberCore/Engine/TrackWriter.swift Tests/DabberCoreTests/TrackWriterTests.swift
git commit -m "feat: add track writer converting ring slots into 48k caf segments"
```

---

### Task 6: Capture sources with restart (PropertyWatcher, CaptureSource, InputDeviceSource, ComputerAudioSource, SleepWatcher)

**Files:**
- Create: `Sources/DabberCore/CoreAudio/PropertyWatcher.swift`, `Sources/DabberCore/Engine/CaptureSource.swift`, `Sources/DabberCore/Engine/InputDeviceSource.swift`, `Sources/DabberCore/Engine/ComputerAudioSource.swift`, `Sources/DabberCore/Engine/SleepWatcher.swift`, `Tests/DabberCoreTests/CaptureSourceTests.swift`
- Modify: `Sources/DabberCore/CoreAudio/IOProcRunner.swift`

The restart logic is tested through one seam, `CaptureHooks`: two closures that start the IOProc and register property listeners, each returning a stop closure. `.live` uses `IOProcRunner` and `PropertyWatcher`; the tests pass fakes and fire listener events by hand. Device opening is the overridable `openDevice()` / `deviceIsPresent()`. The hardware path is exercised in Task 10 through the signed bundle.

Restart flow: a trigger from `RestartPolicy` (or `onFormatMismatch` from the writer) at once removes the device listeners, stops the IOProc, closes the segment and closes the device, so no buffer in a new format reaches the old segment. The reopen is scheduled 500 ms after the last trigger, so the burst `nsrt`/`diff`/`sfmt`/`sfmt` seen in Spike 1 run 2 becomes one reopen (format re-read, never cached). If the reopen fails, one retry after 2 s; still failing -> `.failed`. The system listener (`dev#`, `srst`) is registered once in `start()` and removed in `stop()`, so it keeps working while the source waits: `srst` schedules a restart; `dev#` starts a source that is not running and has no pending restart when its device is present (a mic whose UID resolves again, or a failed source), and stops a running source whose device is gone (`.waitingForDevice`). `stop()` cancels the pending restart. Sleep (`pause()`) ignores all triggers until `resume()`. Listener blocks run on the watcher's own queue and hop to the source queue, so `remove()` is never called on the queue the HAL dispatches to.

- [ ] **Step 1: Write `Sources/DabberCore/CoreAudio/PropertyWatcher.swift`**

```swift
import CoreAudio
import Foundation

public final class PropertyWatcher: @unchecked Sendable {
    public typealias Handler = @Sendable (AudioObjectID, AudioObjectPropertySelector) -> Void

    private var registrations: [(AudioObjectID, AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []
    private let queue = DispatchQueue(label: "dabber.listeners")

    public init(objects: [(AudioObjectID, [AudioObjectPropertySelector])], handler: @escaping Handler) throws {
        for (object, selectors) in objects {
            for selector in selectors {
                let block: AudioObjectPropertyListenerBlock = { count, addresses in
                    for i in 0..<Int(count) { handler(object, addresses[i].mSelector) }
                }
                var addr = address(selector)
                let status = AudioObjectAddPropertyListenerBlock(object, &addr, queue, block)
                if status != noErr {
                    remove()
                    throw CAError(status: status, op: "add listener \(fourCC(selector)) on \(object)")
                }
                registrations.append((object, addr, block))
            }
        }
    }

    public func remove() {
        for (object, addr, block) in registrations {
            var a = addr
            AudioObjectRemovePropertyListenerBlock(object, &a, queue, block)
        }
        registrations.removeAll()
    }
}
```

- [ ] **Step 2: Run the IOProc block on the HAL IO thread (`Sources/DabberCore/CoreAudio/IOProcRunner.swift`)**

`AudioDeviceCreateIOProcIDWithBlock` with a queue dispatches every IO block synchronously onto that queue (`AudioHardware.h`, `inDispatchQueue`), so the IO thread waits on a GCD thread. With `nil` the block runs directly on the HAL IO thread. From now on everything the handler calls must be realtime-safe: no allocation, locks, logging, Objective-C or Swift runtime calls that can block. The only handler is `ring.push` (memcpy and atomics). Replace the file with:

```swift
import CoreAudio
import Foundation

public final class IOProcRunner: @unchecked Sendable {
    public typealias Handler = @Sendable (UnsafePointer<AudioBufferList>, UnsafePointer<AudioTimeStamp>) -> Void

    private let device: AudioObjectID
    private var procID: AudioDeviceIOProcID?

    public init(device: AudioObjectID, handler: @escaping Handler) throws {
        self.device = device
        try check(
            AudioDeviceCreateIOProcIDWithBlock(&procID, device, nil) { _, input, inputTime, _, _ in
                handler(input, inputTime)
            }, "create ioproc")
        try check(AudioDeviceStart(device, procID), "start device")
    }

    public func stop() {
        guard let procID else { return }
        AudioDeviceStop(device, procID)
        AudioDeviceDestroyIOProcID(device, procID)
        self.procID = nil
    }
}
```

- [ ] **Step 3: Write the failing tests `Tests/DabberCoreTests/CaptureSourceTests.swift`**

```swift
import CoreAudio
import Foundation
import Synchronization
import Testing
@testable import DabberCore

private final class Probe: Sendable {
    let ioStarts = Atomic<Int>(0)
    let ioRunning = Atomic<Bool>(false)
    let handlers = Mutex<[AudioObjectID: PropertyWatcher.Handler]>([:])

    var hooks: CaptureHooks {
        CaptureHooks(
            startIO: { [self] _, _ in
                ioStarts.wrappingAdd(1, ordering: .relaxed)
                ioRunning.store(true, ordering: .relaxed)
                return { [self] in ioRunning.store(false, ordering: .relaxed) }
            },
            watch: { [self] objects, handler in
                handlers.withLock { h in for (object, _) in objects { h[object] = handler } }
                return {}
            })
    }

    var running: Bool { ioRunning.load(ordering: .relaxed) }
    var starts: Int { ioStarts.load(ordering: .relaxed) }

    func fire(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) {
        let handler = handlers.withLock { $0[object] }
        handler?(object, selector)
    }
}

private final class FakeDeviceSource: CaptureSource, @unchecked Sendable {
    let present = Atomic<Bool>(true)

    override func openDevice() throws -> OpenedDevice {
        guard present.load(ordering: .relaxed) else { throw SourceError.deviceMissing("fake") }
        return OpenedDevice(device: 42, format: int16Mono(rate: 48_000), watched: [(42, .device)])
    }

    override func deviceIsPresent() -> Bool { present.load(ordering: .relaxed) }
}

private func makeSource(_ probe: Probe) throws -> FakeDeviceSource {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cs-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let source = FakeDeviceSource(
        spec: SourceSpec(kind: .mic, uid: "fake", name: "Fake"), dir: dir, baseName: "mic - Fake", channels: 1,
        hooks: probe.hooks)
    source.restartDelay = 0.2
    return source
}

private func waitUntil(_ condition: () -> Bool) -> Bool {
    let end = Date().addingTimeInterval(3)
    while Date() < end {
        if condition() { return true }
        Thread.sleep(forTimeInterval: 0.01)
    }
    return condition()
}

@Test func deviceMissingRestartResumesWhenTheSystemReportsTheUIDBack() throws {
    let probe = Probe()
    let source = try makeSource(probe)
    try source.start()
    #expect(source.status == .running)
    source.present.store(false, ordering: .relaxed)
    probe.fire(42, kAudioDevicePropertyDeviceIsAlive)
    #expect(waitUntil { source.status == .waitingForDevice })
    #expect(!probe.running)
    source.present.store(true, ordering: .relaxed)
    probe.fire(systemObject, kAudioHardwarePropertyDevices)
    #expect(waitUntil { source.status == .running })
    #expect(probe.starts == 2)
    #expect(source.restarts.map(\.reason) == ["livn", "device returned"])
    source.stop()
}

@Test func triggerStopsIOAtOnceAndReopensOnlyAfterTheDebounce() throws {
    let probe = Probe()
    let source = try makeSource(probe)
    try source.start()
    let fired = Date()
    probe.fire(42, kAudioDevicePropertyNominalSampleRate)
    #expect(waitUntil { !probe.running })
    #expect(source.status == .restarting("nsrt"))
    #expect(probe.starts == 1)
    #expect(waitUntil { source.status == .running })
    #expect(Date().timeIntervalSince(fired) >= 0.2)
    #expect(probe.starts == 2)
    #expect(source.writer.segments.map(\.reason) == ["start", "restart: nsrt"])
    source.stop()
}

@Test func stopDuringAPendingRestartLeavesTheSourceStopped() throws {
    let probe = Probe()
    let source = try makeSource(probe)
    try source.start()
    probe.fire(42, kAudioDevicePropertyNominalSampleRate)
    #expect(waitUntil { source.status == .restarting("nsrt") })
    source.stop()
    Thread.sleep(forTimeInterval: 0.4)
    #expect(source.status == .stopped)
    #expect(probe.starts == 1)
    #expect(!probe.running)
}
```

- [ ] **Step 4: Run, expect compile failure**

Run: `scripts/test.sh`
Expected: FAIL, `cannot find type 'CaptureSource' in scope`.

- [ ] **Step 5: Write `Sources/DabberCore/Engine/CaptureSource.swift`**

All mutable state except the status is touched on `queue` only. The status sits in a `Mutex` so the UI and `SessionRecorder.status()` never wait on `queue` while a restart runs HAL calls. `writer` has its own queue; calling it from `queue` is fine, and its callbacks arrive on its events queue and hop to `queue` with `async`.

```swift
import CoreAudio
import Foundation
import Synchronization

public struct SourceSpec: Sendable, Equatable {
    public let kind: SourceKind
    public let uid: String?
    public let name: String

    public init(kind: SourceKind, uid: String?, name: String) {
        self.kind = kind
        self.uid = uid
        self.name = name
    }
}

public enum SourceStatus: Sendable, Equatable {
    case stopped
    case running
    case restarting(String)
    case waitingForDevice
    case failed(String)
}

public enum SourceError: Error, CustomStringConvertible {
    case deviceMissing(String)
    case noInputStream(String)

    public var description: String {
        switch self {
        case .deviceMissing(let uid): return "device \(uid) not present"
        case .noInputStream(let uid): return "device \(uid) has no input stream"
        }
    }
}

struct OpenedDevice {
    let device: AudioObjectID
    let format: AudioStreamBasicDescription
    let watched: [(AudioObjectID, WatchedObject)]
}

public struct CaptureHooks: Sendable {
    public typealias Stop = @Sendable () -> Void
    public typealias StartIO = @Sendable (AudioObjectID, RingBuffer) throws -> Stop
    public typealias Watch = @Sendable (
        [(AudioObjectID, [AudioObjectPropertySelector])], @escaping PropertyWatcher.Handler
    ) throws -> Stop

    public var startIO: StartIO
    public var watch: Watch

    public init(startIO: @escaping StartIO, watch: @escaping Watch) {
        self.startIO = startIO
        self.watch = watch
    }

    public static let live = CaptureHooks(
        startIO: { device, ring in
            let runner = try IOProcRunner(device: device) { list, time in ring.push(list, time) }
            return { runner.stop() }
        },
        watch: { objects, handler in
            let watcher = try PropertyWatcher(objects: objects, handler: handler)
            return { watcher.remove() }
        })
}

public class CaptureSource: @unchecked Sendable {
    public let spec: SourceSpec
    public let writer: TrackWriter
    let queue = DispatchQueue(label: "dabber.source")
    var restartDelay = 0.5
    var retryDelay = 2.0
    private let ring: RingBuffer
    private let hooks: CaptureHooks
    private var stopIO: CaptureHooks.Stop?
    private var stopWatcher: CaptureHooks.Stop?
    private var stopSystemWatcher: CaptureHooks.Stop?
    private var kinds: [AudioObjectID: WatchedObject] = [:]
    private var pendingRestart: DispatchWorkItem?
    private var attempts = 0
    private var wanted = false
    private var paused = false
    private let statusValue = Mutex<SourceStatus>(.stopped)
    private var restartEvents: [RestartEvent] = []

    public init(spec: SourceSpec, dir: URL, baseName: String, channels: Int, hooks: CaptureHooks = .live) {
        self.spec = spec
        self.hooks = hooks
        ring = RingBuffer(slotCount: 256, slotBytes: 32_768)
        writer = TrackWriter(dir: dir, baseName: baseName, channels: channels, ring: ring)
        writer.onFormatMismatch = { [weak self] in self?.requestRestart(reason: "buffer size mismatch") }
    }

    func openDevice() throws -> OpenedDevice { fatalError("subclass responsibility") }
    func closeDevice() {}
    func deviceIsPresent() -> Bool { true }

    public var status: SourceStatus { statusValue.withLock { $0 } }
    public var restarts: [RestartEvent] { queue.sync { restartEvents } }
    public var overruns: Int { ring.overruns }

    public func start() throws {
        try queue.sync {
            wanted = true
            stopSystemWatcher = try hooks.watch([(systemObject, RestartPolicy.selectors(for: .system))]) {
                [weak self] _, selector in
                guard let self else { return }
                queue.async { self.handleSystem(selector) }
            }
            do {
                try startLocked(reason: "start")
            } catch {
                stopSystemWatcher?()
                stopSystemWatcher = nil
                wanted = false
                throw error
            }
        }
    }

    public func stop() {
        queue.sync {
            wanted = false
            stopSystemWatcher?()
            stopSystemWatcher = nil
            stopLocked()
        }
        writer.stop()
    }

    public func pause() {
        queue.sync {
            paused = true
            stopLocked()
        }
    }

    public func resume() {
        queue.async { [self] in
            paused = false
            guard wanted, stopIO == nil else { return }
            restartEvents.append(RestartEvent(atNanos: HostClock.nowNanos(), reason: "wake"))
            do { try startLocked(reason: "restart: wake") } catch { setStatus(.failed("\(error)")) }
        }
    }

    private func startLocked(reason: String) throws {
        let opened = try openDevice()
        do {
            try writer.openSegment(format: opened.format, reason: reason)
            stopIO = try hooks.startIO(opened.device, ring)
            kinds = Dictionary(opened.watched.map { ($0.0, $0.1) }, uniquingKeysWith: { a, _ in a })
            stopWatcher = try hooks.watch(opened.watched.map { ($0.0, RestartPolicy.selectors(for: $0.1)) }) {
                [weak self] object, selector in
                guard let self else { return }
                queue.async { self.handle(object: object, selector: selector) }
            }
        } catch {
            tearDown()
            throw error
        }
        attempts = 0
        setStatus(.running)
    }

    private func tearDown() {
        stopWatcher?()
        stopWatcher = nil
        stopIO?()
        stopIO = nil
        writer.closeSegment()
        closeDevice()
    }

    private func stopLocked() {
        pendingRestart?.cancel()
        pendingRestart = nil
        tearDown()
        setStatus(.stopped)
    }

    private func setStatus(_ s: SourceStatus) { statusValue.withLock { $0 = s } }

    private func handle(object: AudioObjectID, selector: AudioObjectPropertySelector) {
        guard wanted, !paused, let kind = kinds[object], RestartPolicy.shouldRestart(selector, on: kind) else { return }
        scheduleRestart(reason: fourCC(selector), after: restartDelay)
    }

    private func handleSystem(_ selector: AudioObjectPropertySelector) {
        guard wanted, !paused else { return }
        if selector == kAudioHardwarePropertyDevices {
            devicesChanged()
        } else {
            scheduleRestart(reason: fourCC(selector), after: restartDelay)
        }
    }

    private func requestRestart(reason: String) {
        queue.async { [self] in
            guard !paused else { return }
            scheduleRestart(reason: reason, after: restartDelay)
        }
    }

    private func scheduleRestart(reason: String, after delay: Double) {
        guard wanted else { return }
        setStatus(.restarting(reason))
        tearDown()
        pendingRestart?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.restartLocked(reason: reason) }
        pendingRestart = item
        queue.asyncAfter(deadline: .now() + delay, execute: item)
    }

    private func restartLocked(reason: String) {
        pendingRestart = nil
        guard wanted, !paused else { return }
        restartEvents.append(RestartEvent(atNanos: HostClock.nowNanos(), reason: reason))
        do {
            try startLocked(reason: "restart: \(reason)")
        } catch SourceError.deviceMissing {
            setStatus(.waitingForDevice)
        } catch {
            attempts += 1
            if attempts < 2 {
                scheduleRestart(reason: reason, after: retryDelay)
            } else {
                setStatus(.failed("\(error)"))
            }
        }
    }

    private func devicesChanged() {
        let present = deviceIsPresent()
        if present, stopIO == nil, pendingRestart == nil {
            restartEvents.append(RestartEvent(atNanos: HostClock.nowNanos(), reason: "device returned"))
            do {
                try startLocked(reason: "restart: device returned")
            } catch SourceError.deviceMissing {
                setStatus(.waitingForDevice)
            } catch {
                setStatus(.failed("\(error)"))
            }
        } else if !present, stopIO != nil {
            pendingRestart?.cancel()
            pendingRestart = nil
            tearDown()
            setStatus(.waitingForDevice)
        }
    }
}
```

- [ ] **Step 6: Write `Sources/DabberCore/Engine/InputDeviceSource.swift`**

```swift
import CoreAudio
import Foundation

public final class InputDeviceSource: CaptureSource, @unchecked Sendable {
    private let uid: String

    public init(spec: SourceSpec, dir: URL, baseName: String) {
        uid = spec.uid ?? ""
        super.init(spec: spec, dir: dir, baseName: baseName, channels: 1)
    }

    override func openDevice() throws -> OpenedDevice {
        let device = try deviceID(uid: uid)
        guard device != kAudioObjectUnknown else { throw SourceError.deviceMissing(uid) }
        let streams = try getArray(
            device, address(kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeInput),
            filler: AudioObjectID(0))
        guard let stream = streams.first else { throw SourceError.noInputStream(uid) }
        let format = try getValue(
            stream, address(kAudioStreamPropertyVirtualFormat), default: AudioStreamBasicDescription())
        return OpenedDevice(
            device: device, format: format,
            watched: [(device, .device), (stream, .inputStream)])
    }

    override func deviceIsPresent() -> Bool {
        ((try? deviceID(uid: uid)) ?? kAudioObjectUnknown) != kAudioObjectUnknown
    }
}
```

- [ ] **Step 7: Write `Sources/DabberCore/Engine/ComputerAudioSource.swift`**

The tap and its aggregate are recreated on every (re)start; Spike 0 showed creation is fast enough for a headless run to start within its first log second.

```swift
import CoreAudio
import Foundation

public final class ComputerAudioSource: CaptureSource, @unchecked Sendable {
    private var tap: GlobalTap?

    public init(spec: SourceSpec, dir: URL, baseName: String) {
        super.init(spec: spec, dir: dir, baseName: baseName, channels: 2)
    }

    override func openDevice() throws -> OpenedDevice {
        let tap = try GlobalTap()
        self.tap = tap
        let streams = try getArray(
            tap.aggregateID, address(kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeInput),
            filler: AudioObjectID(0))
        var watched: [(AudioObjectID, WatchedObject)] = [
            (tap.aggregateID, .device), (tap.tapID, .tap),
        ]
        if let stream = streams.first { watched.append((stream, .inputStream)) }
        return OpenedDevice(device: tap.aggregateID, format: tap.format, watched: watched)
    }

    override func closeDevice() {
        tap?.destroy()
        tap = nil
    }
}
```

- [ ] **Step 8: Write `Sources/DabberCore/Engine/SleepWatcher.swift`** (**verified** names)

```swift
import AppKit

public final class SleepWatcher: @unchecked Sendable {
    private var tokens: [NSObjectProtocol] = []

    public init(willSleep: @escaping @Sendable () -> Void, didWake: @escaping @Sendable () -> Void) {
        let center = NSWorkspace.shared.notificationCenter
        tokens.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: nil) { _ in willSleep() })
        tokens.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: nil) { _ in didWake() })
    }

    public func remove() {
        for t in tokens { NSWorkspace.shared.notificationCenter.removeObserver(t) }
        tokens.removeAll()
    }
}
```

- [ ] **Step 9: Build and run the tests**

Run: `swift build && scripts/test.sh`
Expected: both exit 0, including the three `CaptureSourceTests` (each takes under 1 s).

- [ ] **Step 10: Commit**

```bash
git add Sources/DabberCore/CoreAudio/PropertyWatcher.swift Sources/DabberCore/CoreAudio/IOProcRunner.swift Sources/DabberCore/Engine/CaptureSource.swift Sources/DabberCore/Engine/InputDeviceSource.swift Sources/DabberCore/Engine/ComputerAudioSource.swift Sources/DabberCore/Engine/SleepWatcher.swift Tests/DabberCoreTests/CaptureSourceTests.swift
git commit -m "feat: add capture sources with debounced restart and device re-find"
```

---

### Task 7: SessionRecorder (state machine, manifest, disk check, sleep/wake, silence)

**Files:**
- Create: `Sources/DabberCore/Engine/SessionRecorder.swift`, `Tests/DabberCoreTests/SessionRecorderTests.swift`

The recorder is testable without hardware through two injected closures: `makeSource` (tests return a `CaptureSource` subclass that overrides `start`/`stop`) and `freeBytes`. The fake source records calls in static arrays, so its tests sit in a `.serialized` suite. The recorder keeps its own copy of every source's segment list (from `onSegmentsChanged`) and writes `session.json` on every change, so a crash leaves a manifest that names every CAF, including the open one.

- [ ] **Step 1: Write the failing tests `Tests/DabberCoreTests/SessionRecorderTests.swift`**

```swift
import Foundation
import Testing
@testable import DabberCore

private final class FakeSource: CaptureSource, @unchecked Sendable {
    nonisolated(unsafe) static var started: [String] = []
    nonisolated(unsafe) static var stopped: [String] = []
    nonisolated(unsafe) static var failStart = false

    override func start() throws {
        if Self.failStart { throw SourceError.deviceMissing(spec.uid ?? "") }
        Self.started.append(writer.baseName)
    }

    override func stop() {
        Self.stopped.append(writer.baseName)
        writer.stop()
    }
}

private func recorder(free: Int64 = 3_000_000_000) throws -> (SessionRecorder, URL) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("sr-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    FakeSource.started = []
    FakeSource.stopped = []
    FakeSource.failStart = false
    let r = SessionRecorder(
        root: root, appVersion: "t",
        makeSource: { spec, dir, base in FakeSource(spec: spec, dir: dir, baseName: base, channels: spec.kind == .mic ? 1 : 2) },
        freeBytes: { _ in free })
    return (r, root)
}

private let specs = [
    SourceSpec(kind: .computer, uid: nil, name: "Computer audio"),
    SourceSpec(kind: .mic, uid: "u1", name: "AirPods"),
]

@Suite(.serialized) struct SessionRecorderTests {
    @Test func startCreatesFolderAndManifestThenStopFinalizesManifest() throws {
        let (r, root) = try recorder()
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let dir = try r.start(specs: specs, at: date)
        #expect(dir.lastPathComponent == SessionNaming.folderName(date))
        #expect(dir.deletingLastPathComponent().path == root.path)
        #expect(FakeSource.started == ["computer audio", "mic - AirPods"])
        let m = try SessionManifest.load(from: dir)
        #expect(m.sources.map(\.file) == ["computer audio.m4a", "mic - AirPods.m4a"])
        #expect(m.sources.map(\.channels) == [2, 1])
        #expect(r.status(at: date.addingTimeInterval(5)).phase == .recording)
        #expect(r.status(at: date.addingTimeInterval(5)).elapsedSeconds == 5)
        #expect(r.stop() == dir)
        #expect(FakeSource.stopped == ["computer audio", "mic - AirPods"])
        #expect(r.status(at: date).phase == .idle)
        #expect(r.lastSessionDir == dir)
    }

    @Test func startIsRefusedWhileRecordingAndWhenDiskIsLow() throws {
        let (r, _) = try recorder()
        _ = try r.start(specs: specs)
        #expect(throws: RecorderError.self) { try r.start(specs: specs) }
        _ = r.stop()
        let (low, _) = try recorder(free: 1)
        #expect(throws: RecorderError.self) { try low.start(specs: specs) }
    }

    @Test func failingSourceStartRollsBack() throws {
        let (r, root) = try recorder()
        FakeSource.failStart = true
        #expect(throws: SourceError.self) { try r.start(specs: specs) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
        #expect(r.status(at: Date()).phase == .idle)
    }

    @Test func stopWithoutStartReturnsNil() throws {
        let (r, _) = try recorder()
        #expect(r.stop() == nil)
    }
}
```

- [ ] **Step 2: Run, expect compile failure**

Run: `scripts/test.sh`
Expected: FAIL, `cannot find 'SessionRecorder' in scope`.

- [ ] **Step 3: Write `Sources/DabberCore/Engine/SessionRecorder.swift`**

```swift
import Foundation

public enum RecorderError: Error, CustomStringConvertible {
    case busy
    case lowDisk(freeBytes: Int64)
    case noSources

    public var description: String {
        switch self {
        case .busy: return "already recording"
        case .lowDisk(let free): return "only \(free / 1_000_000) MB free, need \(DiskCheck.minimumFreeBytes / 1_000_000) MB"
        case .noSources: return "no sources selected"
        }
    }
}

public struct SourceSnapshot: Sendable, Equatable {
    public let spec: SourceSpec
    public let status: SourceStatus
    public let levelDb: Double
    public let silent: Bool
}

public struct RecorderStatus: Sendable, Equatable {
    public let phase: RecorderPhase
    public let elapsedSeconds: Double
    public let sources: [SourceSnapshot]
    public let sessionDir: URL?
    public let lastError: String?
}

public final class SessionRecorder: @unchecked Sendable {
    public typealias MakeSource = @Sendable (SourceSpec, URL, String) -> CaptureSource

    public let root: URL
    public let appVersion: String
    private let makeSource: MakeSource
    private let freeBytes: @Sendable (URL) throws -> Int64
    private let lock = NSLock()
    private var state = SessionState()
    private var sources: [CaptureSource] = []
    private var manifest: SessionManifest?
    private var dir: URL?
    private var startedAt: Date?
    private var silence: [String: SilenceRule] = [:]
    private var sleepWatcher: SleepWatcher?
    private var lastError: String?
    public private(set) var lastSessionDir: URL?

    public init(
        root: URL, appVersion: String,
        makeSource: @escaping MakeSource = SessionRecorder.defaultSource,
        freeBytes: @escaping @Sendable (URL) throws -> Int64 = DiskCheck.freeBytes
    ) {
        self.root = root
        self.appVersion = appVersion
        self.makeSource = makeSource
        self.freeBytes = freeBytes
    }

    public static let defaultSource: MakeSource = { spec, dir, base in
        switch spec.kind {
        case .computer: return ComputerAudioSource(spec: spec, dir: dir, baseName: base)
        case .mic: return InputDeviceSource(spec: spec, dir: dir, baseName: base)
        }
    }

    @discardableResult
    public func start(specs: [SourceSpec], at date: Date = Date()) throws -> URL {
        lock.lock(); defer { lock.unlock() }
        guard state.phase == .idle else { throw RecorderError.busy }
        guard !specs.isEmpty else { throw RecorderError.noSources }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let free = try freeBytes(root)
        guard DiskCheck.hasRoom(freeBytes: free) else { throw RecorderError.lowDisk(freeBytes: free) }
        let dir = root.appendingPathComponent(SessionNaming.folderName(date))
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var manifest = SessionManifest(appVersion: appVersion, startedAt: date, sessionStartNanos: HostClock.nowNanos())
        var created: [CaptureSource] = []
        var taken: [String] = []
        for spec in specs {
            let base = SessionNaming.trackBase(kind: spec.kind, name: spec.name, taken: taken)
            taken.append(base)
            let source = makeSource(spec, dir, base)
            manifest.sources.append(SourceManifest(
                kind: spec.kind, uid: spec.uid, name: spec.name, file: base + ".m4a",
                channels: source.writer.channels, segments: [], restarts: [], overruns: 0))
            created.append(source)
        }
        for (i, source) in created.enumerated() {
            source.writer.onSegmentsChanged = { [weak self] records in self?.segmentsChanged(index: i, records) }
            source.writer.onWriteError = { [weak self] error in self?.stopAfterError(error) }
        }
        do {
            for source in created { try source.start() }
        } catch {
            for source in created { source.stop() }
            try? FileManager.default.removeItem(at: dir)
            throw error
        }
        sources = created
        self.manifest = manifest
        self.dir = dir
        startedAt = date
        silence = [:]
        lastError = nil
        _ = state.start()
        sleepWatcher = SleepWatcher(
            willSleep: { [weak self] in self?.forEachSource { $0.pause() } },
            didWake: { [weak self] in self?.forEachSource { $0.resume() } })
        try manifest.save(to: dir)
        return dir
    }

    @discardableResult
    public func stop() -> URL? {
        lock.lock()
        guard state.stop(), let dir, var manifest else {
            lock.unlock()
            return nil
        }
        let sources = self.sources
        sleepWatcher?.remove()
        sleepWatcher = nil
        lock.unlock()
        for source in sources { source.stop() }
        lock.lock(); defer { lock.unlock() }
        for (i, source) in sources.enumerated() {
            manifest.sources[i].segments = source.writer.segments
            manifest.sources[i].restarts = source.restarts
            manifest.sources[i].overruns = source.overruns
        }
        try? manifest.save(to: dir)
        self.manifest = nil
        self.sources = []
        self.dir = nil
        startedAt = nil
        lastSessionDir = dir
        state.finished()
        return dir
    }

    public func status(at now: Date = Date()) -> RecorderStatus {
        lock.lock(); defer { lock.unlock() }
        let computerDb = sources.first { $0.spec.kind == .computer }?.writer.meter.decibels ?? -160
        var snapshots: [SourceSnapshot] = []
        for source in sources {
            let db = source.writer.meter.decibels
            var silent = false
            if source.spec.kind == .mic {
                var rule = silence[source.writer.baseName] ?? SilenceRule()
                silent = rule.update(micDb: db, computerDb: computerDb, now: now.timeIntervalSince1970)
                silence[source.writer.baseName] = rule
            }
            snapshots.append(SourceSnapshot(spec: source.spec, status: source.status, levelDb: db, silent: silent))
        }
        return RecorderStatus(
            phase: state.phase,
            elapsedSeconds: startedAt.map { now.timeIntervalSince($0) } ?? 0,
            sources: snapshots, sessionDir: dir, lastError: lastError)
    }

    private func forEachSource(_ body: (CaptureSource) -> Void) {
        lock.lock()
        let sources = self.sources
        lock.unlock()
        for source in sources { body(source) }
    }

    private func segmentsChanged(index: Int, _ records: [SegmentRecord]) {
        lock.lock(); defer { lock.unlock() }
        guard var manifest, let dir, index < manifest.sources.count else { return }
        manifest.sources[index].segments = records
        manifest.sources[index].overruns = sources[index].overruns
        self.manifest = manifest
        try? manifest.save(to: dir)
    }

    private func stopAfterError(_ error: Error) {
        lock.lock()
        lastError = "\(error)"
        lock.unlock()
        stop()
    }
}
```

- [ ] **Step 4: Run tests**

Run: `scripts/test.sh`
Expected: exit 0. `segmentsChanged` holds `lock` and touches only the atomic overrun counter, never a source queue; restart events reach the manifest at `stop()`. `stop()` never holds `lock` while calling into a source.

- [ ] **Step 5: Commit**

```bash
git add Sources/DabberCore/Engine/SessionRecorder.swift Tests/DabberCoreTests/SessionRecorderTests.swift
git commit -m "feat: add session recorder with manifest writes, disk check and sleep handling"
```

---

### Task 8: Finalizer pure parts (timeline reader, drift resampler, gaps, plan)

**Files:**
- Create: `Sources/DabberCore/Finalize/SegmentSource.swift`, `Sources/DabberCore/Finalize/TimelineReader.swift`, `Sources/DabberCore/Finalize/FinalizePlan.swift`, `Tests/DabberCoreTests/TimelineReaderTests.swift`
- Modify: `Sources/DabberCore/Model/Segment.swift`

Drift correction is a stretch by well under 1 % (the threshold is 50 ms per segment), so linear interpolation is enough and keeps the finalizer free of converter state. The CAF file length is the source of truth for a segment's frames; the manifest value may be stale after a crash.

- [ ] **Step 1: Write the failing tests `Tests/DabberCoreTests/TimelineReaderTests.swift`**

```swift
import Testing
@testable import DabberCore

@Test func readerZeroFillsGapsAndHonoursSkip() throws {
    let a = MemorySegment(samples: [1, 2, 3, 4], channels: 1)
    let b = MemorySegment(samples: [5, 6, 7], channels: 1)
    let placements = [
        Placement(segmentIndex: 0, destFrame: 1, skipFrames: 0, frames: 4),
        Placement(segmentIndex: 1, destFrame: 7, skipFrames: 1, frames: 2),
    ]
    let r = TimelineReader(placements: placements, sources: [a, b], channels: 1)
    #expect(r.totalFrames == 9)
    #expect(try r.read(0..<9) == [0, 1, 2, 3, 4, 0, 0, 6, 7])
    #expect(try r.read(3..<8) == [3, 4, 0, 0, 6])
    #expect(try r.read(9..<12) == [0, 0, 0])
}

@Test func readerHandlesInterleavedStereo() throws {
    let a = MemorySegment(samples: [1, -1, 2, -2], channels: 2)
    let r = TimelineReader(placements: [Placement(segmentIndex: 0, destFrame: 1, skipFrames: 1, frames: 1)], sources: [a], channels: 2)
    #expect(try r.read(0..<3) == [0, 0, 2, -2, 0, 0])
}

@Test func resamplerKeepsConstantsAndInterpolatesRamps() throws {
    let constant = DriftResampler(MemorySegment(samples: [Float](repeating: 0.5, count: 100), channels: 1), targetFrames: 90)
    #expect(constant.frames == 90)
    #expect(try constant.read(0..<90).allSatisfy { abs($0 - 0.5) < 1e-6 })
    let ramp = DriftResampler(MemorySegment(samples: (0..<10).map(Float.init), channels: 1), targetFrames: 20)
    let out = try ramp.read(0..<20)
    #expect(abs(out[2] - 1.0) < 1e-6)
    #expect(abs(out[3] - 1.5) < 1e-6)
    #expect(out.count == 20)
    #expect(try ramp.read(18..<20).count == 2)
}

@Test func gapsAreListedFromZero() {
    let p = [
        Placement(segmentIndex: 0, destFrame: 10, skipFrames: 0, frames: 5),
        Placement(segmentIndex: 1, destFrame: 15, skipFrames: 0, frames: 5),
        Placement(segmentIndex: 2, destFrame: 30, skipFrames: 0, frames: 1),
    ]
    #expect(Timeline.gaps(p) == [Gap(atFrame: 0, frames: 10), Gap(atFrame: 20, frames: 10)])
    #expect(Timeline.gaps([]).isEmpty)
}

@Test func planResamplesOnlyAboveFiftyMilliseconds() {
    let hour: UInt64 = 3_600_000_000_000
    let records = [
        SegmentRecord(file: "a", startNanos: 1, frames: 0, endNanos: 1 + hour, sourceRate: 48_000, sourceChannels: 1, reason: "start"),
        SegmentRecord(file: "b", startNanos: 1, frames: 0, endNanos: 1 + hour, sourceRate: 48_000, sourceChannels: 1, reason: "start"),
        SegmentRecord(file: "c", startNanos: 1, frames: 0, endNanos: nil, sourceRate: 48_000, sourceChannels: 1, reason: "start"),
        SegmentRecord(file: "d", startNanos: 0, frames: 0, endNanos: nil, sourceRate: 48_000, sourceChannels: 1, reason: "start"),
    ]
    let plans = FinalizePlan.make(records, fileFrames: [48_000 * 3600 + 4_800, 48_000 * 3600 + 2_000, 100, 100])
    #expect(plans.map(\.file) == ["a", "b", "c"])
    #expect(plans[0].resample && plans[0].segment.frames == 48_000 * 3600)
    #expect(!plans[1].resample && plans[1].segment.frames == 48_000 * 3600 + 2_000)
    #expect(!plans[2].resample && plans[2].segment.frames == 100)
    #expect(abs(plans[0].driftMillis - 100) < 0.01)
}
```

- [ ] **Step 2: Run, expect compile failure**

Run: `scripts/test.sh`
Expected: FAIL, `cannot find 'MemorySegment' in scope`.

- [ ] **Step 3: Write `Sources/DabberCore/Finalize/SegmentSource.swift`**

```swift
public protocol SegmentSource {
    var frames: Int { get }
    var channels: Int { get }
    func read(_ range: Range<Int>) throws -> [Float]
}

public struct MemorySegment: SegmentSource {
    public let samples: [Float]
    public let channels: Int

    public init(samples: [Float], channels: Int) {
        self.samples = samples
        self.channels = channels
    }

    public var frames: Int { samples.count / channels }

    public func read(_ range: Range<Int>) -> [Float] {
        Array(samples[(range.lowerBound * channels)..<(range.upperBound * channels)])
    }
}

public struct DriftResampler: SegmentSource {
    private let inner: any SegmentSource
    public let frames: Int

    public init(_ inner: any SegmentSource, targetFrames: Int) {
        self.inner = inner
        frames = targetFrames
    }

    public var channels: Int { inner.channels }

    public func read(_ range: Range<Int>) throws -> [Float] {
        guard !range.isEmpty else { return [] }
        let ratio = Double(inner.frames) / Double(frames)
        let from = Int(Double(range.lowerBound) * ratio)
        let to = min(inner.frames, Int(Double(range.upperBound - 1) * ratio) + 2)
        let src = try inner.read(from..<to)
        let ch = channels
        let last = (to - from) - 1
        var out = [Float](repeating: 0, count: range.count * ch)
        for (i, frame) in range.enumerated() {
            let pos = Double(frame) * ratio
            let k = Int(pos)
            let frac = Float(pos - Double(k))
            let a = min(k - from, last)
            let b = min(a + 1, last)
            for c in 0..<ch {
                out[i * ch + c] = src[a * ch + c] * (1 - frac) + src[b * ch + c] * frac
            }
        }
        return out
    }
}
```

- [ ] **Step 4: Write `Sources/DabberCore/Finalize/TimelineReader.swift`**

```swift
public struct TimelineReader {
    public let placements: [Placement]
    public let sources: [any SegmentSource]
    public let channels: Int

    public init(placements: [Placement], sources: [any SegmentSource], channels: Int) {
        self.placements = placements
        self.sources = sources
        self.channels = channels
    }

    public var totalFrames: Int { placements.map { $0.destFrame + $0.frames }.max() ?? 0 }

    public func read(_ range: Range<Int>) throws -> [Float] {
        var out = [Float](repeating: 0, count: range.count * channels)
        for p in placements {
            let lo = max(range.lowerBound, p.destFrame)
            let hi = min(range.upperBound, p.destFrame + p.frames)
            guard lo < hi else { continue }
            let start = p.skipFrames + (lo - p.destFrame)
            let data = try sources[p.segmentIndex].read(start..<(start + hi - lo))
            let offset = (lo - range.lowerBound) * channels
            for i in 0..<data.count { out[offset + i] = data[i] }
        }
        return out
    }
}
```

- [ ] **Step 5: Add `Gap` and `Timeline.gaps` to `Sources/DabberCore/Model/Segment.swift`**

Append after `Placement`:

```swift
public struct Gap: Equatable, Sendable {
    public let atFrame: Int
    public let frames: Int

    public init(atFrame: Int, frames: Int) {
        self.atFrame = atFrame
        self.frames = frames
    }
}
```

Append inside `Timeline`:

```swift
    public static func gaps(_ placements: [Placement]) -> [Gap] {
        var result: [Gap] = []
        var cursor = 0
        for p in placements {
            if p.destFrame > cursor { result.append(Gap(atFrame: cursor, frames: p.destFrame - cursor)) }
            cursor = p.destFrame + p.frames
        }
        return result
    }
```

- [ ] **Step 6: Write `Sources/DabberCore/Finalize/FinalizePlan.swift`**

```swift
public struct FinalizePlan: Equatable, Sendable {
    public static let resampleThresholdMillis: Double = 50

    public let file: String
    public let segment: Segment
    public let resample: Bool
    public let driftMillis: Double

    public static func make(_ records: [SegmentRecord], fileFrames: [Int]) -> [FinalizePlan] {
        zip(records, fileFrames).compactMap { record, frames in
            guard record.startNanos > 0, frames > 0 else { return nil }
            let measured = Segment(startNanos: record.startNanos, frames: frames, endNanos: record.endNanos)
            let drift = Timeline.driftMillis(measured)
            guard abs(drift) > resampleThresholdMillis, let end = record.endNanos else {
                return FinalizePlan(file: record.file, segment: measured, resample: false, driftMillis: drift)
            }
            let expected = Timeline.frames(nanos: Int64(end) - Int64(record.startNanos))
            return FinalizePlan(
                file: record.file, segment: Segment(startNanos: record.startNanos, frames: expected, endNanos: end),
                resample: true, driftMillis: drift)
        }
    }
}
```

- [ ] **Step 7: Run tests**

Run: `scripts/test.sh`
Expected: exit 0.

- [ ] **Step 8: Commit**

```bash
git add Sources/DabberCore/Finalize/SegmentSource.swift Sources/DabberCore/Finalize/TimelineReader.swift Sources/DabberCore/Finalize/FinalizePlan.swift Sources/DabberCore/Model/Segment.swift Tests/DabberCoreTests/TimelineReaderTests.swift
git commit -m "feat: add chunked timeline reader, drift resampler and finalize plan"
```

---

### Task 9: Finalizer IO (CAF read, AAC write, one-pass render, recovery)

**Files:**
- Create: `Sources/DabberCore/Finalize/CAFSegment.swift`, `Sources/DabberCore/Finalize/AACWriter.swift`, `Sources/DabberCore/Finalize/Finalizer.swift`, `Tests/DabberCoreTests/FinalizerTests.swift`

One pass over the timeline in 48 000-frame chunks: each chunk is read from every track, written to that track's `.m4a`, mixed, and written to `mix.m4a`. Peak memory is one chunk per track (384 KB stereo). After `close()` every file is reopened and its `length` compared with the frame count written (exact, **verified**); only then is the report saved into `session.json` and are the CAFs deleted. A session needs recovery while its manifest has no `finalize` report and CAFs remain, so a finalize interrupted after `mix.m4a` was created runs again and overwrites the partial files (**verified**: a rerun over a junk `mix.m4a` produces 144,000-frame outputs).

- [ ] **Step 1: Write the failing tests `Tests/DabberCoreTests/FinalizerTests.swift`**

```swift
import AVFoundation
import AudioToolbox
import Foundation
import Testing
@testable import DabberCore

private func writeCAF(_ url: URL, samples: [Float], channels: Int) throws {
    let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: AVAudioChannelCount(channels), interleaved: true)!
    var asbd = format.streamDescription.pointee
    var ref: ExtAudioFileRef?
    try check(ExtAudioFileCreateWithURL(url as CFURL, kAudioFileCAFType, &asbd, nil, AudioFileFlags.eraseFile.rawValue, &ref), "create")
    var client = asbd
    try check(ExtAudioFileSetProperty(ref!, kExtAudioFileProperty_ClientDataFormat, UInt32(MemoryLayout<AudioStreamBasicDescription>.size), &client), "client")
    let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count / channels))!
    buf.frameLength = buf.frameCapacity
    samples.withUnsafeBufferPointer { buf.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
    try check(ExtAudioFileWrite(ref!, buf.frameLength, buf.audioBufferList), "write")
    ExtAudioFileDispose(ref!)
}

private func sine(frames: Int, channels: Int, amplitude: Float = 0.5) -> [Float] {
    (0..<(frames * channels)).map { i in amplitude * Float(sin(Double(i / channels) / 48_000 * 2 * .pi * 440)) }
}

private func rms(_ url: URL, from: Int, frames: Int) throws -> Float {
    let f = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: true)
    f.framePosition = AVAudioFramePosition(from)
    let buf = AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: AVAudioFrameCount(frames))!
    try f.read(into: buf, frameCount: AVAudioFrameCount(frames))
    let n = Int(buf.frameLength) * Int(f.processingFormat.channelCount)
    var sum: Float = 0
    for i in 0..<n { sum += buf.floatChannelData![0][i] * buf.floatChannelData![0][i] }
    return (sum / Float(max(n, 1))).squareRoot()
}

private func makeSession() throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("fin-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let s: UInt64 = 10_000_000_000
    var m = SessionManifest(appVersion: "t", startedAt: Date(), sessionStartNanos: s)
    m.sources = [
        SourceManifest(kind: .mic, uid: "u", name: "A", file: "mic - A.m4a", channels: 1, segments: [
            SegmentRecord(file: "mic - A.seg000.caf", startNanos: s, frames: 48_000, endNanos: s + 1_000_000_000, sourceRate: 24_000, sourceChannels: 1, reason: "start"),
            SegmentRecord(file: "mic - A.seg001.caf", startNanos: s + 2_000_000_000, frames: 0, endNanos: nil, sourceRate: 48_000, sourceChannels: 1, reason: "restart: nsrt"),
        ], restarts: [], overruns: 0),
        SourceManifest(kind: .computer, uid: nil, name: "Computer audio", file: "computer audio.m4a", channels: 2, segments: [
            SegmentRecord(file: "computer audio.seg000.caf", startNanos: s, frames: 144_000, endNanos: s + 3_000_000_000, sourceRate: 48_000, sourceChannels: 2, reason: "start"),
        ], restarts: [], overruns: 0),
    ]
    try m.save(to: dir)
    try writeCAF(dir.appendingPathComponent("mic - A.seg000.caf"), samples: sine(frames: 48_000, channels: 1), channels: 1)
    try writeCAF(dir.appendingPathComponent("mic - A.seg001.caf"), samples: sine(frames: 24_000, channels: 1), channels: 1)
    try writeCAF(dir.appendingPathComponent("computer audio.seg000.caf"), samples: sine(frames: 144_000, channels: 2, amplitude: 0.25), channels: 2)
    return dir
}

@Test func finalizerRendersTracksMixAndReportThenDeletesCAFs() throws {
    let dir = try makeSession()
    let report = try Finalizer.run(dir)
    #expect(report.totalFrames == 144_000)
    let names = try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()
    #expect(names == ["computer audio.m4a", "mic - A.m4a", "mix.m4a", "session.json"])
    for n in ["computer audio.m4a", "mic - A.m4a", "mix.m4a"] {
        #expect(try AVAudioFile(forReading: dir.appendingPathComponent(n)).length == 144_000, "\(n)")
    }
    #expect(try rms(dir.appendingPathComponent("mic - A.m4a"), from: 10_000, frames: 4_800) > 0.2)
    #expect(try rms(dir.appendingPathComponent("mic - A.m4a"), from: 60_000, frames: 4_800) < 0.01)
    #expect(try rms(dir.appendingPathComponent("mic - A.m4a"), from: 100_000, frames: 4_800) > 0.2)
    #expect(try rms(dir.appendingPathComponent("mix.m4a"), from: 60_000, frames: 4_800) > 0.1)
    #expect(report.gaps == [GapRecord(track: "mic - A", atFrame: 48_000, frames: 48_000)])
    #expect(report.driftMillis["mic - A.seg000.caf"] == 0)
    #expect(report.resampled.isEmpty)
    #expect(try SessionManifest.load(from: dir).finalize == report)
}

@Test func recoveryFinalizesFoldersWithCAFsButNoMix() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("rec-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let unfinished = try makeSession()
    let pending = root.appendingPathComponent("pending")
    try FileManager.default.moveItem(at: unfinished, to: pending)
    let done = root.appendingPathComponent("done")
    try FileManager.default.createDirectory(at: done, withIntermediateDirectories: true)
    try Data().write(to: done.appendingPathComponent("mix.m4a"))
    try Data().write(to: done.appendingPathComponent("stray.caf"))
    #expect(try Finalizer.recoverAll(root: root).map(\.path) == [pending.path])
    #expect(FileManager.default.fileExists(atPath: pending.appendingPathComponent("mix.m4a").path))
    #expect(FileManager.default.fileExists(atPath: done.appendingPathComponent("stray.caf").path))
}

@Test func missingSegmentFileIsSkippedNotFatal() throws {
    let dir = try makeSession()
    try FileManager.default.removeItem(at: dir.appendingPathComponent("mic - A.seg001.caf"))
    let report = try Finalizer.run(dir)
    #expect(report.totalFrames == 144_000)
    #expect(try rms(dir.appendingPathComponent("mic - A.m4a"), from: 100_000, frames: 4_800) < 0.01)
}

@Test func partialOutputFromAnInterruptedFinalizeIsRecovered() throws {
    let dir = try makeSession()
    try Data(repeating: 7, count: 1000).write(to: dir.appendingPathComponent("mix.m4a"))
    #expect(Finalizer.needsRecovery(dir))
    #expect(try Finalizer.run(dir).totalFrames == 144_000)
    #expect(!Finalizer.needsRecovery(dir))
}

@Test func tracksStartingAtDifferentHostTimesAreAlignedInTheMix() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("fin-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let s: UInt64 = 10_000_000_000
    var m = SessionManifest(appVersion: "t", startedAt: Date(), sessionStartNanos: s)
    m.sources = [
        SourceManifest(kind: .computer, uid: nil, name: "Computer audio", file: "computer audio.m4a", channels: 2, segments: [
            SegmentRecord(file: "computer audio.seg000.caf", startNanos: s, frames: 144_000, endNanos: s + 3_000_000_000, sourceRate: 48_000, sourceChannels: 2, reason: "start"),
        ], restarts: [], overruns: 0),
        SourceManifest(kind: .mic, uid: "u", name: "A", file: "mic - A.m4a", channels: 1, segments: [
            SegmentRecord(file: "mic - A.seg000.caf", startNanos: s + 1_000_000_000, frames: 48_000, endNanos: s + 2_000_000_000, sourceRate: 48_000, sourceChannels: 1, reason: "start"),
        ], restarts: [], overruns: 0),
    ]
    try m.save(to: dir)
    try writeCAF(dir.appendingPathComponent("computer audio.seg000.caf"), samples: [Float](repeating: 0, count: 144_000 * 2), channels: 2)
    try writeCAF(dir.appendingPathComponent("mic - A.seg000.caf"), samples: sine(frames: 48_000, channels: 1), channels: 1)
    let report = try Finalizer.run(dir)
    #expect(report.totalFrames == 144_000)
    #expect(report.gaps == [GapRecord(track: "mic - A", atFrame: 0, frames: 48_000)])
    let mix = dir.appendingPathComponent("mix.m4a")
    #expect(try rms(mix, from: 20_000, frames: 4_800) < 0.01)
    #expect(try rms(mix, from: 60_000, frames: 4_800) > 0.2)
    #expect(try rms(mix, from: 120_000, frames: 4_800) < 0.01)
}
```

- [ ] **Step 2: Run, expect compile failure**

Run: `scripts/test.sh`
Expected: FAIL, `cannot find 'Finalizer' in scope`.

- [ ] **Step 3: Write `Sources/DabberCore/Finalize/CAFSegment.swift`** (**verified** read path)

```swift
import AVFoundation

public final class CAFSegment: SegmentSource {
    public let frames: Int
    public let channels: Int
    private let file: AVAudioFile
    private let buffer: AVAudioPCMBuffer

    public init(url: URL) throws {
        file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: true)
        frames = Int(file.length)
        channels = Int(file.processingFormat.channelCount)
        buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 48_000)!
    }

    public func read(_ range: Range<Int>) throws -> [Float] {
        var out: [Float] = []
        out.reserveCapacity(range.count * channels)
        var pos = range.lowerBound
        while pos < range.upperBound {
            let n = min(48_000, range.upperBound - pos)
            file.framePosition = AVAudioFramePosition(pos)
            try file.read(into: buffer, frameCount: AVAudioFrameCount(n))
            let got = Int(buffer.frameLength)
            out.append(contentsOf: UnsafeBufferPointer(start: buffer.floatChannelData![0], count: got * channels))
            if got < n { out.append(contentsOf: repeatElement(0, count: (n - got) * channels)) }
            pos += n
        }
        return out
    }
}
```

- [ ] **Step 4: Write `Sources/DabberCore/Finalize/AACWriter.swift`** (**verified** settings and `close()`)

```swift
import AVFoundation

public enum FinalizeError: Error, CustomStringConvertible {
    case buffer
    case lengthMismatch(file: String, expected: Int, actual: Int)

    public var description: String {
        switch self {
        case .buffer: return "could not allocate pcm buffer"
        case .lengthMismatch(let file, let expected, let actual):
            return "\(file): wrote \(expected) frames, file reports \(actual)"
        }
    }
}

public final class AACWriter {
    public let url: URL
    public let channels: Int
    public private(set) var framesWritten = 0
    private let file: AVAudioFile
    private let format: AVAudioFormat

    public init(url: URL, channels: Int) throws {
        self.url = url
        self.channels = channels
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48_000.0,
            AVNumberOfChannelsKey: channels, AVEncoderBitRateKey: channels == 1 ? 96_000 : 160_000,
        ]
        file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: true)
        format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: AVAudioChannelCount(channels), interleaved: true)!
    }

    public func write(_ samples: [Float]) throws {
        let frames = samples.count / channels
        guard frames > 0 else { return }
        guard let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)) else {
            throw FinalizeError.buffer
        }
        buf.frameLength = AVAudioFrameCount(frames)
        samples.withUnsafeBufferPointer { buf.floatChannelData![0].update(from: $0.baseAddress!, count: frames * channels) }
        try file.write(from: buf)
        framesWritten += frames
    }

    public func closeAndVerify() throws {
        file.close()
        let actual = Int(try AVAudioFile(forReading: url).length)
        guard actual == framesWritten else {
            throw FinalizeError.lengthMismatch(file: url.lastPathComponent, expected: framesWritten, actual: actual)
        }
    }
}
```

- [ ] **Step 5: Write `Sources/DabberCore/Finalize/Finalizer.swift`**

```swift
import Foundation

public enum Finalizer {
    public static let chunkFrames = 48_000
    public static let mixFile = "mix.m4a"

    private struct Track {
        let base: String
        let channels: Int
        let reader: TimelineReader
        let plans: [FinalizePlan]
    }

    @discardableResult
    public static func run(_ dir: URL) throws -> FinalizeReport {
        var manifest = try SessionManifest.load(from: dir)
        var tracks: [Track] = []
        for source in manifest.sources {
            var present: [SegmentRecord] = []
            var files: [CAFSegment] = []
            for record in source.segments {
                guard let caf = try? CAFSegment(url: dir.appendingPathComponent(record.file)) else { continue }
                present.append(record)
                files.append(caf)
            }
            let plans = FinalizePlan.make(present, fileFrames: files.map(\.frames))
            let planned = Set(plans.map(\.file))
            let sources: [any SegmentSource] = zip(present, files).compactMap { record, caf in
                guard planned.contains(record.file) else { return nil }
                let plan = plans.first { $0.file == record.file }!
                return plan.resample ? DriftResampler(caf, targetFrames: plan.segment.frames) : caf
            }
            let placements = Timeline.place(plans.map(\.segment), sessionStartNanos: manifest.sessionStartNanos)
            tracks.append(Track(
                base: source.trackBase, channels: source.channels,
                reader: TimelineReader(placements: placements, sources: sources, channels: source.channels),
                plans: plans))
        }
        let total = tracks.map(\.reader.totalFrames).max() ?? 0
        let writers = try tracks.map { try AACWriter(url: dir.appendingPathComponent($0.base + ".m4a"), channels: $0.channels) }
        let mix = try AACWriter(url: dir.appendingPathComponent(mixFile), channels: 2)
        var start = 0
        while start < total {
            let range = start..<min(start + chunkFrames, total)
            var mono: [[Float]] = []
            var stereo: [[Float]] = []
            for (track, writer) in zip(tracks, writers) {
                let pcm = try track.reader.read(range)
                try writer.write(pcm)
                if track.channels == 1 { mono.append(pcm) } else { stereo.append(pcm) }
            }
            try mix.write(Mixer.mixToStereo(mono: mono, stereo: stereo))
            start = range.upperBound
        }
        for writer in writers { try writer.closeAndVerify() }
        try mix.closeAndVerify()
        var gaps: [GapRecord] = []
        var drift: [String: Double] = [:]
        var resampled: [String] = []
        for track in tracks {
            gaps += Timeline.gaps(track.reader.placements).map { GapRecord(track: track.base, atFrame: $0.atFrame, frames: $0.frames) }
            for plan in track.plans {
                drift[plan.file] = plan.driftMillis
                if plan.resample { resampled.append(plan.file) }
            }
        }
        let report = FinalizeReport(totalFrames: total, gaps: gaps, driftMillis: drift, resampled: resampled)
        manifest.finalize = report
        try manifest.save(to: dir)
        for name in try FileManager.default.contentsOfDirectory(atPath: dir.path) where name.hasSuffix(".caf") {
            try FileManager.default.removeItem(at: dir.appendingPathComponent(name))
        }
        return report
    }

    public static func needsRecovery(_ dir: URL) -> Bool {
        let fm = FileManager.default
        guard let manifest = try? SessionManifest.load(from: dir), manifest.finalize == nil,
              let names = try? fm.contentsOfDirectory(atPath: dir.path)
        else { return false }
        return names.contains { $0.hasSuffix(".caf") }
    }

    @discardableResult
    public static func recoverAll(root: URL, onError: (URL, Error) -> Void = { _, _ in }) throws -> [URL] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: root.path) else { return [] }
        var done: [URL] = []
        for name in names.sorted() {
            let dir = root.appendingPathComponent(name)
            guard needsRecovery(dir) else { continue }
            do {
                try run(dir)
                done.append(dir)
            } catch {
                onError(dir, error)
            }
        }
        return done
    }
}
```

- [ ] **Step 6: Run tests**

Run: `scripts/test.sh`
Expected: exit 0. If `recoveryFinalizesFoldersWithCAFsButNoMix` fails because `contentsOfDirectory` returns the two folders in a different order, the `sorted()` call is the fix, already in place.

- [ ] **Step 7: Commit**

```bash
git add Sources/DabberCore/Finalize/CAFSegment.swift Sources/DabberCore/Finalize/AACWriter.swift Sources/DabberCore/Finalize/Finalizer.swift Tests/DabberCoreTests/FinalizerTests.swift
git commit -m "feat: add finalizer rendering tracks and mix to aac with crash recovery"
```

---

### Task 10: Headless `--record` and the first hardware run

**Files:**
- Modify: `Sources/Dabber/Headless.swift`
- Create: `Sources/DabberCore/App/AppPaths.swift`

`--record [--computer-audio] [--mic <uid>]... --seconds N --out <root>` starts a session under `<root>` (default `~/Recordings/Dabber`), logs `SESSION <dir>`, one status line per second, then `STOPPED`, `FINALIZED ...`, `EXIT 0`. `--out` is the root, not the session folder, so headless and menu sessions look identical.

- [ ] **Step 1: Write `Sources/DabberCore/App/AppPaths.swift`**

```swift
import Foundation

public enum AppPaths {
    public static var recordingsRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Recordings/Dabber")
    }

    public static var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
    }
}
```

- [ ] **Step 2: Add `--record` to `Headless.dispatch`**

Add this case before `default:` (the spike cases stay until Task 13):

```swift
        case "--record":
            var specs: [SourceSpec] = []
            var seconds = 0.0
            var root = AppPaths.recordingsRoot
            var i = 1
            let devices = try inputDevices()
            while i < args.count {
                switch args[i] {
                case "--computer-audio":
                    specs.append(SourceSpec(kind: .computer, uid: nil, name: "Computer audio"))
                case "--mic":
                    i += 1
                    guard i < args.count else { return 64 }
                    let uid = args[i]
                    let name = devices.first { $0.uid == uid }?.name ?? uid
                    specs.append(SourceSpec(kind: .mic, uid: uid, name: name))
                case "--seconds":
                    i += 1
                    guard i < args.count, let s = Double(args[i]) else { return 64 }
                    seconds = s
                case "--out":
                    i += 1
                    guard i < args.count else { return 64 }
                    root = URL(fileURLWithPath: args[i])
                default:
                    log.line("unknown option \(args[i])")
                    return 64
                }
                i += 1
            }
            guard !specs.isEmpty, seconds > 0 else { return 64 }
            let recorder = SessionRecorder(root: root, appVersion: AppPaths.version)
            let dir = try recorder.start(specs: specs)
            log.line("SESSION \(dir.path)")
            let end = Date().addingTimeInterval(seconds)
            while Date() < end {
                Thread.sleep(forTimeInterval: 1)
                let status = recorder.status()
                let parts = status.sources.map { s in
                    "\(s.spec.name): \(s.status) \(String(format: "%.1f", s.levelDb)) dB" + (s.silent ? " SILENT" : "")
                }
                log.line("t=\(Int(status.elapsedSeconds)) \(status.phase) | " + parts.joined(separator: " | "))
                if status.phase != .recording {
                    log.line("ERROR recording stopped: \(status.lastError ?? "unknown")")
                    break
                }
            }
            guard let stopped = recorder.stop() ?? recorder.lastSessionDir else { return 1 }
            log.line("STOPPED \(stopped.path)")
            let report = try Finalizer.run(stopped)
            log.line("FINALIZED total=\(report.totalFrames) gaps=\(report.gaps.count) resampled=\(report.resampled.count)")
            return 0
```

- [ ] **Step 3: Build**

Run: `swift build && scripts/test.sh`
Expected: both exit 0.

- [ ] **Step 4: Computer audio run with a known sound**

Run:
```bash
scripts/build-app.sh
( sleep 2; afplay /System/Library/Sounds/Submarine.aiff; afplay /System/Library/Sounds/Submarine.aiff ) &
scripts/run-headless.sh "$PWD/build/rec1.log" --record --computer-audio --seconds 8 --out "$PWD/build/rec"
DIR=$(awk '/ SESSION /{sub(/.* SESSION /, ""); print}' build/rec1.log)
ls "$DIR"
ffprobe -v error -show_entries stream=codec_name,sample_rate,channels:format=duration -of default=nw=1 "$DIR/computer audio.m4a"
ffmpeg -hide_banner -nostats -i "$DIR/mix.m4a" -af astats=metadata=0:measure_perchannel=0:measure_overall=Peak_level -f null - 2>&1 | grep 'Peak level'
python3 -c "import json,sys; m=json.load(open(sys.argv[1])); print([ (s['file'], len(s['segments']), s['overruns'], s['restarts']) for s in m['sources']], m['finalize']['totalFrames'])" "$DIR/session.json"
```
Expected: log has per-second lines with `Computer audio: running`, then `STOPPED`, `FINALIZED total=... gaps=<0 or 1> resampled=0` (one leading gap at `atFrame` 0 under 100 ms is the source's start latency, padded with silence), `EXIT 0`. Folder contains exactly `computer audio.m4a`, `mix.m4a`, `session.json` (no `.caf`). ffprobe: `codec_name=aac`, `sample_rate=48000`, `channels=2`, duration 8.0 +/- 0.2. Peak level above -30 dB. One segment, 0 overruns, no restarts, `totalFrames` about 384000.

- [ ] **Step 5: Mic + computer audio run (HUMAN: wear the AirPods and say a few words for 10 s)**

Get the AirPods input UID from `scripts/run-headless.sh "$PWD/build/list.log" --list-inputs` (the line whose name is `AirPods`).

Run:
```bash
scripts/run-headless.sh "$PWD/build/rec2.log" --record --computer-audio --mic "<AirPods UID>" --seconds 10 --out "$PWD/build/rec"
DIR=$(awk '/ SESSION /{sub(/.* SESSION /, ""); print}' build/rec2.log)
ls "$DIR"
ffmpeg -hide_banner -nostats -i "$DIR/mic - AirPods.m4a" -af astats=metadata=0:measure_perchannel=0:measure_overall=RMS_level -f null - 2>&1 | grep 'RMS level'
```
Expected: the macOS microphone dialog appears once (the user allows it; rerun if the run ended before the grant). `mic - AirPods.m4a` exists, mono, RMS above -40 dB. Session JSON shows the mic segment `sourceRate` of 24000 or 48000 (whatever the AirPods reported). No `SILENT` marker after the first seconds while the user talks.

- [ ] **Step 6: Commit**

```bash
git add Sources/Dabber/Headless.swift Sources/DabberCore/App/AppPaths.swift
git commit -m "feat: add headless record command over the session recorder"
```

---

### Task 11: RecorderModel (@MainActor, testable over a fake engine)

**Files:**
- Create: `Sources/DabberCore/App/RecorderModel.swift`, `Tests/DabberCoreTests/RecorderModelTests.swift`

The model lives in `DabberCore` so it is tested from `DabberCoreTests` without testing the executable target. It depends on two small protocols (`RecordingEngine`, `DeviceCatalog`) and a finalize closure. Engine calls that touch hardware run in a detached task so the menu never blocks; while `start` runs, `tick()` skips the engine (the recorder holds its lock during a start that can take about 2 s, Spike 1). A session the engine stopped by itself (write error) is finalized from `tick()`. `defaultEnabledIDs` is the first-launch source set: Computer audio plus the system default input.

- [ ] **Step 1: Write the failing tests `Tests/DabberCoreTests/RecorderModelTests.swift`**

```swift
import Foundation
import Testing
@testable import DabberCore

private final class FakeEngine: RecordingEngine, @unchecked Sendable {
    var started: [[SourceSpec]] = []
    var phase: RecorderPhase = .idle
    var snapshots: [SourceSnapshot] = []
    var dir = URL(fileURLWithPath: "/tmp/fake-session")
    var lastSessionDir: URL?
    var startError: Error?

    func start(specs: [SourceSpec]) throws -> URL {
        if let startError { throw startError }
        started.append(specs)
        phase = .recording
        return dir
    }

    func stop() -> URL? {
        phase = .idle
        lastSessionDir = dir
        return dir
    }

    func status(at now: Date) -> RecorderStatus {
        RecorderStatus(phase: phase, elapsedSeconds: 61, sources: snapshots, sessionDir: phase == .recording ? dir : nil, lastError: nil)
    }
}

private struct FakeCatalog: DeviceCatalog {
    var devices: [InputDevice]
    func inputs() throws -> [InputDevice] { devices }
}

private let airpods = InputDevice(id: 1, uid: "ap", name: "AirPods")
private let usb = InputDevice(id: 2, uid: "usb", name: "USB")

@MainActor
private func model(_ engine: FakeEngine, enabled: Set<String> = ["computer"], finalized: @escaping @Sendable (URL) -> Void = { _ in }) -> RecorderModel {
    let m = RecorderModel(engine: engine, catalog: FakeCatalog(devices: [airpods, usb]), enabledIDs: enabled, persist: { _ in }, finalize: finalized)
    m.refreshDevices()
    return m
}

@MainActor @Test func rowsListComputerAudioThenDevices() {
    let m = model(FakeEngine())
    #expect(m.rows.map(\.id) == ["computer", "ap", "usb"])
    #expect(m.rows.map(\.enabled) == [true, false, false])
}

@MainActor @Test func startUsesEnabledAvailableRows() async {
    let e = FakeEngine()
    let m = model(e, enabled: ["computer", "ap", "gone"])
    await m.startStop()
    #expect(e.started == [[
        SourceSpec(kind: .computer, uid: nil, name: "Computer audio"),
        SourceSpec(kind: .mic, uid: "ap", name: "AirPods"),
    ]])
    #expect(m.phase == .recording)
}

@MainActor @Test func stopFinalizesAndRemembersTheSession() async {
    let e = FakeEngine()
    nonisolated(unsafe) var finalized: [URL] = []
    let m = model(e) { finalized.append($0) }
    await m.startStop()
    await m.startStop()
    #expect(e.phase == .idle)
    #expect(finalized == [e.dir])
    #expect(m.lastSessionDir == e.dir)
    #expect(!m.finalizing)
}

@MainActor @Test func sessionThatStoppedItselfIsFinalized() async {
    let e = FakeEngine()
    nonisolated(unsafe) var finalized: [URL] = []
    let m = model(e) { finalized.append($0) }
    await m.startStop()
    e.phase = .idle
    e.lastSessionDir = e.dir
    m.tick()
    #expect(m.finalizing)
    while m.finalizing { await Task.yield() }
    #expect(finalized == [e.dir])
    #expect(m.lastSessionDir == e.dir)
    m.tick()
    #expect(finalized == [e.dir])
}

@MainActor @Test func tickMapsStatusIntoRowsAndWarning() {
    let e = FakeEngine()
    let m = model(e, enabled: ["computer", "ap"])
    e.phase = .recording
    e.snapshots = [
        SourceSnapshot(spec: SourceSpec(kind: .computer, uid: nil, name: "Computer audio"), status: .running, levelDb: -12, silent: false),
        SourceSnapshot(spec: SourceSpec(kind: .mic, uid: "ap", name: "AirPods"), status: .restarting("nsrt"), levelDb: -70, silent: true),
    ]
    m.tick()
    #expect(m.elapsed == "1:01")
    #expect(m.rows[0].levelDb == -12)
    #expect(m.rows[1].status == .restarting("nsrt"))
    #expect(m.warning == "AirPods: no signal for 10 s; AirPods: restarting (nsrt)")
}

@MainActor @Test func startErrorIsShownNotThrown() async {
    let e = FakeEngine()
    e.startError = RecorderError.lowDisk(freeBytes: 5)
    let m = model(e)
    await m.startStop()
    #expect(m.phase == .idle)
    #expect(m.errorText?.contains("MB free") == true)
}

@MainActor @Test func missingDeviceStaysListedAsUnavailable() {
    let e = FakeEngine()
    let m = RecorderModel(engine: e, catalog: FakeCatalog(devices: [usb]), enabledIDs: ["ap"], persist: { _ in }, finalize: { _ in })
    m.refreshDevices()
    #expect(m.rows.map(\.id) == ["computer", "usb"])
    m.toggle("usb")
    #expect(m.rows[1].enabled)
}

@Test func elapsedFormatting() {
    #expect(RecorderModel.format(seconds: 0) == "0:00")
    #expect(RecorderModel.format(seconds: 65) == "1:05")
    #expect(RecorderModel.format(seconds: 3_723) == "1:02:03")
}

@Test func firstLaunchEnablesComputerAudioAndDefaultInput() {
    #expect(RecorderModel.defaultEnabledIDs(defaultInputUID: "ap") == ["computer", "ap"])
    #expect(RecorderModel.defaultEnabledIDs(defaultInputUID: nil) == ["computer"])
}
```

- [ ] **Step 2: Run, expect compile failure**

Run: `scripts/test.sh`
Expected: FAIL, `cannot find type 'RecordingEngine' in scope`.

- [ ] **Step 3: Write `Sources/DabberCore/App/RecorderModel.swift`**

```swift
import Foundation
import Observation

public protocol RecordingEngine: Sendable {
    func start(specs: [SourceSpec]) throws -> URL
    func stop() -> URL?
    func status(at now: Date) -> RecorderStatus
    var lastSessionDir: URL? { get }
}

extension SessionRecorder: RecordingEngine {
    public func start(specs: [SourceSpec]) throws -> URL { try start(specs: specs, at: Date()) }
}

public protocol DeviceCatalog: Sendable {
    func inputs() throws -> [InputDevice]
}

public struct LiveDeviceCatalog: DeviceCatalog {
    public init() {}
    public func inputs() throws -> [InputDevice] { try inputDevices() }
}

@MainActor @Observable
public final class RecorderModel {
    public struct Row: Identifiable, Equatable, Sendable {
        public let id: String
        public let name: String
        public var enabled: Bool
        public var levelDb: Double = -160
        public var status: SourceStatus?
        public var silent = false
    }

    nonisolated public static let computerID = "computer"

    nonisolated public static func defaultEnabledIDs(defaultInputUID: String?) -> Set<String> {
        Set([computerID] + (defaultInputUID.map { [$0] } ?? []))
    }

    public private(set) var rows: [Row] = []
    public private(set) var phase: RecorderPhase = .idle
    public private(set) var elapsed = "0:00"
    public private(set) var warning: String?
    public private(set) var errorText: String?
    public private(set) var lastSessionDir: URL?
    public private(set) var finalizing = false

    private let engine: any RecordingEngine
    private let catalog: any DeviceCatalog
    private let persist: @Sendable (Set<String>) -> Void
    private let finalize: @Sendable (URL) throws -> Void
    private var enabledIDs: Set<String>
    private var starting = false

    public init(
        engine: any RecordingEngine, catalog: any DeviceCatalog, enabledIDs: Set<String>,
        persist: @escaping @Sendable (Set<String>) -> Void,
        finalize: @escaping @Sendable (URL) throws -> Void = { try Finalizer.run($0) }
    ) {
        self.engine = engine
        self.catalog = catalog
        self.enabledIDs = enabledIDs
        self.persist = persist
        self.finalize = finalize
        lastSessionDir = engine.lastSessionDir
    }

    public var isRecording: Bool { phase != .idle }

    public func refreshDevices() {
        let devices = (try? catalog.inputs()) ?? []
        var next = [Row(id: Self.computerID, name: "Computer audio", enabled: enabledIDs.contains(Self.computerID))]
        next += devices.map { Row(id: $0.uid, name: $0.name, enabled: enabledIDs.contains($0.uid)) }
        for i in next.indices {
            if let old = rows.first(where: { $0.id == next[i].id }) {
                next[i].levelDb = old.levelDb
                next[i].status = old.status
                next[i].silent = old.silent
            }
        }
        rows = next
    }

    public func toggle(_ id: String) {
        guard let i = rows.firstIndex(where: { $0.id == id }) else { return }
        rows[i].enabled.toggle()
        if rows[i].enabled { enabledIDs.insert(id) } else { enabledIDs.remove(id) }
        persist(enabledIDs)
    }

    public func startStop() async {
        if isRecording {
            await stopAndFinalize()
        } else {
            await start()
        }
    }

    public func stopAndFinalize() async {
        finalizing = true
        let engine = self.engine
        guard let dir = await Task.detached(operation: { engine.stop() }).value else {
            finalizing = false
            return
        }
        await finalizeSession(dir)
    }

    public func tick(now: Date = Date()) {
        guard !starting else { return }
        let status = engine.status(at: now)
        let stoppedItself = phase == .recording && status.phase == .idle && !finalizing
        phase = status.phase
        elapsed = Self.format(seconds: status.phase == .idle ? 0 : status.elapsedSeconds)
        var notes: [String] = []
        for i in rows.indices {
            let snapshot = status.sources.first { rows[i].id == ($0.spec.kind == .computer ? Self.computerID : $0.spec.uid) }
            rows[i].levelDb = snapshot?.levelDb ?? -160
            rows[i].status = snapshot?.status
            rows[i].silent = snapshot?.silent ?? false
            guard let snapshot else { continue }
            if snapshot.silent { notes.append("\(rows[i].name): no signal for 10 s") }
            switch snapshot.status {
            case .restarting(let reason): notes.append("\(rows[i].name): restarting (\(reason))")
            case .waitingForDevice: notes.append("\(rows[i].name): waiting for device")
            case .failed(let why): notes.append("\(rows[i].name): failed (\(why))")
            case .running, .stopped: break
            }
        }
        if let error = status.lastError { notes.append("stopped: \(error)") }
        warning = notes.isEmpty ? nil : notes.joined(separator: "; ")
        if stoppedItself, let dir = engine.lastSessionDir {
            finalizing = true
            Task { await finalizeSession(dir) }
        }
    }

    nonisolated public static func format(seconds: Double) -> String {
        let s = Int(seconds)
        let h = s / 3600, m = s % 3600 / 60, r = s % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, r) : String(format: "%d:%02d", m, r)
    }

    private func finalizeSession(_ dir: URL) async {
        phase = .idle
        finalizing = true
        let finalize = self.finalize
        do {
            try await Task.detached { try finalize(dir) }.value
            errorText = nil
        } catch {
            errorText = "finalize failed: \(error)"
        }
        finalizing = false
        lastSessionDir = dir
        tick()
    }

    private func start() async {
        let specs = rows.filter(\.enabled).map { row in
            row.id == Self.computerID
                ? SourceSpec(kind: .computer, uid: nil, name: row.name)
                : SourceSpec(kind: .mic, uid: row.id, name: row.name)
        }
        let engine = self.engine
        starting = true
        do {
            _ = try await Task.detached { try engine.start(specs: specs) }.value
            errorText = nil
        } catch {
            errorText = "\(error)"
        }
        starting = false
        tick()
    }
}
```

- [ ] **Step 4: Run tests**

Run: `scripts/test.sh`
Expected: exit 0. If the compiler rejects `nonisolated(unsafe) var finalized` inside a test function, move it to a file-level `nonisolated(unsafe) private var finalized: [URL] = []` and reset it at the start of the test.

- [ ] **Step 5: Commit**

```bash
git add Sources/DabberCore/App/RecorderModel.swift Tests/DabberCoreTests/RecorderModelTests.swift
git commit -m "feat: add observable recorder model over the recording engine"
```

---

### Task 12: Menu bar window and app delegate (quit finalizes, recovery on launch)

**Files:**
- Modify: `Sources/Dabber/MenuApp.swift`, `Sources/DabberCore/CoreAudio/Devices.swift`
- Create: `Sources/Dabber/AppDelegate.swift`

No unit test: the view is a thin projection of `RecorderModel` (tested in Task 11). Checked by eye in Step 4. **verified** in a scratch package: `MenuBarExtra` with `.menuBarExtraStyle(.window)`, `@NSApplicationDelegateAdaptor`, `.terminateLater` + `reply(toApplicationShouldTerminate:)`, `Binding(get:set:)` rows, `ProgressView(value:)`.

- [ ] **Step 1: Append `defaultInputDeviceUID()` to `Sources/DabberCore/CoreAudio/Devices.swift`**

`kAudioHardwarePropertyDefaultInputDevice` (`AudioHardware.h`). Used only for the first-launch source set; nothing stored yet means first launch.

```swift
public func defaultInputDeviceUID() -> String? {
    guard let id = try? getValue(
        systemObject, address(kAudioHardwarePropertyDefaultInputDevice), default: AudioObjectID(kAudioObjectUnknown)),
        id != kAudioObjectUnknown
    else { return nil }
    return try? getString(id, address(kAudioDevicePropertyDeviceUID))
}
```

- [ ] **Step 2: Write `Sources/Dabber/AppDelegate.swift`**

```swift
import AppKit
import CoreAudio
import DabberCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    private static let enabledKey = "enabledSources"

    @MainActor static let model = RecorderModel(
        engine: SessionRecorder(root: AppPaths.recordingsRoot, appVersion: AppPaths.version),
        catalog: LiveDeviceCatalog(),
        enabledIDs: UserDefaults.standard.stringArray(forKey: enabledKey).map(Set.init)
            ?? RecorderModel.defaultEnabledIDs(defaultInputUID: defaultInputDeviceUID()),
        persist: { UserDefaults.standard.set(Array($0).sorted(), forKey: enabledKey) })

    private var timer: Timer?
    private var devices: PropertyWatcher?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let root = AppPaths.recordingsRoot
        Task.detached { _ = try? Finalizer.recoverAll(root: root) }
        Task { @MainActor in Self.model.refreshDevices() }
        timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { _ in
            Task { @MainActor in Self.model.tick() }
        }
        devices = try? PropertyWatcher(objects: [(systemObject, [kAudioHardwarePropertyDevices])]) { _, _ in
            Task { @MainActor in Self.model.refreshDevices() }
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        Task { @MainActor in
            if Self.model.isRecording { await Self.model.stopAndFinalize() }
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
```

- [ ] **Step 3: Replace `Sources/Dabber/MenuApp.swift`**

```swift
import AppKit
import DabberCore
import SwiftUI

struct MenuApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate

    var body: some Scene {
        MenuBarExtra {
            MenuContent(model: AppDelegate.model)
        } label: {
            Image(systemName: icon)
        }
        .menuBarExtraStyle(.window)
    }

    @MainActor private var icon: String {
        let model = AppDelegate.model
        if model.warning != nil { return "exclamationmark.triangle.fill" }
        return model.isRecording ? "record.circle.fill" : "waveform"
    }
}

struct MenuContent: View {
    let model: RecorderModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(model.rows) { row in
                HStack {
                    Toggle(row.name, isOn: Binding(get: { row.enabled }, set: { _ in model.toggle(row.id) }))
                        .disabled(model.isRecording)
                    Spacer()
                    Text(statusText(row)).font(.caption).foregroundStyle(.secondary)
                }
                ProgressView(value: max(0, min(1, (row.levelDb + 60) / 60)))
                    .tint(row.silent ? .orange : .accentColor)
            }
            Divider()
            HStack {
                Button(model.isRecording ? "Stop" : "Start") { Task { await model.startStop() } }
                    .disabled(model.finalizing || (!model.isRecording && !model.rows.contains(where: \.enabled)))
                Text(model.finalizing ? "Finalizing..." : model.elapsed).monospacedDigit()
            }
            if let warning = model.warning {
                Label(warning, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
            }
            if let error = model.errorText {
                Text(error).foregroundStyle(.red).font(.caption)
            }
            Divider()
            Button("Show in Finder") {
                if let dir = model.lastSessionDir { NSWorkspace.shared.activateFileViewerSelecting([dir]) }
            }
            .disabled(model.lastSessionDir == nil)
            Button("Quit") { NSApplication.shared.terminate(nil) }
        }
        .padding(12)
        .frame(width: 300)
    }

    private func statusText(_ row: RecorderModel.Row) -> String {
        switch row.status {
        case nil, .stopped: return ""
        case .running: return row.silent ? "no signal" : "recording"
        case .restarting(let reason): return "restarting (\(reason))"
        case .waitingForDevice: return "waiting for device"
        case .failed: return "failed"
        }
    }
}
```

- [ ] **Step 4: Build**

Run: `swift build && scripts/test.sh`
Expected: both exit 0. If `Image(systemName:)` inside the label does not refresh on model changes, wrap the label in a small `struct MenuLabel: View { let model: RecorderModel; var body: some View { Image(systemName: ...) } }` so the observation happens inside a view body; keep the icon rules.

- [ ] **Step 5: Launch and check by eye (HUMAN)**

Run: `defaults delete local.dabber.Dabber enabledSources; scripts/build-app.sh && open build/Dabber.app` (the `defaults delete` makes this a first launch; "does not exist" is fine).
The user: click the waveform icon in the menu bar. Expected: a small window with "Computer audio" and the current system default input (System Settings > Sound > Input) checked, every other input device unchecked, a level bar under each, Start, "0:00", "Show in Finder" (enabled if a headless session exists from Task 10), Quit. Check the AirPods if they are not the default input, press Start, talk for 20 s while some music plays, press Stop. Expected: the icon shows a red record symbol while recording, elapsed counts, the bars move, after Stop "Finalizing..." shows briefly, "Show in Finder" opens `~/Recordings/Dabber/<date>` containing `mix.m4a`, `mic - AirPods.m4a`, `computer audio.m4a`, `session.json`. Then: Start again, and while recording press Quit. Expected: the app quits after a moment and the new folder also has all three `.m4a` files and no `.caf`.

- [ ] **Step 6: Commit**

```bash
git add Sources/Dabber/MenuApp.swift Sources/Dabber/AppDelegate.swift Sources/DabberCore/CoreAudio/Devices.swift
git commit -m "feat: add menu bar window with sources, meters, start/stop and finalizing quit"
```

---

### Task 12b: Fall back to the default mic and warn when an enabled mic is missing

**Files:**
- Modify: `Sources/DabberCore/App/RecorderModel.swift`, `Sources/DabberCore/Engine/CaptureSource.swift`, `Sources/Dabber/AppDelegate.swift`, `Sources/Dabber/MenuApp.swift`, `Sources/Dabber/Headless.swift`
- Test: `Tests/DabberCoreTests/RecorderModelTests.swift`, `Tests/DabberCoreTests/CaptureSourceTests.swift`, `Tests/DabberCoreTests/FinalizerTests.swift`

Found in the human test of Task 12: Computer audio + AirPods enabled, AirPods disconnected, Start recorded Computer audio only and said nothing. Rows came only from `catalog.inputs()`, so the absent mic dropped out of the list and the specs, and the silence rule only covers running mics.

- [x] **Step 1: Failing tests** (fake catalog gains `defaultUID`)

`missingEnabledDeviceStaysListedAsNotConnected` (replaces `missingDeviceStaysListedAsUnavailable`), `missingEnabledMicFallsBackToDefaultInputAndWarns`, `presentEnabledMicNeedsNoFallback`, `noEnabledMicFallsBackToDefaultInput`, `noDefaultInputStartsAnywayAndWarns`, `enabledDeviceNamesArePersisted`; `startUsesEnabledAvailableRows` now also expects `gone not connected`. Red: rows lacked the absent device (index out of range crash), names never persisted.

Second round (waiting start): `startWithTheDeviceMissingWaitsThenRecordsWhenItAppears`, `wakeWhileWaitingKeepsWaiting` (CaptureSource), `absentMicWarningClearsOnceItConnects`, and the fallback/no-default/`startUsesEnabledAvailableRows` tests now expect the absent mics in the specs. Red: `start()` threw `device fake not present`; specs lacked the absent mics; the warning did not clear. `sourceThatNeverConnectedBecomesASilentFullLengthTrack` (Finalizer) passed on first run: it pins existing behaviour.

Third round (review): `unpluggedFallbackStaysListedWhileTheSessionRuns`, `startNoteListsOnlyMicsStillAbsent` (RecorderModel; the fake catalog becomes a class so a test can unplug a device), `deviceThatAppearsBeforeItsInputStreamIsRetried` (CaptureSource), `wakeWhileWaitingKeepsWaiting` now also expects no restart event. Red: the unplugged fallback row vanished and its note with it; the note kept listing a mic that had connected; `noInputStream` after `dev#` left the source failed; wake logged a `wake` restart. `sessionWithNoAudioAtAllFinalizesToEmptyFiles` (Finalizer) passed on first run: with total 0 the finalizer writes zero-length `.m4a` files that `closeAndVerify` accepts.

- [x] **Step 2: Implement**

- `DeviceCatalog.defaultInputUID()`; `LiveDeviceCatalog` returns `defaultInputDeviceUID()`.
- `Row.connected`. `refreshDevices()` appends every enabled id not in the catalog as a row with `connected: false`, named from the remembered map (the uid if never seen).
- Names: `[uid: name]` of enabled, present mics, pruned to `enabledIDs`, passed to a new `persistNames` closure; the app stores it in `UserDefaults` key `sourceNames` and passes it back as `names:` on launch.
- `CaptureSource.start()` and `resume()`: `SourceError.deviceMissing` from `openDevice()` sets `.waitingForDevice` instead of throwing / failing; the lifetime system watcher (`dev#`, `srst`) stays, so `devicesChanged()` opens the device when it appears (first segment reason `restart: device returned`). Other errors from `start()` still throw. `resume()` with the device absent sets `.waitingForDevice` without logging a `wake` restart.
- `devicesChanged()`: any other open error (e.g. `noInputStream` while the input stream is not ready yet) counts an attempt and goes through `scheduleRestart(after: retryDelay)`, so the existing two-attempt limit applies before `.failed`.
- Zero segments: a never-connected source keeps `segments: []` in `session.json`; the finalizer already renders it as a full-length silent `.m4a` (no placements, `TimelineReader` zero-fills), no gap records, mix unaffected. No finalizer change.
- `start()` refreshes devices and starts every enabled row, absent mics included (they wait for their device). The started mic specs (fallback included) are kept as `sessionMics` until the engine is idle; `refreshDevices()` lists each of them that disappears as a `(not connected)` row (unchecked if not enabled), so its level and `waiting for device` note stay visible; on idle the list is refreshed without them. No connected enabled mic (absent ones, or none enabled): add the catalog default input if it is present. Warning (shown first; `<names>` is recomputed each tick from the mics still absent; cleared when idle or once every absent mic reports a status other than `waitingForDevice`; while it shows, the absent rows' own `waiting for device` / `no signal` notes are suppressed): `<names> not connected — recording <default>`, `No microphone selected — recording <default>`, `No microphone available` (no default: starts anyway), or `<names> not connected` when another enabled mic is present.
- `MenuApp`: an absent row reads `<name> (not connected)`; the triangle icon already follows `model.warning`.

Headless `--record` does not use `RecorderModel`. It shares `CaptureSource.start()`, so it now checks each `--mic` uid against `inputDevices()` while parsing, before any source exists: `no device with uid <uid>`, exit 2. Checked: `.build/debug/Dabber --record --mic no-such-uid --seconds 1 --out /tmp/x` -> `EXIT 2`, no `/tmp/x`.

- [x] **Step 3: Verify**

`scripts/test.sh`, `swift build`, `scripts/build-app.sh`: exit 0.

---

### Task 13: Remove spike code, final hardware test (HUMAN)

**Files:**
- Delete: `Sources/DabberCore/Spike/CAFRecorder.swift`
- Modify: `Sources/Dabber/Headless.swift`

`--record` now covers what the spikes did (format and event facts land in `session.json`), so the spike recorder and its two commands go. `--list-inputs` stays.

- [ ] **Step 1: Delete the spike recorder and commands**

```bash
git rm Sources/DabberCore/Spike/CAFRecorder.swift
```

In `Sources/Dabber/Headless.swift` delete the whole `case "--spike-tap":` and `case "--spike-mic":` blocks and the `aggregateInputFormat` function.

- [ ] **Step 2: Build, test, rebuild the bundle**

Run: `swift build && scripts/test.sh && scripts/build-app.sh`
Expected: all exit 0. `grep -rn "CAFRecorder\|spike-" Sources` prints nothing.

- [ ] **Step 3: Commit**

```bash
git add Sources/Dabber/Headless.swift
git commit -m "chore: remove spike recorder and spike commands"
```

- [ ] **Step 4: Final real test (HUMAN, about 6 minutes)**

The user wears the AirPods. Run in Terminal, then follow the timeline; a second Terminal with `tail -f build/final.log` shows the seconds:

```bash
scripts/run-headless.sh "$PWD/build/final.log" --record --computer-audio --mic "<AirPods UID>" --seconds 300 --out "$PWD/build/rec"
```

1. 0:00-0:30: talk normally.
2. 0:30: in Safari open https://webcammictest.com/check-mic.html and allow the microphone. Keep talking.
3. 1:30: open Audio MIDI Setup (Spotlight: type "Audio MIDI Setup"), click "AirPods" in the left list, and in the Format menu on the right pick the other sample rate (if it shows 48,000 Hz pick 24,000 Hz, or the reverse). Keep talking.
4. 2:30: close the Safari mic tab. Play any YouTube clip for 30 s.
5. 3:30: put the AirPods in their case for 20 s, then wear them again (the mic disappears and comes back).
6. Until 5:00: talk again. Then wait for `EXIT 0`.

After it ends, run:

```bash
DIR=$(awk '/ SESSION /{sub(/.* SESSION /, ""); print}' build/final.log)
grep -c "restarting" build/final.log
python3 -c "
import json,sys; m=json.load(open(sys.argv[1]))
for s in m['sources']:
    print(s['file'], 'segments', [(x['reason'], x['sourceRate'], x['frames']) for x in s['segments']], 'restarts', s['restarts'], 'overruns', s['overruns'])
print('gaps', m['finalize']['gaps'], 'resampled', m['finalize']['resampled'], 'drift', m['finalize']['driftMillis'])
" "$DIR/session.json"
ffprobe -v error -show_entries format=duration -of default=nw=1 "$DIR/mix.m4a"
ffmpeg -hide_banner -nostats -i "$DIR/mic - AirPods.m4a" -af silencedetect=n=-60dB:d=5 -f null - 2>&1 | grep -E 'silence_(start|end)'
```

Expected and what to record in the reply to the user:
- `EXIT 0`; mix duration 300 +/- 1 s.
- The mic source has more than one segment: at least one with reason `restart: nsrt` (step 3) and one `restart: device returned` (step 5), each with the `sourceRate` in force at the time.
- Gaps on the mic track only around step 5 (about 20 s) and short ones (under 1 s) at each restart; no gaps on computer audio except one leading gap at `atFrame` 0 under 100 ms (start latency).
- Fewer than 5 restarts per source in `session.json`. More means a restart loop (for example, reconfiguration events fired by the restart itself, as seen 2 s after the IOProc stop in Spike 1 run 2): keep the folder and report the restart reasons and times.
- Silence detection on the mic file reports only the step 5 window; if it reports silence from step 2 or step 3 onwards, the switch during recording is not survived: keep the folder, do not delete anything, and report the segment list and the log lines around that time.
- The user listens to `mix.m4a` once: voice and the YouTube clip both audible, no speed change at the restart points.

- [ ] **Step 5: Record the outcome**

Append a short section "Final test 2026-09-23" to `docs/spikes/2026-09-23-spike1-airpods-switch.md` with: which restarts fired and their reasons, gap lengths, drift values, whether the format switch during recording was survived, overrun counts.

```bash
git add docs/spikes/2026-09-23-spike1-airpods-switch.md
git commit -m "docs: record the plan 1b final hardware test"
```

---

## After this plan

Part 1 is complete when Task 13 passes. Known gaps, deliberately left: sleep/wake is implemented but not exercised (no reproducible trigger short of closing the lid mid-call); a mic that keeps the same UID but changes channel count between segments is handled by the per-segment converter but not tested on hardware; restart events reach `session.json` only at `stop()`, so a crash loses them (segments and CAFs survive). Part 2 (settings, hotkey, launch at login, output folder; per-app capture for recording was dropped on 2026-09-23) starts from `RecorderModel` and `SessionRecorder` as they stand.
