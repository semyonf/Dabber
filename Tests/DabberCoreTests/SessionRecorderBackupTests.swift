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

    func add(_ call: String) { lock.withLock { items.append(call) } }
    var all: [String] { lock.withLock { items } }
    func register(_ source: StubSource) { lock.withLock { made[source.writer.baseName] = source } }
    subscript(base: String) -> StubSource? { lock.withLock { made[base] } }
}

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
        if writer.baseName.hasSuffix("(backup)") { calls.gate?.wait() }
        try writer.openSegment(format: int16Mono(rate: 48_000), reason: "start")
        set(.running)
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

private func recorder(_ calls: Calls) throws -> SessionRecorder {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("srb-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return SessionRecorder(
        root: root, appVersion: "t",
        makeSource: { spec, dir, base in StubSource(spec: spec, dir: dir, baseName: base, calls: calls) },
        freeBytes: { _ in 3_000_000_000 },
        devicePresent: { _ in calls.present })
}

private let mac = SourceSpec(kind: .computer, uid: nil, name: "Computer audio")
private let airpods = SourceSpec(kind: .mic, uid: "ap", name: "AirPods")
private let builtIn = SourceSpec(kind: .mic, uid: "bi", name: "MacBook Air Microphone")
private let backupBase = "mic - MacBook Air Microphone (backup)"

@Suite(.serialized) struct SessionRecorderBackupTests {
    @Test func aSessionThatNeverLosesAMicHasNoBackupTrack() throws {
        let calls = Calls()
        let r = try recorder(calls)
        let dir = try r.start(specs: [mac, airpods], backup: builtIn)
        calls["computer audio"]!.set(.waitingForDevice)
        calls["mic - AirPods"]!.set(.restarting("nsrt"))
        #expect(r.status().backup == .off)
        _ = r.stop()
        #expect(!calls.all.contains { $0.contains("(backup)") })
        #expect(try SessionManifest.load(from: dir).sources.map(\.file) == ["computer audio.m4a", "mic - AirPods.m4a"])
    }

    @Test func aLostMicStartsTheBackupInItsOwnTrackAndItsReturnPausesIt() throws {
        let calls = Calls()
        let r = try recorder(calls)
        let dir = try r.start(specs: [mac, airpods], backup: builtIn)
        let ap = calls["mic - AirPods"]!
        ap.set(.waitingForDevice)
        #expect(r.status().backup == .recording)
        #expect(waitUntil { calls.all.contains("start \(backupBase)") })
        #expect(waitUntil { (try? SessionManifest.load(from: dir))?.sources.last?.segments.count == 1 })
        let m = try SessionManifest.load(from: dir)
        #expect(m.sources.map(\.file) == ["computer audio.m4a", "mic - AirPods.m4a", backupBase + ".m4a"])
        #expect(m.sources[2].uid == "bi")
        #expect(m.sources[2].name == "MacBook Air Microphone")
        #expect(m.sources[2].channels == 1)
        #expect(m.sources[1].segments.count == 1)
        #expect(r.status().sources.map(\.spec.uid) == [nil, "ap", "bi"])
        ap.set(.running)
        #expect(r.status().backup == .off)
        #expect(waitUntil { calls.all.last == "pause \(backupBase)" })
        ap.set(.failed("x"))
        #expect(r.status().backup == .recording)
        #expect(waitUntil { calls.all.last == "resume \(backupBase) backup" })
        ap.set(.restarting("nsrt"))
        #expect(r.status().backup == .recording)
        _ = r.stop()
        #expect(calls.all.filter { $0 == "start \(backupBase)" }.count == 1)
        #expect(calls.all.contains("stop \(backupBase)"))
        #expect(try SessionManifest.load(from: dir).sources[2].segments.count == 1)
    }

    @Test func anAbsentBackupIsReportedAndStartsOnceItAppears() throws {
        let calls = Calls()
        calls.present = false
        let r = try recorder(calls)
        let dir = try r.start(specs: [mac, airpods], backup: builtIn)
        calls["mic - AirPods"]!.set(.waitingForDevice)
        #expect(r.status().backup == .missing)
        #expect(r.status().sources.count == 2)
        #expect(try SessionManifest.load(from: dir).sources.count == 2)
        calls.present = true
        _ = r.status()
        #expect(waitUntil { calls["mic - MacBook Air Microphone (backup)"]?.status == .running })
        #expect(r.status().backup == .recording)
        calls[backupBase]!.set(.waitingForDevice)
        #expect(r.status().backup == .missing)
        calls[backupBase]!.set(.failed("boom"))
        #expect(r.status().backup == .failed("boom"))
        _ = r.stop()
    }

    @Test func aBackupThatIsAlreadyRecordedIsIgnored() throws {
        let calls = Calls()
        let r = try recorder(calls)
        _ = try r.start(specs: [mac, airpods, builtIn], backup: builtIn)
        calls["mic - AirPods"]!.set(.waitingForDevice)
        #expect(r.status().backup == .off)
        _ = r.stop()
        #expect(!calls.all.contains { $0.contains("(backup)") })
    }

    @Test func wakeResumesTheBackupOnlyWhileItIsInUse() throws {
        let calls = Calls()
        let r = try recorder(calls)
        _ = try r.start(specs: [mac, airpods], backup: builtIn)
        let ap = calls["mic - AirPods"]!
        ap.set(.waitingForDevice)
        _ = r.status()
        #expect(waitUntil { calls[backupBase]?.status == .running })
        ap.set(.running)
        _ = r.status()
        #expect(waitUntil { calls.all.last == "pause \(backupBase)" })
        r.willSleep()
        r.didWake()
        #expect(calls.all.contains("resume mic - AirPods wake"))
        #expect(!calls.all.contains("resume \(backupBase) wake"))
        ap.set(.waitingForDevice)
        _ = r.status()
        #expect(waitUntil { calls.all.last == "resume \(backupBase) backup" })
        r.willSleep()
        r.didWake()
        #expect(calls.all.filter { $0 == "pause \(backupBase)" }.count == 2)
        #expect(calls.all.last == "resume \(backupBase) wake")
        _ = r.stop()
    }

    @Test func stopDuringABackupStartStopsTheBackupToo() throws {
        let calls = Calls()
        calls.gate = DispatchSemaphore(value: 0)
        let r = try recorder(calls)
        _ = try r.start(specs: [mac, airpods], backup: builtIn)
        calls["mic - AirPods"]!.set(.waitingForDevice)
        _ = r.status()
        #expect(waitUntil { calls.all.contains("start \(backupBase)") })
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            _ = r.stop()
            done.signal()
        }
        #expect(waitUntil { r.status().phase == .stopping })
        calls.gate?.signal()
        #expect(done.wait(timeout: .now() + 3) == .success)
        #expect(calls.all.last(where: { $0.hasSuffix("(backup)") }) == "stop \(backupBase)")
        #expect(calls[backupBase]?.status == .stopped)
    }
}
