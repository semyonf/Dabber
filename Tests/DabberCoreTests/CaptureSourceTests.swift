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
    let streamlessOpens = Atomic<Int>(0)

    override func openDevice() throws -> OpenedDevice {
        guard present.load(ordering: .relaxed) else { throw SourceError.deviceMissing("fake") }
        if streamlessOpens.load(ordering: .relaxed) > 0 {
            streamlessOpens.wrappingSubtract(1, ordering: .relaxed)
            throw SourceError.noInputStream("fake")
        }
        return OpenedDevice(device: 42, format: int16Mono(rate: 48_000), watched: [(42, .device), (43, .inputStream)])
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

@Test func deviceMissingRestartResumesWhenTheSystemReportsTheUIDBack() async throws {
    let probe = Probe()
    let source = try makeSource(probe)
    try source.start()
    #expect(source.status == .running)
    source.present.store(false, ordering: .relaxed)
    probe.fire(42, kAudioDevicePropertyDeviceIsAlive)
    #expect(await eventually { source.status == .waitingForDevice })
    #expect(!probe.running)
    source.present.store(true, ordering: .relaxed)
    probe.fire(systemObject, kAudioHardwarePropertyDevices)
    #expect(await eventually { source.status == .running })
    #expect(probe.starts == 2)
    #expect(source.restarts.map(\.reason) == ["livn", "device returned"])
    source.stop()
}

@Test func startWithTheDeviceMissingWaitsThenRecordsWhenItAppears() async throws {
    let probe = Probe()
    let source = try makeSource(probe)
    source.present.store(false, ordering: .relaxed)
    try source.start()
    #expect(source.status == .waitingForDevice)
    #expect(!probe.running)
    source.present.store(true, ordering: .relaxed)
    probe.fire(systemObject, kAudioHardwarePropertyDevices)
    #expect(await eventually { source.status == .running })
    #expect(probe.starts == 1)
    #expect(source.writer.segments.map(\.reason) == ["restart: device returned"])
    source.stop()
    #expect(source.status == .stopped)
}

@Test func wakeWhileWaitingKeepsWaiting() async throws {
    let probe = Probe()
    let source = try makeSource(probe)
    source.present.store(false, ordering: .relaxed)
    try source.start()
    source.pause()
    source.resume()
    #expect(await eventually { source.status == .waitingForDevice })
    #expect(source.restarts.isEmpty)
    source.stop()
}

@Test func aStartErrorOnWakeIsRetried() async throws {
    let probe = Probe()
    let source = try makeSource(probe)
    source.retryDelay = 0.2
    try source.start()
    source.pause()
    #expect(!probe.running)
    source.streamlessOpens.store(1, ordering: .relaxed)
    source.resume()
    #expect(await eventually { source.status == .running })
    #expect(probe.starts == 2)
    #expect(source.restarts.map(\.reason) == ["wake", "wake"])
    source.stop()
}

@Test func aSecondWakeDuringARetryStartsCaptureOnce() async throws {
    let probe = Probe()
    let source = try makeSource(probe)
    source.retryDelay = 1
    try source.start()
    source.pause()
    source.streamlessOpens.store(1, ordering: .relaxed)
    source.resume()
    #expect(await eventually { if case .restarting = source.status { true } else { false } })
    source.resume()
    #expect(await eventually { source.status == .running })
    try? await Task.sleep(for: .seconds(1.2))
    #expect(probe.starts == 2)
    source.stop()
    #expect(!probe.running)
}

@Test func deviceThatAppearsBeforeItsInputStreamIsRetried() async throws {
    let probe = Probe()
    let source = try makeSource(probe)
    source.retryDelay = 0.2
    source.present.store(false, ordering: .relaxed)
    try source.start()
    source.streamlessOpens.store(1, ordering: .relaxed)
    source.present.store(true, ordering: .relaxed)
    probe.fire(systemObject, kAudioHardwarePropertyDevices)
    #expect(await eventually { source.status == .running })
    #expect(probe.starts == 1)
    source.stop()
}

@Test func triggerStopsIOAtOnceAndReopensOnlyAfterTheDebounce() async throws {
    let probe = Probe()
    let source = try makeSource(probe)
    source.restartDelay = 1
    try source.start()
    let fired = Date()
    probe.fire(42, kAudioDevicePropertyDeviceHasChanged)
    #expect(await eventually { !probe.running })
    #expect(source.status == .restarting("diff"))
    #expect(probe.starts == 1)
    #expect(await eventually { source.status == .running })
    #expect(Date().timeIntervalSince(fired) >= 1)
    #expect(probe.starts == 2)
    #expect(source.writer.segments.map(\.reason) == ["start", "restart: diff"])
    source.stop()
}

@Test(arguments: [(AudioObjectID(42), kAudioDevicePropertyNominalSampleRate), (AudioObjectID(43), kAudioStreamPropertyVirtualFormat)])
func formatChangeReopensAfterAShortDelay(object: AudioObjectID, selector: AudioObjectPropertySelector) async throws {
    let probe = Probe()
    let source = try makeSource(probe)
    source.restartDelay = 2
    try source.start()
    let fired = Date()
    probe.fire(object, selector)
    #expect(await eventually { probe.starts == 2 && source.status == .running })
    let elapsed = Date().timeIntervalSince(fired)
    #expect(elapsed >= 0.1)
    #expect(elapsed < 1)
    source.stop()
}

@Test func stopDuringAPendingRestartLeavesTheSourceStopped() async throws {
    let probe = Probe()
    let source = try makeSource(probe)
    source.restartDelay = 1
    try source.start()
    probe.fire(42, kAudioDevicePropertyDeviceHasChanged)
    #expect(await eventually { source.status == .restarting("diff") })
    source.stop()
    try? await Task.sleep(for: .seconds(1.2))
    #expect(source.status == .stopped)
    #expect(probe.starts == 1)
    #expect(!probe.running)
}

@Test func aStartErrorLeavesTheSourceFailed() throws {
    let probe = Probe()
    let source = try makeSource(probe)
    source.streamlessOpens.store(1, ordering: .relaxed)
    #expect(throws: SourceError.self) { try source.start() }
    #expect(source.status == .failed("device fake has no input stream"))
    #expect(!probe.running)
}
