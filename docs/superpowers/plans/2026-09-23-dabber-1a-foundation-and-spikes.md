# Dabber 1a: Foundation and Spikes Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A signed, runnable Dabber.app skeleton that proves (Spike 0) it can get the audio-capture permission and record computer audio through a process tap, (Spike 1) records what Core Audio reports when AirPods switch to the call profile, and ships the pure timeline and mixing logic with tests.

**Architecture:** One SwiftPM package. `DabberCore` library holds Core Audio helpers, spike recorders and pure model code. `Dabber` executable is both the menu bar app (no arguments) and a headless tool (`--list-inputs`, `--spike-tap`, `--spike-mic`) launched through `open -W` so TCC attributes it to Dabber. A shell script assembles and signs `build/Dabber.app` with a self-signed certificate.

**Tech Stack:** Swift 6.4 (Command Line Tools, no Xcode), SwiftPM, Swift Testing, CoreAudio (process taps, HAL IOProc), AudioToolbox (ExtAudioFile), SwiftUI MenuBarExtra, ffmpeg/ffprobe for checks.

Spec: `docs/superpowers/specs/2026-09-23-dabber-part1-design.md`.
Plan 1b (sources with restart, ring buffer, writers, finalizer, menu UI) is written after Task 7, from the Spike 1 findings.

## Ground rules for implementers

- Repo root: the repository root. Branch `main`. No remote. Never push.
- Commit messages: one line, `type: description`, no body, no trailers.
- Code: English, no comments unless the code cannot say it. KISS.
- Swift 6 language mode. Core Audio callbacks run off the main actor. Classes crossing into IOProc or listener
  blocks are `final class ...: @unchecked Sendable` and do not touch mutable state from two threads.
- The Swift spelling of ObjC/C imports below was written from the SDK headers, not compiled. If a name does not
  compile, open the header under `$(xcrun --show-sdk-path)/System/Library/Frameworks/CoreAudio.framework/Headers/`
  (`CATapDescription.h`, `AudioHardware.h`, `AudioHardwareTapping.h`) and use the imported spelling. Do not change
  behaviour.
- Tasks marked **HUMAN** need the user (password prompt, TCC dialog, AirPods). Stop there and report what the user must do.

## File structure

```
Package.swift
Resources/Info.plist
scripts/make-cert.sh          one-time self-signed "Dabber Dev" code signing identity
scripts/build-app.sh          swift build + bundle + codesign -> build/Dabber.app
scripts/run-headless.sh       open -W the bundle with args, then print the log file
Sources/DabberCore/CoreAudio/Property.swift     get/set helpers, CAError, fourCC
Sources/DabberCore/CoreAudio/Devices.swift      InputDevice, inputDevices(), processObject(pid:)
Sources/DabberCore/CoreAudio/IOProcRunner.swift device IOProc start/stop
Sources/DabberCore/CoreAudio/GlobalTap.swift    global tap excluding self + private aggregate
Sources/DabberCore/CoreAudio/PropertyEventLog.swift  wildcard property listener
Sources/DabberCore/Spike/CAFRecorder.swift      ExtAudioFileWriteAsync CAF writer (spike only)
Sources/DabberCore/Model/Segment.swift          Segment, Placement, place(), drift
Sources/DabberCore/Model/Mixer.swift            mixToStereo()
Sources/Dabber/main.swift                       argument dispatch
Sources/Dabber/Headless.swift                   headless commands
Sources/Dabber/MenuApp.swift                    placeholder MenuBarExtra
Tests/DabberCoreTests/SegmentTests.swift
Tests/DabberCoreTests/MixerTests.swift
Tests/DabberCoreTests/PropertyTests.swift
docs/spikes/2026-09-23-spike0-tap-permission.md
docs/spikes/2026-09-23-spike1-airpods-switch.md
```

---

### Task 1: Package skeleton and menu bar placeholder

**Files:**
- Create: `Package.swift`, `.gitignore`, `Sources/DabberCore/Model/Segment.swift` (empty stub), `Sources/Dabber/main.swift`, `Sources/Dabber/MenuApp.swift`, `Tests/DabberCoreTests/SegmentTests.swift` (smoke)

- [ ] **Step 1: Write `Package.swift`**

```swift
// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Dabber",
    platforms: [.macOS("26.0")],
    targets: [
        .target(name: "DabberCore"),
        .executableTarget(name: "Dabber", dependencies: ["DabberCore"]),
        .testTarget(name: "DabberCoreTests", dependencies: ["DabberCore"]),
    ]
)
```

- [ ] **Step 2: Write `.gitignore`**

```
.build/
build/
*.caf
```

- [ ] **Step 3: Write the smoke test `Tests/DabberCoreTests/SegmentTests.swift`**

```swift
import Testing
@testable import DabberCore

@Test func frameRateIs48k() {
    #expect(Timeline.rate == 48_000)
}
```

- [ ] **Step 4: Run it, expect a compile failure**

Run: `scripts/test.sh`
Expected: FAIL, `cannot find 'Timeline' in scope`.

- [ ] **Step 5: Write `Sources/DabberCore/Model/Segment.swift`**

```swift
public enum Timeline {
    public static let rate = 48_000
}
```

- [ ] **Step 6: Write `Sources/Dabber/MenuApp.swift`**

```swift
import SwiftUI

struct MenuApp: App {
    var body: some Scene {
        MenuBarExtra("Dabber", systemImage: "waveform") {
            Button("Quit") { NSApplication.shared.terminate(nil) }
        }
    }
}
```

- [ ] **Step 7: Write `Sources/Dabber/main.swift`**

```swift
import Foundation

let args = Array(CommandLine.arguments.dropFirst())
if args.isEmpty {
    MenuApp.main()
} else {
    exit(Headless.run(args))
}
```

and a temporary `Sources/Dabber/Headless.swift` so it compiles:

```swift
import Foundation

enum Headless {
    static func run(_ args: [String]) -> Int32 {
        FileHandle.standardError.write("unknown command: \(args.joined(separator: " "))\n".data(using: .utf8)!)
        return 64
    }
}
```

- [ ] **Step 8: Run tests and build**

Run: `scripts/test.sh && swift build`
Expected: `Test run with 1 test ... passed`, build exit 0.

- [ ] **Step 9: Commit**

```bash
git add Package.swift .gitignore Sources Tests
git commit -m "feat: add package skeleton with menu bar placeholder"
```

---

### Task 2: Signing identity and app bundle (HUMAN: keychain password)

**Files:**
- Create: `scripts/make-cert.sh`, `scripts/build-app.sh`, `scripts/run-headless.sh`, `Resources/Info.plist`

- [ ] **Step 1: Write `scripts/make-cert.sh`**

```bash
#!/bin/bash
set -euo pipefail
NAME="Dabber Dev"
if security find-identity -v -p codesigning | grep -q "$NAME"; then
  echo "identity '$NAME' already exists"
  exit 0
fi
while security delete-certificate -c "$NAME" >/dev/null 2>&1; do :; done
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
cat > "$T/cfg" <<EOF
[req]
distinguished_name=dn
x509_extensions=ext
prompt=no
[dn]
CN=$NAME
[ext]
basicConstraints=critical,CA:false
keyUsage=critical,digitalSignature
extendedKeyUsage=critical,codeSigning
EOF
openssl req -x509 -newkey rsa:2048 -nodes -keyout "$T/k.pem" -out "$T/c.pem" -days 3650 -config "$T/cfg"
openssl pkcs12 -export -inkey "$T/k.pem" -in "$T/c.pem" -out "$T/c.p12" -passout pass:dabber -name "$NAME"
security import "$T/c.p12" -k "$HOME/Library/Keychains/login.keychain-db" -P dabber -T /usr/bin/codesign
security add-trusted-cert -r trustRoot -p codeSign -k "$HOME/Library/Keychains/login.keychain-db" "$T/c.pem"
security find-identity -v -p codesigning | grep -q "$NAME"
echo "imported '$NAME'"
```

- [ ] **Step 2: Write `Resources/Info.plist`**

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>local.dabber.Dabber</string>
  <key>CFBundleName</key><string>Dabber</string>
  <key>CFBundleExecutable</key><string>Dabber</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>26.0</string>
  <key>LSUIElement</key><true/>
  <key>NSMicrophoneUsageDescription</key><string>Dabber records your microphone.</string>
  <key>NSAudioCaptureUsageDescription</key><string>Dabber records audio played by other apps.</string>
</dict>
</plist>
```

- [ ] **Step 3: Write `scripts/build-app.sh`**

```bash
#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release --product Dabber
APP=build/Dabber.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/Dabber "$APP/Contents/MacOS/Dabber"
cp Resources/Info.plist "$APP/Contents/Info.plist"
codesign --force --sign "Dabber Dev" "$APP"
codesign -d -r- "$APP" 2>&1 | grep designated
```

- [ ] **Step 4: Write `scripts/run-headless.sh`**

The first argument is the log path; the rest go to the app. `open -W` does not return the app's exit status, so
the app writes `EXIT <code>` as the last log line.

```bash
#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p "$(dirname "$1")"
LOG="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"; shift
rm -f "$LOG"
open -W -n build/Dabber.app --args --log "$LOG" "$@"
cat "$LOG"
tail -1 "$LOG" | grep -q ' EXIT 0$'
```

- [ ] **Step 5: `chmod +x scripts/*.sh`, then run `scripts/make-cert.sh` (HUMAN)**

Expected: `imported 'Dabber Dev'`, and `security find-identity -v -p codesigning` lists `Dabber Dev`. macOS asks
for the password to change trust settings (from `add-trusted-cert`); the user types it.
Fallback if `codesign` in Step 6 reports the identity as unusable: the user creates it by hand in Keychain Access >
Certificate Assistant > Create a Certificate, name `Dabber Dev`, Identity Type `Self Signed Root`, Certificate
Type `Code Signing`.

- [ ] **Step 6: Build the bundle**

Run: `scripts/build-app.sh`
Expected: a line starting with `designated =>` that contains `certificate leaf` and `identifier "local.dabber.Dabber"`, and does NOT contain `cdhash`.

- [ ] **Step 7: Launch the menu bar app once**

Run: `open build/Dabber.app` then `pgrep -x Dabber`
Expected: a pid. A waveform icon is in the menu bar (HUMAN confirms by eye). Quit it from its menu.

- [ ] **Step 8: Commit**

```bash
git add scripts Resources
git commit -m "build: add signing identity script and app bundle build"
```

---

### Task 3: Core Audio property helpers and input device listing

**Files:**
- Create: `Sources/DabberCore/CoreAudio/Property.swift`, `Sources/DabberCore/CoreAudio/Devices.swift`, `Tests/DabberCoreTests/PropertyTests.swift`
- Modify: `Sources/Dabber/Headless.swift`

- [ ] **Step 1: Write the failing tests**

```swift
import Testing
import CoreAudio
@testable import DabberCore

@Test func fourCCPrintsAsciiCodes() {
    #expect(fourCC(OSStatus(bitPattern: 0x7768_6F3F)) == "who?")
    #expect(fourCC(OSStatus(-50)) == "-50")
}

@Test func systemHasADefaultOutputDevice() throws {
    let id: AudioObjectID = try getValue(
        AudioObjectID(kAudioObjectSystemObject),
        address(kAudioHardwarePropertyDefaultOutputDevice),
        default: AudioObjectID(kAudioObjectUnknown))
    #expect(id != kAudioObjectUnknown)
    #expect(!(try getString(id, address(kAudioDevicePropertyDeviceUID))).isEmpty)
}

@Test func inputDevicesHaveUIDs() throws {
    let devices = try inputDevices()
    #expect(!devices.isEmpty)
    #expect(devices.allSatisfy { !$0.uid.isEmpty })
}

@Test func ownPidMapsToAProcessObject() throws {
    #expect(try processObject(pid: getpid()) != kAudioObjectUnknown)
}

@Test func deviceUIDRoundTrips() throws {
    let first = try #require(try inputDevices().first)
    #expect(try deviceID(uid: first.uid) == first.id)
    #expect(try deviceID(uid: "no-such-device") == kAudioObjectUnknown)
}
```

- [ ] **Step 2: Run, expect compile failure**

Run: `scripts/test.sh`
Expected: FAIL, `cannot find 'fourCC' in scope`.

- [ ] **Step 3: Write `Sources/DabberCore/CoreAudio/Property.swift`**

```swift
import CoreAudio

public struct CAError: Error, CustomStringConvertible {
    public let status: OSStatus
    public let op: String
    public var description: String { "\(op) failed: \(fourCC(status))" }
}

public func fourCC(_ value: OSStatus) -> String {
    let n = UInt32(bitPattern: value)
    let bytes = [24, 16, 8, 0].map { UInt8((n >> $0) & 0xFF) }
    guard bytes.allSatisfy({ $0 >= 32 && $0 < 127 }) else { return String(value) }
    return String(decoding: bytes, as: UTF8.self)
}

public func fourCC(_ selector: UInt32) -> String { fourCC(OSStatus(bitPattern: selector)) }

func check(_ status: OSStatus, _ op: String) throws {
    if status != noErr { throw CAError(status: status, op: op) }
}

public func address(
    _ selector: AudioObjectPropertySelector,
    scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
    element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain
) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
}

public func getValue<T>(_ object: AudioObjectID, _ addr: AudioObjectPropertyAddress, default initial: T) throws -> T {
    var a = addr
    var size = UInt32(MemoryLayout<T>.size)
    var value = initial
    try check(AudioObjectGetPropertyData(object, &a, 0, nil, &size, &value), "get \(fourCC(addr.mSelector))")
    return value
}

public func getArray<T>(_ object: AudioObjectID, _ addr: AudioObjectPropertyAddress, filler: T) throws -> [T] {
    var a = addr
    var size: UInt32 = 0
    try check(AudioObjectGetPropertyDataSize(object, &a, 0, nil, &size), "size \(fourCC(addr.mSelector))")
    var values = [T](repeating: filler, count: Int(size) / MemoryLayout<T>.stride)
    try check(AudioObjectGetPropertyData(object, &a, 0, nil, &size, &values), "get \(fourCC(addr.mSelector))")
    return values
}

public func getString(_ object: AudioObjectID, _ addr: AudioObjectPropertyAddress) throws -> String {
    var a = addr
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    var value: Unmanaged<CFString>?
    try check(AudioObjectGetPropertyData(object, &a, 0, nil, &size, &value), "get \(fourCC(addr.mSelector))")
    return value.map { $0.takeRetainedValue() as String } ?? ""
}
```

- [ ] **Step 4: Write `Sources/DabberCore/CoreAudio/Devices.swift`**

```swift
import CoreAudio

public struct InputDevice: Sendable, Equatable {
    public let id: AudioObjectID
    public let uid: String
    public let name: String
}

let systemObject = AudioObjectID(kAudioObjectSystemObject)

public func inputDevices() throws -> [InputDevice] {
    let ids = try getArray(systemObject, address(kAudioHardwarePropertyDevices), filler: AudioObjectID(0))
    return try ids.compactMap { id in
        let streams = try getArray(
            id, address(kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeInput), filler: AudioObjectID(0))
        guard !streams.isEmpty else { return nil }
        return InputDevice(
            id: id,
            uid: try getString(id, address(kAudioDevicePropertyDeviceUID)),
            name: try getString(id, address(kAudioObjectPropertyName)))
    }
}

public func processObject(pid: pid_t) throws -> AudioObjectID {
    var a = address(kAudioHardwarePropertyTranslatePIDToProcessObject)
    var p = pid
    var object = AudioObjectID(kAudioObjectUnknown)
    var size = UInt32(MemoryLayout<AudioObjectID>.size)
    try check(
        AudioObjectGetPropertyData(systemObject, &a, UInt32(MemoryLayout<pid_t>.size), &p, &size, &object),
        "translate pid")
    return object
}

public func deviceID(uid: String) throws -> AudioObjectID {
    var a = address(kAudioHardwarePropertyTranslateUIDToDevice)
    var cfUID = uid as CFString
    var id = AudioObjectID(kAudioObjectUnknown)
    var size = UInt32(MemoryLayout<AudioObjectID>.size)
    try withUnsafeMutablePointer(to: &cfUID) { q in
        try check(
            AudioObjectGetPropertyData(systemObject, &a, UInt32(MemoryLayout<CFString>.size), q, &size, &id),
            "translate uid")
    }
    return id
}
```

- [ ] **Step 5: Run tests**

Run: `scripts/test.sh`
Expected: all tests pass.

- [ ] **Step 6: Add `--list-inputs` and `--log` to `Sources/Dabber/Headless.swift`**

```swift
import CoreAudio
import Foundation
import DabberCore

enum Headless {
    static func run(_ raw: [String]) -> Int32 {
        var args = raw
        var log = Log(path: nil)
        if let i = args.firstIndex(of: "--log"), i + 1 < args.count {
            log = Log(path: args[i + 1])
            args.removeSubrange(i...(i + 1))
        }
        let code: Int32
        do {
            code = try dispatch(args, log)
        } catch {
            log.line("ERROR \(error)")
            code = 1
        }
        log.line("EXIT \(code)")
        return code
    }

    static func dispatch(_ args: [String], _ log: Log) throws -> Int32 {
        switch args.first {
        case "--list-inputs":
            for d in try inputDevices() { log.line("\(d.uid)\t\(d.name)") }
            return 0
        default:
            log.line("unknown command: \(args.joined(separator: " "))")
            return 64
        }
    }
}

final class Log: @unchecked Sendable {
    private let handle: FileHandle
    private let lock = NSLock()

    init(path: String?) {
        if let path {
            FileManager.default.createFile(atPath: path, contents: nil)
            handle = FileHandle(forWritingAtPath: path) ?? .standardError
        } else {
            handle = .standardOutput
        }
    }

    func line(_ s: String) {
        lock.lock(); defer { lock.unlock() }
        handle.write((String(format: "%.3f ", Date().timeIntervalSince1970) + s + "\n").data(using: .utf8)!)
    }
}
```

- [ ] **Step 7: Verify headless listing through the bundle**

Run: `scripts/build-app.sh && scripts/run-headless.sh "$PWD/build/list.log" --list-inputs`
Expected: one line per input device, including a line whose name is `AirPods` if they are connected, last line `EXIT 0`, script exit 0.

- [ ] **Step 8: Commit**

```bash
git add Sources Tests
git commit -m "feat: add core audio property helpers and input device listing"
```

---

### Task 4: Spike 0, global tap recorded to CAF (HUMAN: permission dialog)

**Files:**
- Create: `Sources/DabberCore/CoreAudio/IOProcRunner.swift`, `Sources/DabberCore/CoreAudio/GlobalTap.swift`, `Sources/DabberCore/Spike/CAFRecorder.swift`, `docs/spikes/2026-09-23-spike0-tap-permission.md`
- Modify: `Sources/Dabber/Headless.swift`

- [ ] **Step 1: Write `Sources/DabberCore/CoreAudio/IOProcRunner.swift`**

```swift
import CoreAudio
import Foundation

public final class IOProcRunner: @unchecked Sendable {
    public typealias Handler = @Sendable (UnsafePointer<AudioBufferList>, UnsafePointer<AudioTimeStamp>) -> Void

    private let device: AudioObjectID
    private var procID: AudioDeviceIOProcID?

    public init(device: AudioObjectID, handler: @escaping Handler) throws {
        self.device = device
        let queue = DispatchQueue(label: "dabber.ioproc", qos: .userInteractive)
        try check(
            AudioDeviceCreateIOProcIDWithBlock(&procID, device, queue) { _, input, inputTime, _, _ in
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

- [ ] **Step 2: Write `Sources/DabberCore/CoreAudio/GlobalTap.swift`**

```swift
import CoreAudio
import Foundation

public final class GlobalTap: @unchecked Sendable {
    public let tapID: AudioObjectID
    public let aggregateID: AudioObjectID
    public let format: AudioStreamBasicDescription

    public init() throws {
        let me = try processObject(pid: getpid())
        let excluded: [AudioObjectID] = me == kAudioObjectUnknown ? [] : [me]
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: excluded)
        description.uuid = UUID()
        description.isPrivate = true
        description.muteBehavior = .unmuted

        var tap = AudioObjectID(kAudioObjectUnknown)
        try check(AudioHardwareCreateProcessTap(description, &tap), "create process tap")
        tapID = tap

        let tapUID = try getString(tap, address(kAudioTapPropertyUID))
        format = try getValue(tap, address(kAudioTapPropertyFormat), default: AudioStreamBasicDescription())

        let config: [String: Any] = [
            kAudioAggregateDeviceUIDKey: "local.dabber.tap.\(UUID().uuidString)",
            kAudioAggregateDeviceNameKey: "Dabber Tap",
            kAudioAggregateDeviceIsPrivateKey: 1,
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: tapUID]],
        ]
        var aggregate = AudioObjectID(kAudioObjectUnknown)
        let status = AudioHardwareCreateAggregateDevice(config as CFDictionary, &aggregate)
        if status != noErr {
            AudioHardwareDestroyProcessTap(tap)
            throw CAError(status: status, op: "create aggregate")
        }
        aggregateID = aggregate
    }

    public func destroy() {
        AudioHardwareDestroyAggregateDevice(aggregateID)
        AudioHardwareDestroyProcessTap(tapID)
    }
}
```

- [ ] **Step 3: Write `Sources/DabberCore/Spike/CAFRecorder.swift`**

`ExtAudioFileWriteAsync` is safe to call from the IOProc after one priming call with zero frames from a normal
thread (ExtendedAudioFile.h). CAF cannot store a non-interleaved layout (`fmt?`), so the file is interleaved and
the client format is the device format; for non-interleaved input `mBytesPerFrame` is per channel buffer, so the
byte-derived frame count holds in both layouts. Only the IO queue calls `write` and `close()` runs after the runner
stopped, so the counters need no lock; `close()` returns `frames=<n> failedWrites=<k> firstError=<fourCC or none>`. Spike-only; Plan 1b replaces it with a ring buffer and writer thread.

```swift
import AudioToolbox
import Foundation

public final class CAFRecorder: @unchecked Sendable {
    private let file: ExtAudioFileRef
    private let bytesPerFrame: UInt32
    private var framesWritten: UInt64 = 0
    private var failedWrites = 0
    private var firstError: OSStatus = noErr

    public init(url: URL, format: AudioStreamBasicDescription) throws {
        var fileFormat = format
        if format.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0 {
            fileFormat.mFormatFlags &= ~kAudioFormatFlagIsNonInterleaved
            fileFormat.mBytesPerFrame = format.mBytesPerFrame * format.mChannelsPerFrame
            fileFormat.mBytesPerPacket = fileFormat.mBytesPerFrame
        }
        var ref: ExtAudioFileRef?
        try check(
            ExtAudioFileCreateWithURL(
                url as CFURL, kAudioFileCAFType, &fileFormat, nil, AudioFileFlags.eraseFile.rawValue, &ref),
            "create caf")
        file = ref!
        var client = format
        try check(
            ExtAudioFileSetProperty(
                file, kExtAudioFileProperty_ClientDataFormat,
                UInt32(MemoryLayout<AudioStreamBasicDescription>.size), &client),
            "set client format")
        bytesPerFrame = format.mBytesPerFrame
        try check(ExtAudioFileWriteAsync(file, 0, nil), "prime async write")
    }

    public func write(_ list: UnsafePointer<AudioBufferList>) {
        let frames = list.pointee.mBuffers.mDataByteSize / bytesPerFrame
        guard frames > 0 else { return }
        let status = ExtAudioFileWriteAsync(file, frames, list)
        if status == noErr {
            framesWritten += UInt64(frames)
        } else {
            failedWrites += 1
            if firstError == noErr { firstError = status }
        }
    }

    public func close() -> String {
        ExtAudioFileDispose(file)
        let error = firstError == noErr ? "none" : fourCC(firstError)
        return "frames=\(framesWritten) failedWrites=\(failedWrites) firstError=\(error)"
    }
}
```

- [ ] **Step 4: Add `--spike-tap <seconds> <out.caf>` to `Headless.dispatch`**

Add this case before `default:`:

```swift
        case "--spike-tap":
            guard args.count == 3, let seconds = Double(args[1]) else { return 64 }
            let tap = try GlobalTap()
            log.line("tap format: \(tap.format.mSampleRate) Hz, \(tap.format.mChannelsPerFrame) ch, flags \(tap.format.mFormatFlags)")
            log.line(try aggregateInputFormat(tap.aggregateID))
            let recorder = try CAFRecorder(url: URL(fileURLWithPath: args[2]), format: tap.format)
            let runner = try IOProcRunner(device: tap.aggregateID) { input, _ in recorder.write(input) }
            Thread.sleep(forTimeInterval: seconds)
            runner.stop()
            log.line("tap recorder: \(recorder.close())")
            tap.destroy()
            return 0
```

Add to `Headless`, after `dispatch`:

```swift
    static func aggregateInputFormat(_ aggregate: AudioObjectID) throws -> String {
        let streams = try getArray(
            aggregate, address(kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeInput), filler: AudioObjectID(0))
        guard let stream = streams.first else { return "aggregate input format: none" }
        let f = try getValue(stream, address(kAudioStreamPropertyVirtualFormat), default: AudioStreamBasicDescription())
        return "aggregate input format: \(f.mSampleRate) Hz \(f.mChannelsPerFrame) ch flags \(f.mFormatFlags)"
    }
```

- [ ] **Step 5: Build and run with a known sound playing (HUMAN: allow the permission dialog)**

Run:
```bash
scripts/build-app.sh
( sleep 2; afplay /System/Library/Sounds/Submarine.aiff; afplay /System/Library/Sounds/Submarine.aiff ) &
scripts/run-headless.sh "$PWD/build/tap.log" --spike-tap 8 "$PWD/build/tap.caf"
```
Expected: macOS shows a "Dabber would like to record audio from other apps" style dialog the first time; the user
allows it. Log shows `tap format: 48000.0 Hz, 2 ch ...` (rate may differ; record it), `aggregate input format: ...`,
`tap recorder: frames=... failedWrites=0 firstError=none` and `EXIT 0`.
If the dialog blocked the run, run the command again after allowing.

- [ ] **Step 6: Check the recording has signal**

Run: `ffprobe -v error -show_entries format=duration -of default=nw=1 build/tap.caf; ffmpeg -hide_banner -nostats -i build/tap.caf -af astats=metadata=0:measure_perchannel=0:measure_overall=Peak_level -f null - 2>&1 | grep 'Peak level'`
Expected: duration about 8 s, peak level above -30 dB. A peak of `-inf` means the tap got silence: record that
in the spike doc and stop; the permission or the tap description is wrong.

- [ ] **Step 7: Check the permission survives two rebuilds**

Run:
```bash
sqlite3 "$HOME/Library/Application Support/com.apple.TCC/TCC.db" "select service, client, auth_value from access where client like '%dabber%'"
touch Sources/Dabber/main.swift && scripts/build-app.sh && scripts/run-headless.sh "$PWD/build/tap2.log" --spike-tap 3 "$PWD/build/tap2.caf"
touch Sources/Dabber/main.swift && scripts/build-app.sh && scripts/run-headless.sh "$PWD/build/tap3.log" --spike-tap 3 "$PWD/build/tap3.caf"
```
Expected: a row `kTCCServiceAudioCapture|local.dabber.Dabber|2` (this service lives in the user TCC.db; the
Terminal has Full Disk Access, so the query works), and both reruns end with `EXIT 0` with no new dialog. If a dialog appears again after rebuild, record it; the signing
approach must change before Plan 1b.

- [ ] **Step 8: One 60 s run (spec requirement: async-write backlog and private aggregate stability)**

Run: `scripts/run-headless.sh "$PWD/build/tap60.log" --spike-tap 60 "$PWD/build/tap60.caf" && ffprobe -v error -show_entries format=duration -of default=nw=1 build/tap60.caf`
Expected: `EXIT 0`, duration 60 s within 0.1 s.

- [ ] **Step 9: Write `docs/spikes/2026-09-23-spike0-tap-permission.md`**

Record: tap format, whether the dialog appeared and its exact text, the TCC row (or its absence), whether the
grant survived rebuilds, peak level measured, any API spelling that differed from this plan.

- [ ] **Step 10: Commit**

```bash
git add Sources docs/spikes
git commit -m "feat: spike global process tap recording to caf"
```

---

### Task 5: Spike 1, AirPods call-profile switch (HUMAN: AirPods + Safari)

**Files:**
- Create: `Sources/DabberCore/CoreAudio/PropertyEventLog.swift`, `docs/spikes/2026-09-23-spike1-airpods-switch.md`
- Modify: `Sources/Dabber/Headless.swift`

- [ ] **Step 1: Write `Sources/DabberCore/CoreAudio/PropertyEventLog.swift`**

```swift
import CoreAudio
import Foundation

public final class PropertyEventLog: @unchecked Sendable {
    private var registrations: [(AudioObjectID, AudioObjectPropertyListenerBlock)] = []
    private let queue = DispatchQueue(label: "dabber.events")
    private static let wildcard = AudioObjectPropertyAddress(
        mSelector: kAudioObjectPropertySelectorWildcard,
        mScope: kAudioObjectPropertyScopeWildcard,
        mElement: kAudioObjectPropertyElementWildcard)

    public init(objects: [(AudioObjectID, String)], sink: @escaping @Sendable (String) -> Void) throws {
        for (object, label) in objects {
            let block: AudioObjectPropertyListenerBlock = { count, addresses in
                for i in 0..<Int(count) {
                    let a = addresses[i]
                    sink("\(label) \(fourCC(a.mSelector)) scope=\(fourCC(a.mScope)) el=\(a.mElement)")
                }
            }
            var addr = Self.wildcard
            try check(AudioObjectAddPropertyListenerBlock(object, &addr, queue, block), "add listener \(label)")
            registrations.append((object, block))
        }
    }

    public func remove() {
        for (object, block) in registrations {
            var addr = Self.wildcard
            AudioObjectRemovePropertyListenerBlock(object, &addr, queue, block)
        }
        registrations.removeAll()
    }
}
```

- [ ] **Step 2: Add `--spike-mic <uid> <out.caf>` to `Headless.dispatch`**

Opening the AirPods mic from Dabber itself may switch them to the call profile, so the mic IOProc runs only in the
middle of a fixed 95 s schedule. Phases (seconds from start), each announced in the log as `PHASE X`:
A 0-15 listeners and format polling only; B 15 mic IOProc starts; C 35 human opens the Safari mic test;
D 60 human closes that tab; E 75 mic IOProc stops, logging continues to 95 (switch back).
Watched objects: system, mic device, its input and output streams, the tap aggregate, the tap object. The tap is recorded for the
whole run. Tap and aggregate input formats are logged at start; formats of the mic input stream, mic output stream
and tap every second. A failure to start the mic recording in phase B is logged as `ERROR B <error>` and the run
continues. Each recorder's `close()` summary is logged as `tap recorder: ...` / `mic recorder: ...`.

```swift
        case "--spike-mic":
            guard args.count == 3 else { return 64 }
            let mic = try deviceID(uid: args[1])
            guard mic != kAudioObjectUnknown else { log.line("no device with uid \(args[1])"); return 2 }
            let inputs = try getArray(
                mic, address(kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeInput), filler: AudioObjectID(0))
            let outputs = try getArray(
                mic, address(kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeOutput), filler: AudioObjectID(0))
            guard let input = inputs.first else { log.line("device has no input stream"); return 2 }
            if inputs.count > 1 { log.line("WARNING \(inputs.count) input streams, recording the first only") }
            let format: (AudioObjectID?) -> String = { stream in
                guard let stream,
                      let f = try? getValue(stream, address(kAudioStreamPropertyVirtualFormat), default: AudioStreamBasicDescription())
                else { return "-" }
                return "\(f.mSampleRate) Hz \(f.mChannelsPerFrame) ch"
            }
            let tap = try GlobalTap()
            log.line("tap format: \(tap.format.mSampleRate) Hz, \(tap.format.mChannelsPerFrame) ch, flags \(tap.format.mFormatFlags)")
            log.line(try aggregateInputFormat(tap.aggregateID))
            var watched: [(AudioObjectID, String)] = [
                (systemObject, "system"), (mic, "mic"), (tap.aggregateID, "tap"), (tap.tapID, "tapobj"),
            ]
            watched += inputs.enumerated().map { ($0.element, "mic-in\($0.offset)") }
            watched += outputs.enumerated().map { ($0.element, "mic-out\($0.offset)") }
            let events = try PropertyEventLog(objects: watched) { log.line($0) }
            let tapRecorder = try CAFRecorder(url: URL(fileURLWithPath: args[2] + ".tap.caf"), format: tap.format)
            let tapRunner = try IOProcRunner(device: tap.aggregateID) { buffers, _ in tapRecorder.write(buffers) }
            var micRecorder: CAFRecorder?
            var micRunner: IOProcRunner?
            log.line("PHASE A")
            for second in 0..<95 {
                if second == 15 {
                    log.line("PHASE B")
                    var created: CAFRecorder?
                    do {
                        let recorder = try CAFRecorder(
                            url: URL(fileURLWithPath: args[2]),
                            format: getValue(input, address(kAudioStreamPropertyVirtualFormat), default: AudioStreamBasicDescription()))
                        created = recorder
                        micRunner = try IOProcRunner(device: mic) { buffers, _ in recorder.write(buffers) }
                        micRecorder = recorder
                    } catch {
                        log.line("ERROR B \(error)")
                        if let created { log.line("mic recorder: \(created.close())") }
                    }
                }
                if second == 35 { log.line("PHASE C") }
                if second == 60 { log.line("PHASE D") }
                if second == 75 {
                    log.line("PHASE E")
                    micRunner?.stop()
                    if let micRecorder { log.line("mic recorder: \(micRecorder.close())") }
                    micRunner = nil
                    micRecorder = nil
                }
                let tapFormat = (try? getValue(tap.tapID, address(kAudioTapPropertyFormat), default: AudioStreamBasicDescription()))
                    .map { "\($0.mSampleRate) Hz \($0.mChannelsPerFrame) ch" } ?? "-"
                log.line("t=\(second) in \(format(input)) | out \(format(outputs.first)) | tap \(tapFormat)")
                Thread.sleep(forTimeInterval: 1)
            }
            tapRunner.stop()
            events.remove()
            log.line("tap recorder: \(tapRecorder.close())")
            tap.destroy()
            return 0
```

`systemObject` is internal to DabberCore; make it `public let systemObject` in `Devices.swift`.

- [ ] **Step 3: Build, then run the scripted session twice (HUMAN)**

Get the AirPods UID from `build/list.log` (Task 3). The user wears the AirPods and talks the whole time in both runs.
The log prints `PHASE` lines; `tail -f build/mic.log` in a second terminal shows when to act.

Run 1, Dabber first:

```bash
scripts/build-app.sh
scripts/run-headless.sh "$PWD/build/mic.log" --spike-mic "<AirPods UID>" "$PWD/build/mic.caf"
```

1. At `PHASE C` (about 35 s): open https://webcammictest.com/check-mic.html in Safari and allow the mic.
2. Somewhere in C: play any YouTube clip in another Safari tab for a few seconds.
3. At `PHASE D` (about 60 s): close the mic test tab.

Run 2, Safari first: open the mic test page and allow the mic before starting, then

```bash
scripts/run-headless.sh "$PWD/build/mic2.log" --spike-mic "<AirPods UID>" "$PWD/build/mic2.caf"
```

and close the tab at `PHASE D`.

Expected: both logs have per-second format lines, event lines, `PHASE A` to `PHASE E`, last line `EXIT 0`. The
macOS microphone permission dialog appears the first time; the user allows it and the run is repeated.

- [ ] **Step 4: Analyse the recordings**

Run:
```bash
for f in build/mic.caf build/mic.caf.tap.caf build/mic2.caf build/mic2.caf.tap.caf; do
  echo "== $f"; ffprobe -v error -show_entries stream=sample_rate,channels:format=duration -of default=nw=1 "$f"
  ffmpeg -hide_banner -nostats -i "$f" -af silencedetect=n=-70dB:d=2 -f null - 2>&1 | grep -E 'silence_(start|end)'
done
for l in build/mic.log build/mic2.log; do echo "== $l"; awk '$2 == "PHASE" || $4 ~ /^scope=/ {print $2, $3}' "$l" | uniq -c | head -60; done
```
Expected: facts, not a pass/fail. Note in particular whether mic.caf goes silent or garbled after the switch
(it was opened with the pre-switch format; that is the failure we expect to reproduce).

- [ ] **Step 5: Write `docs/spikes/2026-09-23-spike1-airpods-switch.md`**

Record, for both runs: which phase triggered the switch and the switch back (Dabber's own IOProc, Safari, or both); input, output and tap formats per phase; which selectors fired on
which object (as fourCC) in what order; whether the mic IOProc kept delivering buffers; what the recordings sound
like at the switch; the recommended restart trigger set for Plan 1b, derived only from what fired.

- [ ] **Step 6: Commit**

```bash
git add Sources docs/spikes
git commit -m "feat: spike airpods call-profile switch logging"
```

---

### Task 6: Segment placement and drift (pure, TDD)

**Files:**
- Modify: `Sources/DabberCore/Model/Segment.swift`, `Tests/DabberCoreTests/SegmentTests.swift`

Model: every track is a list of segments already converted to 48 kHz. A segment knows the host time (ns) of its
first frame and its frame count. `place` maps segments onto the session timeline in frames. Gaps stay as gaps
(the writer pads zeros). If a segment starts before the previous one ended, its overlapping head is skipped.

- [ ] **Step 1: Write the failing tests (append to `SegmentTests.swift`)**

```swift
@Test func firstSegmentStartsAtItsOffset() {
    let s = [Segment(startNanos: 1_000_000_000 + 500_000_000, frames: 48_000)]
    #expect(Timeline.place(s, sessionStartNanos: 1_000_000_000) ==
            [Placement(segmentIndex: 0, destFrame: 24_000, skipFrames: 0, frames: 48_000)])
}

@Test func gapBetweenSegmentsIsKept() {
    let s = [
        Segment(startNanos: 0, frames: 48_000),
        Segment(startNanos: 2_000_000_000, frames: 4_800),
    ]
    let p = Timeline.place(s, sessionStartNanos: 0)
    #expect(p[1] == Placement(segmentIndex: 1, destFrame: 96_000, skipFrames: 0, frames: 4_800))
}

@Test func overlappingHeadIsSkipped() {
    let s = [
        Segment(startNanos: 0, frames: 48_000),
        Segment(startNanos: 900_000_000, frames: 9_600),
    ]
    let p = Timeline.place(s, sessionStartNanos: 0)
    #expect(p[1] == Placement(segmentIndex: 1, destFrame: 48_000, skipFrames: 4_800, frames: 4_800))
}

@Test func fullyOverlappedSegmentIsDropped() {
    let s = [
        Segment(startNanos: 0, frames: 48_000),
        Segment(startNanos: 100_000_000, frames: 480),
    ]
    #expect(Timeline.place(s, sessionStartNanos: 0).count == 1)
}

@Test func segmentBeforeSessionStartIsTrimmed() {
    let s = [Segment(startNanos: 0, frames: 48_000)]
    #expect(Timeline.place(s, sessionStartNanos: 500_000_000) ==
            [Placement(segmentIndex: 0, destFrame: 0, skipFrames: 24_000, frames: 24_000)])
}

@Test func driftIsMeasuredAgainstHostTime() {
    let s = Segment(startNanos: 0, frames: 48_000 * 3600 + 4_800, endNanos: 3_600_000_000_000)
    #expect(abs(Timeline.driftMillis(s) - 100) < 0.01)
}

@Test func driftWithoutEndIsZero() {
    #expect(Timeline.driftMillis(Segment(startNanos: 0, frames: 48_000)) == 0)
}
```

- [ ] **Step 2: Run, expect compile failure**

Run: `scripts/test.sh`
Expected: FAIL, `cannot find 'Segment' in scope`.

- [ ] **Step 3: Replace `Sources/DabberCore/Model/Segment.swift`**

`endNanos` is the host time right after the last frame, when known. Positive drift means the device delivered more
frames than host time says it should have.

```swift
public struct Segment: Equatable, Sendable, Codable {
    public let startNanos: UInt64
    public var frames: Int
    public var endNanos: UInt64?

    public init(startNanos: UInt64, frames: Int, endNanos: UInt64? = nil) {
        self.startNanos = startNanos
        self.frames = frames
        self.endNanos = endNanos
    }
}

public struct Placement: Equatable, Sendable {
    public let segmentIndex: Int
    public let destFrame: Int
    public let skipFrames: Int
    public let frames: Int
}

public enum Timeline {
    public static let rate = 48_000

    public static func frames(nanos: Int64) -> Int {
        Int((Double(nanos) * Double(rate) / 1e9).rounded())
    }

    public static func place(_ segments: [Segment], sessionStartNanos: UInt64) -> [Placement] {
        var result: [Placement] = []
        var cursor = 0
        for (i, s) in segments.enumerated() {
            let offset = frames(nanos: Int64(s.startNanos) - Int64(sessionStartNanos))
            let dest = max(offset, cursor)
            let skip = dest - offset
            let count = s.frames - skip
            guard count > 0 else { continue }
            result.append(Placement(segmentIndex: i, destFrame: dest, skipFrames: skip, frames: count))
            cursor = dest + count
        }
        return result
    }

    public static func driftMillis(_ s: Segment) -> Double {
        guard let end = s.endNanos, end > s.startNanos else { return 0 }
        let expected = Double(end - s.startNanos) * Double(rate) / 1e9
        return (Double(s.frames) - expected) / Double(rate) * 1000
    }
}
```

- [ ] **Step 4: Run tests**

Run: `scripts/test.sh`
Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/DabberCore/Model/Segment.swift Tests/DabberCoreTests/SegmentTests.swift
git commit -m "feat: add segment placement and drift measurement"
```

---

### Task 7: Stereo mixer (pure, TDD)

**Files:**
- Create: `Sources/DabberCore/Model/Mixer.swift`, `Tests/DabberCoreTests/MixerTests.swift`

Mic tracks are mono, computer audio is interleaved stereo. The mix is interleaved stereo, as long as the longest
input, each mono sample goes to both channels, sums are clamped to [-1, 1].

- [ ] **Step 1: Write the failing tests**

```swift
import Testing
@testable import DabberCore

@Test func monoGoesToBothChannels() {
    #expect(Mixer.mixToStereo(mono: [[0.5, -0.25]], stereo: []) == [0.5, 0.5, -0.25, -0.25])
}

@Test func stereoIsSummedWithMono() {
    #expect(Mixer.mixToStereo(mono: [[0.1]], stereo: [[0.2, 0.3]]) == [0.3, 0.4].map { Float($0) })
}

@Test func shorterInputsArePaddedWithSilence() {
    #expect(Mixer.mixToStereo(mono: [[0.5]], stereo: [[0, 0, 0.25, 0.25]]) == [0.5, 0.5, 0.25, 0.25])
}

@Test func positiveSumIsClamped() {
    #expect(Mixer.mixToStereo(mono: [[0.8], [0.8]], stereo: []) == [1, 1])
}

@Test func negativeSumIsClamped() {
    #expect(Mixer.mixToStereo(mono: [], stereo: [[-0.9, -0.9], [-0.9, -0.9]]) == [-1, -1])
}

@Test func emptyInputGivesEmptyMix() {
    #expect(Mixer.mixToStereo(mono: [], stereo: []).isEmpty)
}
```

Note: `stereoIsSummedWithMono` compares Float sums; if rounding bites, compare with a tolerance of 1e-6 instead
of changing the implementation.

- [ ] **Step 2: Run, expect compile failure**

Run: `scripts/test.sh`
Expected: FAIL, `cannot find 'Mixer' in scope`.

- [ ] **Step 3: Write `Sources/DabberCore/Model/Mixer.swift`**

```swift
public enum Mixer {
    public static func mixToStereo(mono: [[Float]], stereo: [[Float]]) -> [Float] {
        let frames = max(mono.map(\.count).max() ?? 0, stereo.map { $0.count / 2 }.max() ?? 0)
        var out = [Float](repeating: 0, count: frames * 2)
        for track in mono {
            for (i, s) in track.enumerated() {
                out[2 * i] += s
                out[2 * i + 1] += s
            }
        }
        for track in stereo {
            for (i, s) in track.prefix(track.count / 2 * 2).enumerated() { out[i] += s }
        }
        for i in out.indices { out[i] = min(1, max(-1, out[i])) }
        return out
    }
}
```

- [ ] **Step 4: Run tests**

Run: `scripts/test.sh`
Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/DabberCore/Model/Mixer.swift Tests/DabberCoreTests/MixerTests.swift
git commit -m "feat: add stereo mixer"
```

---

## After this plan

Plan 1b is written from `docs/spikes/*.md` and covers: ring buffer, per-segment `TrackWriter` with
`AVAudioConverter` to 48 kHz, `ComputerAudioSource` and `InputDeviceSource` with the restart trigger set Spike 1
found, `SessionRecorder` state machine, `Finalizer` (placement, gap padding, drift resample above 50 ms, mix,
AAC encode, crash recovery on launch), `session.json`, disk pre-check, sleep/wake, silence warning, menu UI with
level meters, headless `--record`. Also from the Task 2-3 review: `inputDevices()` must skip a device that fails
mid-read instead of aborting the list, and `getArray` must trim to the size returned by the second call.
