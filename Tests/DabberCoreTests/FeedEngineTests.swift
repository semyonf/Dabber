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
    let inUse = Atomic<Bool>(true)
    let handlers = Mutex<[AudioObjectID: PropertyWatcher.Handler]>([:])
    let demandWatches = Atomic<Int>(0)
    let watched: [(AudioObjectID, WatchedObject)]

    init(watched: [(AudioObjectID, WatchedObject)] = [(77, .device)]) {
        self.watched = watched
    }

    var hooks: FeedHooks {
        FeedHooks(
            micPresent: { [self] _ in micPresent.load(ordering: .relaxed) },
            micDevice: { [self] in driverPresent.load(ordering: .relaxed) ? dabberMicID : nil },
            inUse: { [self] _ in inUse.load(ordering: .relaxed) },
            open: { [self] _, withMic in
                guard driverPresent.load(ordering: .relaxed) else { throw FeedError.driverMissing }
                if failingOpens.load(ordering: .relaxed) > 0 {
                    failingOpens.wrappingSubtract(1, ordering: .relaxed)
                    throw CAError(status: 1, op: "create feed aggregate")
                }
                opens.withLock { $0.append(withMic) }
                return OpenedFeed(device: 77, watched: watched) { [self] in
                    closes.wrappingAdd(1, ordering: .relaxed)
                }
            },
            startIO: { [self] _, _ in
                ioRunning.store(true, ordering: .relaxed)
                return { [self] in ioRunning.store(false, ordering: .relaxed) }
            },
            watch: { [self] objects, handler in
                handlers.withLock { h in for (object, _) in objects { h[object] = handler } }
                if objects.contains(where: { $0.0 == dabberMicID }) { demandWatches.wrappingAdd(1, ordering: .relaxed) }
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

private let dabberMicID: AudioObjectID = 55

private let withMic = FeedConfig(micUID: "ap", computerAudio: true, tapBundleIDs: ["com.apple.Safari"])

private func makeEngine(_ probe: FeedProbe) -> FeedEngine {
    let engine = FeedEngine(hooks: probe.hooks)
    engine.restartDelay = 0.1
    engine.retryDelay = 0.1
    engine.idleDelay = 0.2
    return engine
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

@Test func micFormatChangeKeepsTheFeedRunningButMicDeathRebuildsIt() {
    let probe = FeedProbe(watched: FeedAggregate.watchList(aggregate: 77, tap: 88, mic: 99))
    let engine = makeEngine(probe)
    engine.applyAndWait(withMic)
    probe.fire(99, kAudioDevicePropertyNominalSampleRate)
    probe.fire(99, kAudioStreamPropertyVirtualFormat)
    Thread.sleep(forTimeInterval: 0.3)
    #expect(engine.status == .running)
    #expect(probe.openedWithMic == [true])
    probe.fire(99, kAudioDevicePropertyDeviceIsAlive)
    #expect(waitUntil { engine.status == .restarting("livn") })
    #expect(waitUntil { engine.status == .running })
    #expect(probe.openedWithMic == [true, true])
    engine.applyAndWait(nil)
}

@Test func feedWaitsForAnAppToUseDabberMic() {
    let probe = FeedProbe()
    probe.inUse.store(false, ordering: .relaxed)
    let engine = makeEngine(probe)
    engine.applyAndWait(withMic)
    #expect(engine.status == .idle)
    #expect(probe.openedWithMic.isEmpty)
    #expect(!probe.running)
    probe.inUse.store(true, ordering: .relaxed)
    probe.fire(dabberMicID, kAudioDevicePropertyDeviceIsRunningSomewhere)
    #expect(waitUntil { engine.status == .running })
    #expect(probe.openedWithMic == [true])
    #expect(probe.running)
    engine.applyAndWait(nil)
}

@Test func feedStopsOnceNobodyUsesDabberMicForTheDelay() {
    let probe = FeedProbe()
    let engine = makeEngine(probe)
    engine.applyAndWait(withMic)
    #expect(engine.status == .running)
    probe.inUse.store(false, ordering: .relaxed)
    probe.fire(dabberMicID, kAudioDevicePropertyDeviceIsRunningSomewhere)
    Thread.sleep(forTimeInterval: 0.05)
    #expect(engine.status == .running)
    #expect(waitUntil { engine.status == .idle })
    #expect(!probe.running)
    #expect(probe.closes.load(ordering: .relaxed) == 1)
    engine.applyAndWait(nil)
    #expect(engine.status == .off)
}

@Test func briefGapInDabberMicUseKeepsTheFeedOpen() {
    let probe = FeedProbe()
    let engine = makeEngine(probe)
    engine.applyAndWait(withMic)
    probe.inUse.store(false, ordering: .relaxed)
    probe.fire(dabberMicID, kAudioDevicePropertyDeviceIsRunningSomewhere)
    Thread.sleep(forTimeInterval: 0.05)
    probe.inUse.store(true, ordering: .relaxed)
    probe.fire(dabberMicID, kAudioDevicePropertyDeviceIsRunningSomewhere)
    Thread.sleep(forTimeInterval: 0.4)
    #expect(engine.status == .running)
    #expect(probe.openedWithMic == [true])
    #expect(probe.closes.load(ordering: .relaxed) == 0)
    engine.applyAndWait(nil)
}

@Test func restartWhileNobodyUsesDabberMicLeavesTheFeedIdle() {
    let probe = FeedProbe()
    let engine = makeEngine(probe)
    engine.applyAndWait(withMic)
    probe.inUse.store(false, ordering: .relaxed)
    probe.fire(77, kAudioDevicePropertyNominalSampleRate)
    #expect(waitUntil { engine.status == .idle })
    #expect(probe.openedWithMic == [true])
    #expect(!probe.running)
    engine.applyAndWait(nil)
}

@Test func serviceRestartReregistersTheDabberMicListener() {
    let probe = FeedProbe()
    let engine = makeEngine(probe)
    engine.applyAndWait(withMic)
    #expect(probe.demandWatches.load(ordering: .relaxed) == 1)
    probe.fire(systemObject, kAudioHardwarePropertyServiceRestarted)
    #expect(waitUntil { probe.openedWithMic.count == 2 && engine.status == .running })
    #expect(probe.demandWatches.load(ordering: .relaxed) == 2)
    engine.applyAndWait(nil)
}
