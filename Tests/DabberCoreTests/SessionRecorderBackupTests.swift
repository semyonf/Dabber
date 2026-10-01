import Foundation
import Synchronization
import Testing
@testable import DabberCore

private final class Calls: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String] = []
    private var made: [String: StubSource] = [:]
    var present = true
    var gate: DispatchSemaphore?
    var absent: Set<String> = []
    var failing = false

    func add(_ call: String) { lock.withLock { items.append(call) } }
    var all: [String] { lock.withLock { items } }
    var backupCalls: [String] { all.filter { $0.hasSuffix("(backup)") || $0.contains("(backup) ") } }
    func register(_ source: StubSource) { lock.withLock { made[source.writer.baseName] = source } }
    subscript(base: String) -> StubSource? { lock.withLock { made[base] } }
}

private struct StubFailure: Error {}

private final class StubSource: CaptureSource, @unchecked Sendable {
    let calls: Calls
    let current = Mutex<SourceStatus>(.stopped)

    init(spec: SourceSpec, dir: URL, baseName: String, calls: Calls) {
        self.calls = calls
        super.init(spec: spec, dir: dir, baseName: baseName, channels: spec.kind == .mic ? 1 : 2)
        calls.register(self)
    }

    override var status: SourceStatus { current.withLock { $0 } }
    func set(_ status: SourceStatus) { current.withLock { $0 = status } }

    override func start() throws {
        calls.add("start \(writer.baseName)")
        let backup = writer.baseName.hasSuffix("(backup)")
        if backup { calls.gate?.wait() }
        if backup, calls.failing {
            set(.failed("stub"))
            throw StubFailure()
        }
        if calls.absent.contains(writer.baseName) { return set(.waitingForDevice) }
        try writer.openSegment(format: int16Mono(rate: 48_000), reason: "start")
        set(.running)
        calls.add("started \(writer.baseName)")
    }

    override func pause() {
        calls.add("pause \(writer.baseName)")
        set(.stopped)
    }

    override func resume(reason: String) {
        calls.add("resume \(writer.baseName) \(reason)")
        set(.running)
    }

    override func stop() {
        calls.add("stop \(writer.baseName)")
        set(.stopped)
        writer.stop()
    }
}

private func recorder(_ calls: Calls, present: (@Sendable (String) -> Bool)? = nil) throws -> SessionRecorder {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("srb-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return SessionRecorder(
        root: root, appVersion: "t",
        makeSource: { spec, dir, base in StubSource(spec: spec, dir: dir, baseName: base, calls: calls) },
        freeBytes: { _ in 3_000_000_000 },
        devicePresent: present ?? { _ in calls.present })
}

private let mac = SourceSpec(kind: .computer, uid: nil, name: "Computer audio")
private let airpods = SourceSpec(kind: .mic, uid: "ap", name: "AirPods")
private let builtIn = SourceSpec(kind: .mic, uid: "bi", name: "MacBook Air Microphone")
private let usb = SourceSpec(kind: .mic, uid: "usb", name: "USB")
private let backupBase = "mic - MacBook Air Microphone (backup)"
private let usbBase = "mic - USB (backup)"
private let t0 = Date(timeIntervalSince1970: 1_900_000_000)

private func at(_ seconds: Double) -> Date { t0.addingTimeInterval(seconds) }

@Suite(.serialized) struct SessionRecorderBackupTests {
    @Test func aSessionThatNeverLosesAMicHasNoBackupTrack() throws {
        let calls = Calls()
        let r = try recorder(calls)
        let dir = try r.start(specs: [mac, airpods], backup: builtIn, at: t0)
        calls["computer audio"]!.set(.waitingForDevice)
        calls["mic - AirPods"]!.set(.restarting("nsrt"))
        #expect(r.status(at: at(0)).backup == .off)
        _ = r.stop()
        #expect(calls.backupCalls.isEmpty)
        #expect(try SessionManifest.load(from: dir).sources.map(\.file) == ["computer audio.m4a", "mic - AirPods.m4a"])
    }

    @Test func aLostMicStartsTheBackupInItsOwnTrackAndItsReturnPausesIt() throws {
        let calls = Calls()
        let r = try recorder(calls)
        let dir = try r.start(specs: [mac, airpods], backup: builtIn, at: t0)
        let ap = calls["mic - AirPods"]!
        ap.set(.waitingForDevice)
        _ = r.status(at: at(0))
        #expect(waitUntil { calls.all.contains("started \(backupBase)") })
        #expect(r.status(at: at(0)).backup == .recording)
        #expect(waitUntil { (try? SessionManifest.load(from: dir))?.sources.last?.segments.count == 1 })
        let m = try SessionManifest.load(from: dir)
        #expect(m.sources.map(\.file) == ["computer audio.m4a", "mic - AirPods.m4a", backupBase + ".m4a"])
        #expect(m.sources[2].uid == "bi")
        #expect(m.sources[2].name == "MacBook Air Microphone")
        #expect(m.sources[2].channels == 1)
        #expect(m.sources.map(\.backup) == [nil, nil, true])
        #expect(m.sources[1].segments.count == 1)
        #expect(r.status(at: at(0)).sources.map(\.spec.uid) == [nil, "ap", "bi"])
        ap.set(.running)
        _ = r.status(at: at(1))
        #expect(r.status(at: at(4)).backup == .off)
        #expect(waitUntil { calls.all.last == "pause \(backupBase)" })
        ap.set(.failed("x"))
        #expect(r.status(at: at(5)).backup == .recording)
        #expect(waitUntil { calls.all.last == "resume \(backupBase) backup" })
        ap.set(.restarting("nsrt"))
        #expect(r.status(at: at(6)).backup == .recording)
        _ = r.stop()
        #expect(calls.all.filter { $0 == "start \(backupBase)" }.count == 1)
        #expect(calls.all.contains("stop \(backupBase)"))
        #expect(try SessionManifest.load(from: dir).sources[2].segments.count == 1)
    }

    @Test func theBackupPausesOnlyAfterTheMicsHaveRunForAWhile() throws {
        let calls = Calls()
        let r = try recorder(calls)
        _ = try r.start(specs: [mac, airpods], backup: builtIn, at: t0)
        let ap = calls["mic - AirPods"]!
        ap.set(.waitingForDevice)
        _ = r.status(at: at(0))
        #expect(waitUntil { calls[backupBase]?.status == .running })
        ap.set(.running)
        #expect(r.status(at: at(1)).backup == .recording)
        #expect(r.status(at: at(2)).backup == .recording)
        ap.set(.waitingForDevice)
        #expect(r.status(at: at(2.5)).backup == .recording)
        ap.set(.running)
        #expect(r.status(at: at(3)).backup == .recording)
        #expect(r.status(at: at(5)).backup == .recording)
        #expect(r.status(at: at(5.6)).backup == .off)
        #expect(waitUntil { calls.all.last == "pause \(backupBase)" })
        #expect(calls.backupCalls == ["start \(backupBase)", "started \(backupBase)", "pause \(backupBase)"])
        _ = r.stop()
    }

    @Test func aMicAbsentAtRecordStartsTheBackupOnlyAfterItHasRun() throws {
        let calls = Calls()
        calls.absent = ["mic - AirPods"]
        let r = try recorder(calls)
        _ = try r.start(specs: [mac, airpods], backup: builtIn, at: t0)
        #expect(r.status(at: at(0)).backup == .off)
        #expect(r.status(at: at(5)).backup == .off)
        let ap = calls["mic - AirPods"]!
        ap.set(.running)
        #expect(r.status(at: at(6)).backup == .off)
        #expect(calls.backupCalls.isEmpty)
        ap.set(.waitingForDevice)
        _ = r.status(at: at(7))
        #expect(waitUntil { calls[backupBase]?.status == .running })
        #expect(r.status(at: at(7)).backup == .recording)
        _ = r.stop()
    }

    @Test func anAbsentBackupIsReportedAndStartsOnceItAppears() throws {
        let calls = Calls()
        calls.present = false
        let r = try recorder(calls)
        let dir = try r.start(specs: [mac, airpods], backup: builtIn, at: t0)
        calls["mic - AirPods"]!.set(.waitingForDevice)
        #expect(waitUntil { r.status(at: at(0)).backup == .missing })
        #expect(r.status(at: at(1)).sources.count == 2)
        #expect(try SessionManifest.load(from: dir).sources.count == 2)
        calls.present = true
        #expect(r.status(at: at(1.5)).backup == .missing)
        _ = r.status(at: at(2))
        #expect(waitUntil { calls[backupBase]?.status == .running })
        #expect(r.status(at: at(2)).backup == .recording)
        calls[backupBase]!.set(.waitingForDevice)
        #expect(r.status(at: at(2)).backup == .missing)
        calls[backupBase]!.set(.failed("boom"))
        #expect(r.status(at: at(2)).backup == .failed("boom"))
        _ = r.stop()
    }

    @Test func aSlowPresenceCheckDoesNotBlockStatus() throws {
        let calls = Calls()
        let gate = DispatchSemaphore(value: 0)
        defer { gate.signal() }
        let r = try recorder(calls, present: { _ in
            _ = gate.wait(timeout: .now() + 2)
            return true
        })
        _ = try r.start(specs: [mac, airpods], backup: builtIn, at: t0)
        calls["mic - AirPods"]!.set(.waitingForDevice)
        let begin = Date()
        _ = r.status(at: at(0))
        _ = r.status(at: at(0.2))
        #expect(Date().timeIntervalSince(begin) < 1)
        gate.signal()
        #expect(waitUntil { calls[backupBase]?.status == .running })
        _ = r.stop()
    }

    @Test func aBackupThatIsAlreadyRecordedIsIgnored() throws {
        let calls = Calls()
        let r = try recorder(calls)
        _ = try r.start(specs: [mac, airpods, builtIn], backup: builtIn, at: t0)
        calls["mic - AirPods"]!.set(.waitingForDevice)
        #expect(r.status(at: at(0)).backup == .off)
        _ = r.stop()
        #expect(calls.backupCalls.isEmpty)
    }

    @Test func aBackupThatNeverRecordedIsLeftOutOfTheSession() throws {
        let calls = Calls()
        calls.failing = true
        let r = try recorder(calls)
        let dir = try r.start(specs: [mac, airpods], backup: builtIn, at: t0)
        calls["mic - AirPods"]!.set(.waitingForDevice)
        _ = r.status(at: at(0))
        #expect(waitUntil { r.status(at: at(0)).backup == .failed("stub") })
        _ = r.stop()
        #expect(try SessionManifest.load(from: dir).sources.map(\.file) == ["computer audio.m4a", "mic - AirPods.m4a"])
    }

    @Test func wakeResumesTheBackupOnlyWhileItIsInUse() throws {
        let calls = Calls()
        let r = try recorder(calls)
        _ = try r.start(specs: [mac, airpods], backup: builtIn, at: t0)
        let ap = calls["mic - AirPods"]!
        ap.set(.waitingForDevice)
        _ = r.status(at: at(0))
        #expect(waitUntil { calls[backupBase]?.status == .running })
        ap.set(.running)
        _ = r.status(at: at(1))
        _ = r.status(at: at(4))
        #expect(waitUntil { calls.all.last == "pause \(backupBase)" })
        r.willSleep()
        r.didWake()
        #expect(calls.all.contains("resume mic - AirPods wake"))
        ap.set(.waitingForDevice)
        _ = r.status(at: at(5))
        #expect(waitUntil { calls.all.last == "resume \(backupBase) backup" })
        #expect(!calls.all.contains("resume \(backupBase) wake"))
        r.willSleep()
        r.didWake()
        #expect(waitUntil { calls.all.last == "resume \(backupBase) wake" })
        #expect(calls.all.filter { $0 == "pause \(backupBase)" }.count == 2)
        _ = r.stop()
    }

    @Test func sleepDuringABackupStartPausesTheBackupAfterTheStart() throws {
        let calls = Calls()
        let gate = DispatchSemaphore(value: 0)
        calls.gate = gate
        defer { gate.signal() }
        let r = try recorder(calls)
        _ = try r.start(specs: [mac, airpods], backup: builtIn, at: t0)
        calls["mic - AirPods"]!.set(.waitingForDevice)
        _ = r.status(at: at(0))
        #expect(waitUntil { calls.all.contains("start \(backupBase)") })
        r.willSleep()
        gate.signal()
        #expect(waitUntil { calls.backupCalls.last == "pause \(backupBase)" })
        #expect(calls.backupCalls == ["start \(backupBase)", "started \(backupBase)", "pause \(backupBase)"])
        #expect(calls[backupBase]?.status == .stopped)
        r.didWake()
        #expect(waitUntil { calls.backupCalls.last == "resume \(backupBase) wake" })
        _ = r.stop()
    }

    @Test func stopDuringABackupStartStopsTheBackupToo() throws {
        let calls = Calls()
        let gate = DispatchSemaphore(value: 0)
        calls.gate = gate
        defer { gate.signal() }
        let r = try recorder(calls)
        _ = try r.start(specs: [mac, airpods], backup: builtIn, at: t0)
        calls["mic - AirPods"]!.set(.waitingForDevice)
        _ = r.status(at: at(0))
        #expect(waitUntil { calls.all.contains("start \(backupBase)") })
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            _ = r.stop()
            done.signal()
        }
        #expect(waitUntil { r.status(at: at(0)).phase == .stopping })
        gate.signal()
        #expect(done.wait(timeout: .now() + 3) == .success)
        #expect(calls.backupCalls.last == "stop \(backupBase)")
        #expect(calls[backupBase]?.status == .stopped)
    }

    @Test func aBackupChosenWhileInactiveIsUsedAtTheNextLoss() throws {
        let calls = Calls()
        let r = try recorder(calls)
        let dir = try r.start(specs: [mac, airpods], backup: builtIn, at: t0)
        r.setBackup(usb)
        calls["mic - AirPods"]!.set(.waitingForDevice)
        _ = r.status(at: at(0))
        #expect(waitUntil { calls.all.contains("started \(usbBase)") })
        #expect(r.status(at: at(0)).backup == .recording)
        _ = r.stop()
        #expect(calls[backupBase] == nil)
        #expect(try SessionManifest.load(from: dir).sources.map(\.file).last == usbBase + ".m4a")
    }
}

private final class DeviceFake: CaptureSource, @unchecked Sendable {
    let present = Atomic<Bool>(true)
    let failures = Atomic<Int>(0)
    let openMillis = Atomic<Int>(0)
    let forced = Mutex<SourceStatus?>(nil)

    override func openDevice() throws -> OpenedDevice {
        Thread.sleep(forTimeInterval: Double(openMillis.load(ordering: .relaxed)) / 1000)
        guard present.load(ordering: .relaxed) else { throw SourceError.deviceMissing("fake") }
        if failures.load(ordering: .relaxed) > 0 {
            failures.wrappingSubtract(1, ordering: .relaxed)
            throw SourceError.noInputStream("fake")
        }
        return OpenedDevice(device: 42, format: int16Mono(rate: 48_000), watched: [(42, .device)])
    }

    override func deviceIsPresent() -> Bool { present.load(ordering: .relaxed) }
    override var status: SourceStatus { forced.withLock { $0 } ?? super.status }
    func force(_ status: SourceStatus?) { forced.withLock { $0 = status } }
}

private final class Devices: Sendable {
    let made = Mutex<[String: DeviceFake]>([:])
    let backupFailures: Int
    init(backupFailures: Int = 0) { self.backupFailures = backupFailures }
    subscript(base: String) -> DeviceFake? { made.withLock { $0[base] } }
}

private let backupDevice = "mic - Built-in (backup)"

private func deviceRecorder(_ devices: Devices) throws -> SessionRecorder {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("srd-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let hooks = CaptureHooks(startIO: { _, _ in {} }, watch: { _, _ in {} })
    let r = SessionRecorder(
        root: root, appVersion: "t",
        makeSource: { spec, dir, base in
            let s = DeviceFake(spec: spec, dir: dir, baseName: base, channels: 1, hooks: hooks)
            s.retryDelay = 0.3
            if base == backupDevice { s.failures.store(devices.backupFailures, ordering: .relaxed) }
            devices.made.withLock { $0[base] = s }
            return s
        },
        freeBytes: { _ in 3_000_000_000 }, devicePresent: { _ in true })
    _ = try r.start(specs: [airpods], backup: SourceSpec(kind: .mic, uid: "bi", name: "Built-in"), at: t0)
    return r
}

private func pausedBackup(_ r: SessionRecorder, _ devices: Devices) throws -> (DeviceFake, DeviceFake) {
    let ap = try #require(devices["mic - AirPods"])
    ap.force(.waitingForDevice)
    _ = r.status(at: at(0))
    #expect(waitUntil { devices[backupDevice]?.status == .running })
    let b = try #require(devices[backupDevice])
    ap.force(nil)
    _ = r.status(at: at(1))
    #expect(r.status(at: at(4)).backup == .off)
    #expect(waitUntil { b.status == .stopped })
    return (ap, b)
}

private func polls(_ r: SessionRecorder, at now: Date, for seconds: Double, until done: () -> Bool = { false })
    -> [(BackupState, SourceStatus)] {
    var seen: [(BackupState, SourceStatus)] = []
    let end = Date().addingTimeInterval(seconds)
    while Date() < end, !done() {
        seen.append((r.status(at: now).backup, r.status(at: now).sources.last!.status))
        Thread.sleep(forTimeInterval: 0.01)
    }
    return seen
}

@Suite(.serialized) struct SessionRecorderBackupDeviceTests {
    @Test func aBackupThatFailsAfterItRanIsNotReportedAsRecordingWhileItRetries() throws {
        let devices = Devices()
        let r = try deviceRecorder(devices)
        let (ap, b) = try pausedBackup(r, devices)
        let why = "device fake has no input stream"
        b.failures.store(3, ordering: .relaxed)
        ap.force(.waitingForDevice)
        _ = r.status(at: at(5))
        #expect(waitUntil { b.status == .failed(why) })
        #expect(r.status(at: at(5)).backup == .failed(why))
        _ = r.status(at: at(7.5))
        let seen = polls(r, at: at(7.5), for: 3) { b.status == .running }
        #expect(seen.contains { $0.1 == .restarting("backup") })
        #expect(!seen.contains { $0.0 == .recording && $0.1 != .running })
        #expect(waitUntil { r.status(at: at(7.5)).backup == .recording })
        #expect(b.status == .running)
        _ = r.stop()
    }

    @Test func aResumingBackupIsNotReportedMissing() throws {
        let devices = Devices()
        let r = try deviceRecorder(devices)
        let (ap, b) = try pausedBackup(r, devices)
        b.openMillis.store(300, ordering: .relaxed)
        ap.force(.waitingForDevice)
        _ = r.status(at: at(5))
        let seen = polls(r, at: at(5), for: 1)
        #expect(!seen.contains { $0.0 == .missing })
        #expect(b.status == .running)
        r.willSleep()
        #expect(waitUntil { b.status == .stopped })
        r.didWake()
        let woke = polls(r, at: at(5), for: 1)
        #expect(!woke.contains { $0.0 == .missing })
        #expect(b.status == .running)
        _ = r.stop()
    }

    @Test func theBackupPausesAndResumesThroughTheSourceAndIsMissingWhenAbsentOnResume() throws {
        let devices = Devices()
        let r = try deviceRecorder(devices)
        let ap = devices["mic - AirPods"]!
        ap.force(.waitingForDevice)
        _ = r.status(at: at(0))
        #expect(waitUntil { devices[backupDevice]?.status == .running })
        let b = try #require(devices[backupDevice])
        #expect(r.status(at: at(0)).backup == .recording)
        ap.force(nil)
        _ = r.status(at: at(1))
        #expect(r.status(at: at(4)).backup == .off)
        #expect(waitUntil { b.status == .stopped })
        ap.force(.waitingForDevice)
        _ = r.status(at: at(5))
        #expect(waitUntil { b.writer.segments.map(\.reason) == ["start", "restart: backup"] })
        #expect(b.status == .running)
        #expect(r.status(at: at(5)).backup == .recording)
        ap.force(nil)
        _ = r.status(at: at(6))
        #expect(r.status(at: at(9)).backup == .off)
        #expect(waitUntil { b.status == .stopped })
        b.present.store(false, ordering: .relaxed)
        ap.force(.waitingForDevice)
        _ = r.status(at: at(10))
        #expect(waitUntil { r.status(at: at(10)).backup == .missing })
        let dir = try #require(r.stop())
        let m = try SessionManifest.load(from: dir)
        #expect(m.sources.last?.segments.map(\.reason) == ["start", "restart: backup"])
        #expect(m.sources.last?.restarts.map(\.reason) == ["backup"])
    }

    @Test func aBackupWhoseStartFailedIsRetriedAndNotReportedAsRecording() throws {
        let devices = Devices(backupFailures: 2)
        let r = try deviceRecorder(devices)
        let ap = devices["mic - AirPods"]!
        let why = "device fake has no input stream"
        ap.force(.waitingForDevice)
        _ = r.status(at: at(0))
        #expect(waitUntil { r.status(at: at(0)).backup == .failed(why) })
        ap.force(nil)
        _ = r.status(at: at(1))
        #expect(r.status(at: at(4)).backup == .off)
        ap.force(.waitingForDevice)
        _ = r.status(at: at(5))
        #expect(waitUntil { devices[backupDevice]!.failures.load(ordering: .relaxed) == 0 })
        #expect(waitUntil { r.status(at: at(5)).backup == .failed(why) })
        #expect(r.status(at: at(6)).backup == .failed(why))
        _ = r.status(at: at(7.5))
        #expect(waitUntil { r.status(at: at(7.5)).backup == .recording })
        #expect(devices[backupDevice]!.status == .running)
        _ = r.stop()
    }
}
