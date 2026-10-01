import Foundation
import Observation
import Synchronization
import Testing
@testable import DabberCore

private final class FakeEngine: RecordingEngine, @unchecked Sendable {
    var started: [[SourceSpec]] = []
    var backups: [SourceSpec?] = []
    var backupChanges: [SourceSpec?] = []
    var backupState: BackupState = .off
    var slides: [Bool] = []
    let frames = Mutex<[UInt64]>([])
    var phase: RecorderPhase = .idle
    var snapshots: [SourceSnapshot] = []
    var dir = URL(fileURLWithPath: "/tmp/fake-session")
    var lastSessionDir: URL?
    var startError: Error?
    var diskWarning: String?
    var lastError: String?
    var startGate: DispatchSemaphore?
    let startEntered = Atomic<Bool>(false)

    func start(specs: [SourceSpec], backup: SourceSpec?, title: String, slides: Bool) throws -> URL {
        startEntered.store(true, ordering: .relaxed)
        startGate?.wait()
        if let startError { throw startError }
        if phase != .idle { throw RecorderError.busy }
        lastError = nil
        started.append(specs)
        backups.append(backup)
        self.slides.append(slides)
        manifest.title = title
        phase = .recording
        return dir
    }

    func setBackup(_ spec: SourceSpec?) { backupChanges.append(spec) }

    func stop() -> URL? {
        guard phase != .idle else { return nil }
        phase = .idle
        lastSessionDir = dir
        return dir
    }

    var manifest = SessionManifest(appVersion: "t", startedAt: Date(), sessionStartNanos: 1_000_000_000)

    func addMark(atNanos: UInt64) -> [Mark] { editMarks { $0.addMark(atNanos: atNanos) } }
    func setMarkText(id: Int, _ text: String) -> [Mark] { editMarks { $0.setMarkText(id: id, text) } }
    func removeMark(id: Int) -> [Mark] { editMarks { $0.removeMark(id: id) } }
    func setTitle(_ title: String) { _ = editMarks { $0.title = title } }

    func addFrame(atNanos: UInt64, data: Data) throws -> Bool {
        guard phase == .recording else { return false }
        frames.withLock { $0.append(atNanos) }
        return true
    }

    private func editMarks(_ edit: (inout SessionManifest) -> Void) -> [Mark] {
        guard phase == .recording else { return [] }
        edit(&manifest)
        return manifest.marks
    }

    func status(at now: Date) -> RecorderStatus {
        RecorderStatus(phase: phase, elapsedSeconds: 61, sources: snapshots, sessionDir: phase == .recording ? dir : nil, lastError: lastError,
            diskWarning: diskWarning, backup: backupState)
    }
}

private final class FakeCatalog: DeviceCatalog, @unchecked Sendable {
    var devices: [InputDevice]
    var defaultUID: String?
    init(devices: [InputDevice], defaultUID: String? = nil) {
        self.devices = devices
        self.defaultUID = defaultUID
    }
    func inputs() throws -> [InputDevice] { devices }
    func defaultInputUID() -> String? { defaultUID }
}

private let airpods = InputDevice(id: 1, uid: "ap", name: "AirPods")
private let usb = InputDevice(id: 2, uid: "usb", name: "USB")

@MainActor
private func model(_ engine: FakeEngine, enabled: Set<String> = ["computer"], finalized: @escaping @Sendable (URL) -> Void = { _ in }) -> RecorderModel {
    let m = RecorderModel(
        engine: engine, catalog: FakeCatalog(devices: [airpods, usb]), enabledIDs: enabled, persist: { _ in },
        finalize: { dir, _ in finalized(dir); return dir })
    m.refreshDevices()
    return m
}

@MainActor @Test func rowsListComputerAudioThenDevices() {
    let m = model(FakeEngine())
    #expect(m.rows.map(\.id) == ["computer", "ap", "usb"])
    #expect(m.rows.map(\.enabled) == [true, false, false])
}

@MainActor @Test func dabberMicIsNeverARecordingSource() {
    let dabberMic = InputDevice(id: 9, uid: FeedDevices.micUID, name: "Dabber Mic")
    let m = RecorderModel(
        engine: FakeEngine(), catalog: FakeCatalog(devices: [airpods, dabberMic]), enabledIDs: ["computer", FeedDevices.micUID],
        persist: { _ in }, finalize: { dir, _ in dir })
    m.refreshDevices()
    #expect(!m.rows.contains { $0.id == FeedDevices.micUID })
}

@MainActor @Test func rowTitlesSayMacAudioAndMarkMissingDevices() {
    let m = absentModel(FakeEngine(), enabled: ["ap"], defaultUID: nil)
    #expect(m.rows.map(\.title) == ["Mac audio", "USB", "AirPods (not connected)"])
    #expect(m.rows[0].name == "Computer audio")
}

@MainActor @Test func levelBarsOnlyForCheckedOrRecordedSources() async {
    let e = FakeEngine()
    let m = model(e)
    #expect(m.rows.map(\.showsLevel) == [true, false, false])
    e.snapshots = [SourceSnapshot(spec: SourceSpec(kind: .mic, uid: "usb", name: "USB"), status: .running, levelDb: -20, silent: false)]
    e.phase = .recording
    m.tick()
    #expect(m.rows.map(\.showsLevel) == [true, false, true])
}

@MainActor @Test func recordButtonFollowsThePhaseAndIsFreeWhileTheFinalizeRuns() async {
    let e = SlowStopEngine()
    let gate = DispatchSemaphore(value: 0)
    let m = RecorderModel(
        engine: e, catalog: FakeCatalog(devices: [airpods]), enabledIDs: ["computer"], persist: { _ in },
        finalize: { dir, _ in
            gate.wait()
            return dir
        })
    m.refreshDevices()
    #expect(m.recordTitle == "● Record")
    #expect(m.canStartStop)
    await m.startStop()
    #expect(m.recordTitle == "■ Stop")
    #expect(m.canStartStop)
    let stopping = Task { await m.startStop() }
    while e.phase != .stopping { await Task.yield() }
    #expect(m.recordTitle == "Stopping…")
    #expect(!m.canStartStop)
    #expect(m.finishing == nil)
    e.gate.signal()
    await stopping.value
    #expect(m.recordTitle == "● Record")
    #expect(m.canStartStop)
    #expect(m.finishing == "Finishing: slow-stop…")
    m.toggle("computer")
    #expect(!m.canStartStop)
    gate.signal()
    await m.finishPending()
    #expect(m.finishing == nil)
}

@MainActor @Test func recordingAgainWhileEarlierRecordingsFinishOneAtATimeInOrder() async {
    let e = FakeEngine()
    let gate = DispatchSemaphore(value: 0)
    let log = Mutex<[String]>([])
    let m = model(e) { dir in
        log.withLock { $0.append("begin " + dir.lastPathComponent) }
        gate.wait()
        log.withLock { $0.append("end " + dir.lastPathComponent) }
    }
    let a = URL(fileURLWithPath: "/tmp/2026-09-29 10-00 A")
    let b = URL(fileURLWithPath: "/tmp/2026-09-29 11-00 B")
    e.dir = a
    await m.startStop()
    await m.startStop()
    #expect(m.recordTitle == "● Record")
    #expect(m.finishing == "Finishing: 2026-09-29 10-00 A…")
    e.dir = b
    await m.startStop()
    #expect(m.isRecording)
    #expect(m.finishing == "Finishing: 2026-09-29 10-00 A…")
    await m.startStop()
    #expect(m.finishing == "Finishing 2 recordings…")
    #expect(await eventually { log.withLock { $0 } == ["begin 2026-09-29 10-00 A"] })
    gate.signal()
    #expect(await eventually { m.finishing == "Finishing: 2026-09-29 11-00 B…" })
    #expect(m.lastSessionDir == a)
    gate.signal()
    await m.finishPending()
    #expect(m.finishing == nil)
    #expect(m.lastSessionDir == b)
    #expect(log.withLock { $0 } == [
        "begin 2026-09-29 10-00 A", "end 2026-09-29 10-00 A", "begin 2026-09-29 11-00 B", "end 2026-09-29 11-00 B",
    ])
}

@MainActor @Test func finalizeRunsAtUtilityPriority() async {
    let seen = Mutex<TaskPriority?>(nil)
    let m = RecorderModel(
        engine: FakeEngine(), catalog: FakeCatalog(devices: [airpods]), enabledIDs: ["computer"], persist: { _ in },
        finalize: { dir, _ in
            seen.withLock { $0 = Task.basePriority }
            return dir
        })
    m.refreshDevices()
    await m.startStop()
    await m.startStop()
    await m.finishPending()
    #expect(seen.withLock { $0 } == .utility)
}

@MainActor @Test func aFinishedFinalizeKeepsTheErrorOfAFailedStart() async {
    let e = FakeEngine()
    let gate = DispatchSemaphore(value: 0)
    let m = model(e) { _ in gate.wait() }
    await m.startStop()
    await m.startStop()
    e.startError = RecorderError.lowDisk(freeBytes: 5)
    await m.startStop()
    #expect(m.errorText?.contains("MB free") == true)
    gate.signal()
    await m.finishPending()
    #expect(m.errorText?.contains("MB free") == true)
}

@MainActor @Test func aFailedFinalizeIsShownUntilTheNextRecording() async {
    let e = FakeEngine()
    let m = RecorderModel(
        engine: e, catalog: FakeCatalog(devices: [airpods]), enabledIDs: ["computer"], persist: { _ in },
        finalize: { _, _ in throw RecorderError.noSources })
    m.refreshDevices()
    await m.startStop()
    await m.startStop()
    await m.finishPending()
    #expect(m.errorText == "Could not finish fake-session: no sources selected")
    #expect(m.lastSessionDir == e.dir)
    await m.startStop()
    #expect(m.errorText == nil)
}

@MainActor @Test func quitDuringAStartStopsTheNewRecording() async {
    let e = FakeEngine()
    e.startGate = DispatchSemaphore(value: 0)
    let m = model(e)
    let starting = Task { await m.startStop() }
    while !e.startEntered.load(ordering: .relaxed) { await Task.yield() }
    let quit = Task { await m.prepareToQuit() }
    try? await Task.sleep(for: .milliseconds(20))
    e.startGate?.signal()
    await starting.value
    await quit.value
    #expect(e.phase == .idle)
    #expect(e.lastSessionDir == e.dir)
    await m.startStop()
    #expect(e.started.count == 1)
}

@MainActor @Test func recordButtonIsDisabledWhileAStartIsInProgress() async {
    let e = FakeEngine()
    e.startGate = DispatchSemaphore(value: 0)
    let m = model(e)
    let starting = Task { await m.startStop() }
    while !e.startEntered.load(ordering: .relaxed) { await Task.yield() }
    #expect(!m.canStartStop)
    let second = Task { await m.startStop() }
    try? await Task.sleep(for: .milliseconds(20))
    e.startGate?.signal()
    e.startGate?.signal()
    await starting.value
    await second.value
    #expect(e.started.count == 1)
    #expect(m.errorText == nil)
    #expect(m.isRecording)
    #expect(m.canStartStop)
}

@MainActor @Test func unchangedTickDoesNotInvalidateRows() {
    let e = FakeEngine()
    let m = model(e, enabled: ["computer", "ap"])
    e.phase = .recording
    e.snapshots = [SourceSnapshot(spec: SourceSpec(kind: .computer, uid: nil, name: "Computer audio"), status: .running, levelDb: -12, silent: false)]
    m.tick()
    nonisolated(unsafe) var changed = false
    withObservationTracking { _ = m.rows } onChange: { changed = true }
    m.tick()
    #expect(!changed)
    e.snapshots = [SourceSnapshot(spec: SourceSpec(kind: .computer, uid: nil, name: "Computer audio"), status: .running, levelDb: -20, silent: false)]
    m.tick()
    #expect(changed)
    #expect(m.rows[0].levelDb == -20)
}

@MainActor @Test func macAudioWarningsUseTheUILabel() {
    let e = FakeEngine()
    let m = model(e)
    e.phase = .recording
    e.snapshots = [SourceSnapshot(spec: SourceSpec(kind: .computer, uid: nil, name: "Computer audio"), status: .running, levelDb: -90, silent: true)]
    m.tick()
    #expect(m.warning == "Mac audio: no signal for 10 s")
}

@MainActor @Test func startUsesEnabledAvailableRows() async {
    let e = FakeEngine()
    let m = model(e, enabled: ["computer", "ap", "gone"])
    await m.startStop()
    #expect(e.started == [[
        SourceSpec(kind: .computer, uid: nil, name: "Computer audio"),
        SourceSpec(kind: .mic, uid: "ap", name: "AirPods"),
        SourceSpec(kind: .mic, uid: "gone", name: "gone"),
    ]])
    #expect(m.phase == .recording)
    #expect(m.warning == "gone not connected")
}

@MainActor @Test func stopFinalizesAndRemembersTheSession() async {
    let e = FakeEngine()
    nonisolated(unsafe) var finalized: [URL] = []
    let m = model(e) { finalized.append($0) }
    await m.startStop()
    await m.startStop()
    #expect(e.phase == .idle)
    await m.finishPending()
    #expect(finalized == [e.dir])
    #expect(m.lastSessionDir == e.dir)
    #expect(m.finishing == nil)
}

@MainActor @Test func sessionThatStoppedItselfIsFinalized() async {
    let e = FakeEngine()
    nonisolated(unsafe) var finalized: [URL] = []
    let m = model(e) { finalized.append($0) }
    await m.startStop()
    e.phase = .idle
    e.lastSessionDir = e.dir
    m.tick()
    #expect(m.finishing == "Finishing: fake-session…")
    #expect(m.recordTitle == "● Record")
    await m.finishPending()
    #expect(finalized == [e.dir])
    #expect(m.lastSessionDir == e.dir)
    m.tick()
    #expect(finalized == [e.dir])
}

@MainActor @Test func selfStopSeenThroughStoppingIsFinalizedOnce() async {
    let e = FakeEngine()
    nonisolated(unsafe) var finalized: [URL] = []
    let m = model(e) { finalized.append($0) }
    await m.startStop()
    e.phase = .stopping
    m.tick()
    e.phase = .idle
    e.lastSessionDir = e.dir
    m.tick()
    #expect(m.finishing == "Finishing: fake-session…")
    m.tick()
    await m.finishPending()
    m.tick()
    #expect(finalized == [e.dir])
    #expect(m.lastSessionDir == e.dir)
}

@MainActor @Test func quitDuringFinalizeWaitsForTheFinalizeToReturn() async {
    let e = FakeEngine()
    let gate = DispatchSemaphore(value: 0)
    nonisolated(unsafe) var returned = false
    let m = model(e) { _ in
        gate.wait()
        returned = true
    }
    await m.startStop()
    await m.startStop()
    #expect(m.finishing == "Finishing: fake-session…")
    let quit = Task { await m.prepareToQuit(); return returned }
    try? await Task.sleep(for: .milliseconds(50))
    gate.signal()
    #expect(await quit.value)
    #expect(m.finishing == nil)
}

@MainActor @Test func quitRightAfterAnUnnoticedSelfStopFinalizesThatSession() async {
    let e = FakeEngine()
    nonisolated(unsafe) var finalized: [URL] = []
    let m = model(e) { finalized.append($0) }
    await m.startStop()
    e.phase = .idle
    e.lastSessionDir = e.dir
    await m.prepareToQuit()
    #expect(finalized == [e.dir])
}

@MainActor @Test func quitDuringASelfStopFinalizeWaitsForIt() async {
    let e = FakeEngine()
    let gate = DispatchSemaphore(value: 0)
    nonisolated(unsafe) var returned = false
    let m = model(e) { _ in
        gate.wait()
        returned = true
    }
    await m.startStop()
    e.phase = .idle
    e.lastSessionDir = e.dir
    m.tick()
    let quit = Task { await m.prepareToQuit(); return returned }
    try? await Task.sleep(for: .milliseconds(50))
    gate.signal()
    #expect(await quit.value)
}

@MainActor @Test func quitWhileRecordingSaysItIsFinalizingBeforeQuit() async {
    let e = FakeEngine()
    let gate = DispatchSemaphore(value: 0)
    let m = model(e) { _ in gate.wait() }
    await m.startStop()
    let quit = Task { await m.prepareToQuit() }
    while m.isRecording { await Task.yield() }
    #expect(m.recordTitle == "Finalizing before quit…")
    #expect(!m.canStartStop)
    gate.signal()
    await quit.value
}

@MainActor @Test func quitDuringAFinalizeSaysItIsFinalizingBeforeQuit() async {
    let e = FakeEngine()
    let gate = DispatchSemaphore(value: 0)
    let m = model(e) { _ in gate.wait() }
    await m.startStop()
    await m.startStop()
    #expect(m.recordTitle == "● Record")
    let quit = Task { await m.prepareToQuit() }
    try? await Task.sleep(for: .milliseconds(20))
    #expect(m.recordTitle == "Finalizing before quit…")
    #expect(!m.canStartStop)
    gate.signal()
    await quit.value
}

@MainActor @Test func stopErrorClearsOnceSeenAfterTheFinalize() async {
    let e = FakeEngine()
    let gate = DispatchSemaphore(value: 0)
    let m = model(e) { _ in gate.wait() }
    await m.startStop()
    e.phase = .idle
    e.lastSessionDir = e.dir
    e.lastError = "disk almost full (5 MB free)"
    m.tick()
    #expect(m.warning == "stopped: disk almost full (5 MB free)")
    m.menuClosed()
    #expect(m.warning == "stopped: disk almost full (5 MB free)")
    gate.signal()
    await m.finishPending()
    m.tick()
    #expect(m.warning == "stopped: disk almost full (5 MB free)")
    m.menuClosed()
    #expect(m.warning == nil)
    m.tick()
    #expect(m.warning == nil)
}

@MainActor @Test func stopErrorOfTheNextSessionIsShownAgain() async {
    let e = FakeEngine()
    let m = model(e)
    await m.startStop()
    e.phase = .idle
    e.lastSessionDir = e.dir
    e.lastError = "disk almost full (5 MB free)"
    m.tick()
    await m.finishPending()
    m.menuClosed()
    #expect(m.warning == nil)
    await m.startStop()
    #expect(m.isRecording)
    e.phase = .idle
    e.lastError = "caf write failed: 1"
    m.tick()
    #expect(m.warning == "stopped: caf write failed: 1")
}

@MainActor @Test func recoveryFailureIsAWarningUntilSeen() {
    let m = model(FakeEngine())
    m.recoveryFailed(URL(fileURLWithPath: "/tmp/rec/2026-09-23 10-00"), RecorderError.noSources)
    #expect(m.warning == "Could not finish 2026-09-23 10-00: no sources selected")
    m.tick()
    #expect(m.warning == "Could not finish 2026-09-23 10-00: no sources selected")
    m.menuClosed()
    #expect(m.warning == nil)
}

@MainActor @Test func recoveredSessionProblemsAreWarningsUntilSeen() {
    let m = model(FakeEngine())
    m.recovered(
        URL(fileURLWithPath: "/tmp/rec/2026-09-23 10-00"),
        FinalizeReport(totalFrames: 1, gaps: [], driftMillis: [:], resampled: [], slidesError: "no frames", unreadable: ["a.caf"]))
    #expect(m.warning == "2026-09-23 10-00: Slides video failed: no frames; 2026-09-23 10-00: Could not read: a.caf")
    m.menuClosed()
    #expect(m.warning == nil)
    m.recovered(URL(fileURLWithPath: "/tmp/rec/x"), FinalizeReport(totalFrames: 1, gaps: [], driftMillis: [:], resampled: []))
    #expect(m.warning == nil)
}

@MainActor @Test func lowDiskWarningIsShown() async {
    let e = FakeEngine()
    let m = model(e, enabled: ["computer", "ap"])
    await m.startStop()
    e.diskWarning = "disk space low: about 19 min of recording left"
    m.tick()
    #expect(m.warning == "disk space low: about 19 min of recording left")
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
    #expect(!m.rows[1].silent)
    #expect(m.warning == "AirPods: restarting (nsrt)")
}

@MainActor @Test func startErrorIsShownNotThrown() async {
    let e = FakeEngine()
    e.startError = RecorderError.lowDisk(freeBytes: 5)
    let m = model(e)
    await m.startStop()
    #expect(m.phase == .idle)
    #expect(m.errorText?.contains("MB free") == true)
}

@MainActor private func absentModel(
    _ engine: FakeEngine, enabled: Set<String>, devices: [InputDevice] = [usb], defaultUID: String?,
    names: [String: String] = ["ap": "AirPods"]
) -> RecorderModel {
    let m = RecorderModel(
        engine: engine, catalog: FakeCatalog(devices: devices, defaultUID: defaultUID), enabledIDs: enabled,
        names: names, persist: { _ in }, finalize: { dir, _ in dir })
    m.refreshDevices()
    return m
}

@MainActor @Test func missingEnabledDeviceStaysListedAsNotConnected() {
    let m = absentModel(FakeEngine(), enabled: ["ap"], defaultUID: "usb")
    #expect(m.rows.map(\.id) == ["computer", "usb", "ap"])
    #expect(m.rows.map(\.name) == ["Computer audio", "USB", "AirPods"])
    #expect(m.rows.map(\.connected) == [true, true, false])
    #expect(m.rows[2].enabled)
    m.toggle("usb")
    #expect(m.rows[1].enabled)
}

@MainActor @Test func missingEnabledMicFallsBackToDefaultInputAndWarns() async {
    let e = FakeEngine()
    let m = absentModel(e, enabled: ["computer", "ap"], defaultUID: "usb")
    await m.startStop()
    #expect(e.started == [[
        SourceSpec(kind: .computer, uid: nil, name: "Computer audio"),
        SourceSpec(kind: .mic, uid: "ap", name: "AirPods"),
        SourceSpec(kind: .mic, uid: "usb", name: "USB"),
    ]])
    #expect(m.warning == "AirPods not connected — recording USB")
    await m.startStop()
    #expect(m.warning == nil)
}

@MainActor @Test func absentMicWarningClearsOnceItConnects() async {
    let e = FakeEngine()
    let m = absentModel(e, enabled: ["computer", "ap"], defaultUID: "usb")
    await m.startStop()
    let ap = SourceSpec(kind: .mic, uid: "ap", name: "AirPods")
    e.snapshots = [SourceSnapshot(spec: ap, status: .waitingForDevice, levelDb: -160, silent: false)]
    m.tick()
    #expect(m.rows[2].status == .waitingForDevice)
    #expect(m.warning == "AirPods not connected — recording USB")
    e.snapshots = [SourceSnapshot(spec: ap, status: .running, levelDb: -20, silent: false)]
    m.tick()
    #expect(m.warning == nil)
    e.snapshots = [SourceSnapshot(spec: ap, status: .waitingForDevice, levelDb: -160, silent: false)]
    m.tick()
    #expect(m.warning == "AirPods: waiting for device")
}

@MainActor @Test func unpluggedFallbackStaysListedWhileTheSessionRuns() async {
    let e = FakeEngine()
    let catalog = FakeCatalog(devices: [usb], defaultUID: "usb")
    let m = RecorderModel(
        engine: e, catalog: catalog, enabledIDs: ["computer", "ap"], names: ["ap": "AirPods"],
        persist: { _ in }, finalize: { dir, _ in dir })
    m.refreshDevices()
    await m.startStop()
    catalog.devices = []
    m.refreshDevices()
    #expect(m.rows.map(\.id) == ["computer", "ap", "usb"])
    #expect(m.rows.map(\.connected) == [true, false, false])
    #expect(m.rows.map(\.enabled) == [true, true, false])
    e.snapshots = [
        SourceSnapshot(spec: SourceSpec(kind: .mic, uid: "ap", name: "AirPods"), status: .waitingForDevice, levelDb: -160, silent: false),
        SourceSnapshot(spec: SourceSpec(kind: .mic, uid: "usb", name: "USB"), status: .waitingForDevice, levelDb: -160, silent: false),
    ]
    m.tick()
    #expect(m.warning == "AirPods not connected — recording USB; USB: waiting for device")
    await m.startStop()
    #expect(m.rows.map(\.id) == ["computer", "ap"])
}

@MainActor @Test func startNoteListsOnlyMicsStillAbsent() async {
    let e = FakeEngine()
    let m = absentModel(e, enabled: ["computer", "ap", "bt"], defaultUID: "usb", names: ["ap": "AirPods", "bt": "Buds"])
    await m.startStop()
    #expect(m.warning == "AirPods, Buds not connected — recording USB")
    e.snapshots = [
        SourceSnapshot(spec: SourceSpec(kind: .mic, uid: "ap", name: "AirPods"), status: .running, levelDb: -20, silent: false),
        SourceSnapshot(spec: SourceSpec(kind: .mic, uid: "bt", name: "Buds"), status: .waitingForDevice, levelDb: -160, silent: false),
    ]
    m.tick()
    #expect(m.warning == "Buds not connected — recording USB")
}

@MainActor @Test func presentEnabledMicNeedsNoFallback() async {
    let e = FakeEngine()
    let m = absentModel(e, enabled: ["computer", "ap"], devices: [airpods, usb], defaultUID: "usb")
    await m.startStop()
    #expect(e.started == [[
        SourceSpec(kind: .computer, uid: nil, name: "Computer audio"),
        SourceSpec(kind: .mic, uid: "ap", name: "AirPods"),
    ]])
    #expect(m.warning == nil)
}

@MainActor @Test func noEnabledMicFallsBackToDefaultInput() async {
    let e = FakeEngine()
    let m = absentModel(e, enabled: ["computer"], devices: [airpods, usb], defaultUID: "ap")
    await m.startStop()
    #expect(e.started == [[
        SourceSpec(kind: .computer, uid: nil, name: "Computer audio"),
        SourceSpec(kind: .mic, uid: "ap", name: "AirPods"),
    ]])
    #expect(m.warning == "No microphone selected — recording AirPods")
}

@MainActor @Test func noDefaultInputStartsAnywayAndWarns() async {
    let e = FakeEngine()
    let m = absentModel(e, enabled: ["computer", "ap"], defaultUID: nil)
    await m.startStop()
    #expect(e.started == [[
        SourceSpec(kind: .computer, uid: nil, name: "Computer audio"),
        SourceSpec(kind: .mic, uid: "ap", name: "AirPods"),
    ]])
    #expect(m.phase == .recording)
    #expect(m.warning == "No microphone available")
}

@MainActor @Test func enabledDeviceNamesArePersisted() {
    nonisolated(unsafe) var saved: [[String: String]] = []
    let m = RecorderModel(
        engine: FakeEngine(), catalog: FakeCatalog(devices: [airpods, usb]), enabledIDs: ["ap"],
        persist: { _ in }, persistNames: { saved.append($0) }, finalize: { dir, _ in dir })
    m.refreshDevices()
    #expect(saved.last == ["ap": "AirPods"])
    m.toggle("usb")
    #expect(saved.last == ["ap": "AirPods", "usb": "USB"])
    m.toggle("ap")
    #expect(saved.last == ["usb": "USB"])
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

private final class FakeHostClock: @unchecked Sendable {
    var now: UInt64 = 1_000_000_000
}

@MainActor
private func markModel(_ engine: FakeEngine, _ clock: FakeHostClock) async -> RecorderModel {
    let m = RecorderModel(
        engine: engine, catalog: FakeCatalog(devices: [airpods]), enabledIDs: ["computer"], persist: { _ in },
        finalize: { dir, _ in dir }, clock: { clock.now })
    m.refreshDevices()
    await m.startStop()
    return m
}

@MainActor @Test func markTakesThePressTimeAndTheCommentDoesNotMoveIt() async {
    let e = FakeEngine()
    let clock = FakeHostClock()
    let m = await markModel(e, clock)
    #expect(m.canMark)
    clock.now = 6_000_000_000
    m.mark()
    #expect(m.marks == [Mark(id: 1, offsetNanos: 5_000_000_000)])
    #expect(m.editingMarkID == 1)
    #expect(m.markRows == [RecorderModel.MarkRow(id: 1, time: "0:05", title: "Mark 1")])
    clock.now = 9_000_000_000
    m.draft = "про деньги"
    m.saveComment()
    #expect(m.marks == [Mark(id: 1, offsetNanos: 5_000_000_000, text: "про деньги")])
    #expect(m.editingMarkID == nil)
    #expect(m.draft == "")
    #expect(e.manifest.marks == m.marks)
}

@MainActor @Test func nextMarkSavesTheOpenCommentFirst() async {
    let e = FakeEngine()
    let clock = FakeHostClock()
    let m = await markModel(e, clock)
    clock.now = 2_000_000_000
    m.mark()
    m.draft = "first"
    clock.now = 3_000_000_000
    m.mark()
    #expect(m.markRows.map(\.title) == ["first", "Mark 2"])
    #expect(m.editingMarkID == 2)
}

@MainActor @Test func removingAMarkDropsItsOpenComment() async {
    let e = FakeEngine()
    let m = await markModel(e, FakeHostClock())
    m.mark()
    m.draft = "gone"
    m.removeMark(1)
    #expect(m.marks.isEmpty)
    #expect(m.editingMarkID == nil)
    #expect(m.draft == "")
    #expect(e.manifest.marks.isEmpty)
}

@MainActor @Test func closingTheMenuSavesTheOpenComment() async {
    let e = FakeEngine()
    let m = await markModel(e, FakeHostClock())
    m.mark()
    m.draft = "typed"
    m.menuClosed()
    #expect(e.manifest.marks.map(\.text) == ["typed"])
}

@MainActor @Test func stopSavesTheOpenCommentAndClearsTheList() async {
    let e = FakeEngine()
    let m = await markModel(e, FakeHostClock())
    m.mark()
    m.draft = "last words"
    await m.startStop()
    #expect(e.manifest.marks.map(\.text) == ["last words"])
    #expect(m.marks.isEmpty)
    #expect(m.editingMarkID == nil)
    #expect(!m.canMark)
    m.mark()
    #expect(e.manifest.marks.count == 1)
}

private final class FakeCalendar: CalendarSource, @unchecked Sendable {
    let make: @Sendable (Date) -> [CalendarEvent]
    var windows: [TimeInterval] = []

    init(_ make: @escaping @Sendable (Date) -> [CalendarEvent]) { self.make = make }

    func events(from start: Date, to end: Date) async -> [CalendarEvent] {
        windows.append(end.timeIntervalSince(start))
        return make(start)
    }
}

@MainActor @Test func recordingTakesTheCurrentEventTitleAndSavesEdits() async {
    let e = FakeEngine()
    let calendar = FakeCalendar { now in
        [
            CalendarEvent(title: "Holiday", start: now.addingTimeInterval(-3_600), end: now.addingTimeInterval(3_600), isAllDay: true),
            CalendarEvent(title: "Планёрка", start: now.addingTimeInterval(-120), end: now.addingTimeInterval(1_800)),
        ]
    }
    let renamed = URL(fileURLWithPath: "/tmp/renamed-session")
    let m = RecorderModel(
        engine: e, catalog: FakeCatalog(devices: [airpods]), enabledIDs: ["computer"], persist: { _ in },
        finalize: { _, _ in renamed }, calendar: calendar)
    m.refreshDevices()
    await m.startStop()
    #expect(calendar.windows == [900])
    #expect(m.title == "Планёрка")
    #expect(e.manifest.title == "Планёрка")
    m.setTitle("Планёрка: итоги")
    #expect(m.title == "Планёрка: итоги")
    #expect(e.manifest.title == "Планёрка: итоги")
    await m.startStop()
    #expect(m.title == "")
    await m.finishPending()
    #expect(m.lastSessionDir == renamed)
}

@MainActor @Test func withoutAnEventTheTitleIsEmpty() async {
    let e = FakeEngine()
    let m = model(e)
    await m.startStop()
    #expect(e.started.count == 1)
    #expect(m.title == "")
    #expect(e.manifest.title == "")
}

@MainActor @Test func finalizeGetsTheChosenFolderAndTheChoiceIsPersisted() async {
    let e = FakeEngine()
    nonisolated(unsafe) var outputs: [String] = []
    nonisolated(unsafe) var saved: [String] = []
    let m = RecorderModel(
        engine: e, catalog: FakeCatalog(devices: [airpods]), enabledIDs: ["computer"], persist: { _ in },
        finalize: { dir, out in outputs.append(out.path); return dir },
        outputFolder: URL(fileURLWithPath: "/tmp/out-a"), persistOutput: { saved.append($0.path) })
    m.refreshDevices()
    #expect(m.outputFolder.path == "/tmp/out-a")
    m.setOutputFolder(URL(fileURLWithPath: "/tmp/out-b"))
    #expect(m.outputFolder.path == "/tmp/out-b")
    #expect(saved == ["/tmp/out-b"])
    await m.startStop()
    await m.startStop()
    await m.finishPending()
    #expect(outputs == ["/tmp/out-b"])
}

@MainActor @Test func failedDeliveryKeepsTheLocalSessionAndWarnsUntilADeliverySucceeds() async {
    let e = FakeEngine()
    let local = URL(fileURLWithPath: "/tmp/work/2026-09-24 10-00")
    let moved = URL(fileURLWithPath: "/tmp/out/2026-09-24 10-00")
    let fail = Atomic<Bool>(true)
    let m = RecorderModel(
        engine: e, catalog: FakeCatalog(devices: [airpods]), enabledIDs: ["computer"], persist: { _ in },
        finalize: { _, _ in
            if fail.load(ordering: .relaxed) { throw DeliveryFailed(dir: local, reason: "folder not found: /tmp/out") }
            return moved
        })
    m.refreshDevices()
    await m.startStop()
    await m.startStop()
    await m.finishPending()
    #expect(m.lastSessionDir == local)
    #expect(m.errorText == nil)
    #expect(m.warning == "Saved in the local folder: folder not found: /tmp/out")
    m.menuClosed()
    #expect(m.warning == "Saved in the local folder: folder not found: /tmp/out")
    fail.store(false, ordering: .relaxed)
    await m.startStop()
    await m.startStop()
    await m.finishPending()
    #expect(m.lastSessionDir == moved)
    #expect(m.warning == nil)
}

@MainActor @Test func launchDeliveryResultSetsAndClearsTheWarning() {
    let m = model(FakeEngine())
    m.deliveryDone(failure: "folder not found: /x")
    #expect(m.warning == "Saved in the local folder: folder not found: /x")
    m.deliveryDone(failure: nil)
    #expect(m.warning == nil)
}

private struct StillScreen: ScreenGrabber {
    var permitted = true
    func allowed() -> Bool { permitted }
    func grab() async throws -> ScreenGrab { ScreenGrab(image: screen(), display: 1) }
}

@MainActor
private func slidesModel(
    _ engine: FakeEngine, on: Bool, permitted: Bool = true, persist: @escaping @Sendable (Bool) -> Void = { _ in }
) -> (RecorderModel, SlideRecorder) {
    let slides = SlideRecorder(grabber: StillScreen(permitted: permitted), interval: .milliseconds(5))
    let m = RecorderModel(
        engine: engine, catalog: FakeCatalog(devices: [airpods]), enabledIDs: ["computer", "ap"], persist: { _ in },
        finalize: { dir, _ in dir }, slides: slides, slidesOn: on, persistSlides: persist)
    m.refreshDevices()
    return (m, slides)
}

@MainActor @Test func slidesSwitchIsSavedAndLockedWhileRecording() async {
    let e = FakeEngine()
    nonisolated(unsafe) var saved: [Bool] = []
    let (m, _) = slidesModel(e, on: false) { saved.append($0) }
    m.toggleSlides()
    #expect(m.slidesOn)
    await m.startStop()
    m.toggleSlides()
    #expect(m.slidesOn)
    await m.startStop()
    m.toggleSlides()
    #expect(!m.slidesOn)
    #expect(saved == [true, false])
}

@MainActor @Test func recordingWithSlidesGrabsIntoTheEngineUntilStop() async {
    let e = FakeEngine()
    let (m, slides) = slidesModel(e, on: true)
    await m.startStop()
    #expect(e.slides == [true])
    #expect(await eventually { e.frames.withLock { $0.count } == 1 })
    #expect(slides.status == .on)
    await m.startStop()
    #expect(slides.status == nil)
    let off = FakeEngine()
    let (m2, slides2) = slidesModel(off, on: false)
    await m2.startStop()
    #expect(off.slides == [false])
    #expect(slides2.status == nil)
}

@MainActor @Test func slidesStopWhenTheSessionStopsItself() async {
    let e = FakeEngine()
    let (m, slides) = slidesModel(e, on: true)
    await m.startStop()
    #expect(slides.status == .on)
    e.phase = .idle
    m.tick()
    #expect(slides.status == nil)
}

@MainActor @Test func missingScreenPermissionIsAWarning() async {
    let e = FakeEngine()
    let (m, _) = slidesModel(e, on: true, permitted: false)
    await m.startStop()
    #expect(m.warning == "Screen: no permission (Privacy & Security > Screen & System Audio Recording)")
    #expect(e.frames.withLock { $0.isEmpty })
}

@MainActor @Test func aFailedSlideshowIsAWarningUntilSeen() async throws {
    let e = FakeEngine()
    e.dir = FileManager.default.temporaryDirectory.appendingPathComponent("sv-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: e.dir, withIntermediateDirectories: true)
    var manifest = SessionManifest(appVersion: "t", startedAt: Date(), sessionStartNanos: 1)
    manifest.finalize = FinalizeReport(
        totalFrames: 1, gaps: [], driftMillis: [:], resampled: [], slidesError: "no frames", unreadable: ["mic - A.seg001.caf"])
    try manifest.save(to: e.dir)
    let (m, _) = slidesModel(e, on: true)
    await m.startStop()
    await m.startStop()
    await m.finishPending()
    let name = e.dir.lastPathComponent
    #expect(m.warning == "\(name): Slides video failed: no frames; \(name): Could not read: mic - A.seg001.caf")
    m.menuClosed()
    #expect(m.warning == nil)
}

private final class FakeHotkey: MarkHotkey, @unchecked Sendable {
    let allowed: Bool
    var fire: (@Sendable () -> Void)?
    var stops = 0
    init(allowed: Bool = true) { self.allowed = allowed }
    func start(_ fire: @escaping @Sendable () -> Void) -> Bool {
        self.fire = fire
        return allowed
    }
    func stop() {
        stops += 1
        fire = nil
    }
}

@MainActor
private func hotkeyModel(_ engine: FakeEngine, _ hotkey: FakeHotkey) -> RecorderModel {
    let m = RecorderModel(
        engine: engine, catalog: FakeCatalog(devices: [airpods]), enabledIDs: ["computer", "ap"], persist: { _ in },
        finalize: { dir, _ in dir }, hotkey: hotkey)
    m.refreshDevices()
    return m
}

@MainActor @Test func hotkeyMarksOnlyWhileRecording() async {
    let e = FakeEngine()
    let hotkey = FakeHotkey()
    let m = hotkeyModel(e, hotkey)
    #expect(hotkey.fire == nil)
    #expect(m.hotkeyHint == nil)
    await m.startStop()
    #expect(m.hotkeyHint == "Double-tap left ⌥ to mark")
    hotkey.fire?()
    for _ in 0..<20 where m.marks.isEmpty { await Task.yield() }
    #expect(m.marks.count == 1)
    await m.startStop()
    #expect(hotkey.fire == nil)
    #expect(hotkey.stops == 1)
    #expect(m.hotkeyHint == nil)
}

@MainActor @Test func hotkeyWithoutPermissionSaysHowToAllowIt() async {
    let m = hotkeyModel(FakeEngine(), FakeHotkey(allowed: false))
    await m.startStop()
    #expect(m.hotkeyHint == "Allow Input Monitoring for the ⌥⌥ hotkey")
    #expect(m.warning == nil)
}

@MainActor @Test func hotkeyStopsWhenTheSessionStopsItself() async {
    let e = FakeEngine()
    let hotkey = FakeHotkey()
    let m = hotkeyModel(e, hotkey)
    await m.startStop()
    e.phase = .idle
    m.tick()
    m.tick()
    #expect(hotkey.stops == 1)
    #expect(hotkey.fire == nil)
}

private final class SlowStopEngine: RecordingEngine, @unchecked Sendable {
    let lock = NSLock()
    var phaseValue: RecorderPhase = .idle
    var lastSessionDir: URL?
    let gate = DispatchSemaphore(value: 0)
    let dir = URL(fileURLWithPath: "/tmp/slow-stop")
    var phase: RecorderPhase { lock.withLock { phaseValue } }

    func start(specs: [SourceSpec], backup: SourceSpec?, title: String, slides: Bool) throws -> URL {
        lock.withLock { phaseValue = .recording }
        return dir
    }

    func stop() -> URL? {
        let stopping = lock.withLock { () -> Bool in
            guard phaseValue == .recording else { return false }
            phaseValue = .stopping
            return true
        }
        guard stopping else { return nil }
        gate.wait()
        lock.withLock {
            phaseValue = .idle
            lastSessionDir = dir
        }
        return dir
    }

    func setTitle(_ title: String) {}
    func setBackup(_ spec: SourceSpec?) {}
    func status(at now: Date) -> RecorderStatus {
        RecorderStatus(phase: phase, elapsedSeconds: 1, sources: [], sessionDir: nil, lastError: nil)
    }
    func addMark(atNanos: UInt64) -> [Mark] { [] }
    func setMarkText(id: Int, _ text: String) -> [Mark] { [] }
    func removeMark(id: Int) -> [Mark] { [] }
    func addFrame(atNanos: UInt64, data: Data) throws -> Bool { false }
}

private final class Count: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    var value: Int { lock.withLock { n } }
    func add() { lock.withLock { n += 1 } }
}

@MainActor
private func slowStopModel(_ engine: SlowStopEngine, finalized: Count) -> RecorderModel {
    let m = RecorderModel(
        engine: engine, catalog: FakeCatalog(devices: [airpods]), enabledIDs: ["computer", "ap"], persist: { _ in },
        finalize: { dir, _ in
            finalized.add()
            return dir
        })
    m.refreshDevices()
    return m
}

@MainActor @Test func quitDuringAStopWaitsForItsFinalize() async {
    let e = SlowStopEngine()
    let finalized = Count()
    let m = slowStopModel(e, finalized: finalized)
    await m.startStop()
    let stopping = Task { await m.startStop() }
    while e.phase != .stopping { await Task.yield() }
    let quitDone = Mutex(false)
    let quit = Task {
        await m.prepareToQuit()
        quitDone.withLock { $0 = true }
    }
    try? await Task.sleep(for: .milliseconds(200))
    #expect(!quitDone.withLock { $0 })
    #expect(m.stopping)
    e.gate.signal()
    await quit.value
    await stopping.value
    #expect(finalized.value == 1)
    #expect(m.finishing == nil)
}

@MainActor @Test func aSecondStopDuringAStopFinalizesOnce() async {
    let e = SlowStopEngine()
    let finalized = Count()
    let m = slowStopModel(e, finalized: finalized)
    await m.startStop()
    let first = Task { await m.startStop() }
    while e.phase != .stopping { await Task.yield() }
    let second = Task { await m.startStop() }
    try? await Task.sleep(for: .milliseconds(50))
    #expect(m.stopping)
    #expect(m.recordTitle == "Stopping…")
    e.gate.signal()
    while e.phase != .idle { await Task.yield() }
    m.tick()
    await first.value
    await second.value
    await m.finishPending()
    #expect(finalized.value == 1)
    #expect(m.finishing == nil)
}

private let builtInMic = InputDevice(id: 3, uid: "bi", name: "MacBook Air Microphone", builtIn: true)

private final class Saved<T>: @unchecked Sendable {
    var values: [T] = []
}

@MainActor
private func backupModel(
    _ engine: FakeEngine, enabled: Set<String> = ["computer", "ap"], backup: String? = "bi",
    devices: [InputDevice] = [airpods, usb, builtInMic], defaultUID: String? = nil, names: [String: String] = [:],
    savedBackup: Saved<String?> = Saved(), savedNames: Saved<[String: String]> = Saved()
) -> RecorderModel {
    let m = RecorderModel(
        engine: engine, catalog: FakeCatalog(devices: devices, defaultUID: defaultUID), enabledIDs: enabled,
        names: names, persist: { _ in }, persistNames: { savedNames.values.append($0) },
        finalize: { dir, _ in dir }, backupUID: backup, persistBackup: { savedBackup.values.append($0) })
    m.refreshDevices()
    return m
}

@Test func firstLaunchPicksTheBuiltInMicAsBackup() {
    #expect(RecorderModel.backupSetting(saved: nil, devices: [airpods, builtInMic]) == "bi")
    #expect(RecorderModel.backupSetting(saved: nil, devices: [airpods, usb]) == nil)
    #expect(RecorderModel.backupSetting(saved: "", devices: [builtInMic]) == nil)
    #expect(RecorderModel.backupSetting(saved: "usb", devices: [builtInMic]) == "usb")
}

@MainActor @Test func backupChoiceIsSavedAndChangesTheBackupWhileRecording() async {
    let e = FakeEngine()
    let saved = Saved<String?>()
    let dabberMic = InputDevice(id: 9, uid: FeedDevices.micUID, name: "Dabber Mic")
    let m = backupModel(e, devices: [airpods, usb, builtInMic, dabberMic], savedBackup: saved)
    #expect(m.backupUID == "bi")
    #expect(m.backupChoices.map(\.id) == ["ap", "usb", "bi"])
    #expect(m.backupChoices.map(\.title) == ["AirPods (recorded)", "USB", "MacBook Air Microphone"])
    m.setBackup("usb")
    #expect(m.backupUID == "usb")
    #expect(saved.values == ["usb"])
    #expect(e.backupChanges.isEmpty)
    await m.startStop()
    #expect(e.backups == [SourceSpec(kind: .mic, uid: "usb", name: "USB")])
    m.setBackup("bi")
    m.setBackup("ap")
    m.setBackup(nil)
    #expect(m.backupUID == nil)
    #expect(saved.values == ["usb", "bi", "ap", nil])
    #expect(e.backupChanges == [SourceSpec(kind: .mic, uid: "bi", name: "MacBook Air Microphone"), nil, nil])
    #expect(m.backupChoices.map(\.title) == ["AirPods (recorded)", "USB", "MacBook Air Microphone"])
    await m.startStop()
    m.setBackup("usb")
    #expect(m.backupUID == "usb")
    #expect(e.backupChanges.count == 3)
}

@MainActor @Test func warningsNameTheBackupChosenWhileRecording() async {
    let e = FakeEngine()
    let m = backupModel(e)
    await m.startStop()
    m.setBackup("usb")
    let ap = SourceSpec(kind: .mic, uid: "ap", name: "AirPods")
    let bi = SourceSpec(kind: .mic, uid: "bi", name: "MacBook Air Microphone")
    let usbMic = SourceSpec(kind: .mic, uid: "usb", name: "USB")
    e.backupState = .recording
    e.snapshots = [
        SourceSnapshot(spec: ap, status: .waitingForDevice, levelDb: -160, silent: false),
        SourceSnapshot(spec: bi, status: .failed("x"), levelDb: -160, silent: false, backup: true),
        SourceSnapshot(spec: usbMic, status: .running, levelDb: -20, silent: false, backup: true),
    ]
    m.tick()
    #expect(m.warning == "AirPods: waiting for device — recording USB (backup)")
    e.backupState = .missing
    e.snapshots.removeLast()
    m.tick()
    #expect(m.warning == "AirPods: waiting for device; Backup mic USB not connected")
    m.setBackup("ap")
    e.backupState = .off
    m.tick()
    #expect(m.warning == "AirPods: waiting for device")
    let mac = SourceSpec(kind: .computer, uid: nil, name: "Computer audio")
    e.snapshots.insert(SourceSnapshot(spec: mac, status: .restarting("x"), levelDb: -160, silent: false), at: 0)
    m.tick()
    #expect(m.warning == "Mac audio: restarting (x); AirPods: waiting for device")
}

@MainActor @Test func anAbsentBackupIsListedUnderItsSavedName() {
    let m = backupModel(FakeEngine(), devices: [airpods, usb], names: ["bi": "MacBook Air Microphone"])
    #expect(m.backupChoices.last == RecorderModel.BackupChoice(id: "bi", title: "MacBook Air Microphone (not connected)"))
}

@MainActor @Test func theBackupNameIsSavedWithTheSourceNames() {
    let names = Saved<[String: String]>()
    let m = backupModel(FakeEngine(), savedNames: names)
    #expect(names.values.last == ["ap": "AirPods", "bi": "MacBook Air Microphone"])
    m.setBackup("usb")
    #expect(names.values.last == ["ap": "AirPods", "usb": "USB"])
}

@MainActor @Test func recordingPassesTheBackupUnlessItIsAlreadyRecorded() async {
    let e = FakeEngine()
    let m = backupModel(e)
    await m.startStop()
    await m.startStop()
    m.toggle("bi")
    await m.startStop()
    #expect(e.backups == [SourceSpec(kind: .mic, uid: "bi", name: "MacBook Air Microphone"), nil])
}

@MainActor @Test func theFallbackMicIsNotAlsoTheBackup() async {
    let e = FakeEngine()
    let m = backupModel(e, enabled: ["computer"], defaultUID: "bi")
    await m.startStop()
    #expect(e.started.last?.last == SourceSpec(kind: .mic, uid: "bi", name: "MacBook Air Microphone"))
    #expect(e.backups == [nil])
}

@MainActor @Test func backupWarningsNameTheLostMicAndTheBackup() async {
    let e = FakeEngine()
    let m = backupModel(e)
    await m.startStop()
    let ap = SourceSpec(kind: .mic, uid: "ap", name: "AirPods")
    let bi = SourceSpec(kind: .mic, uid: "bi", name: "MacBook Air Microphone")
    e.backupState = .recording
    e.snapshots = [
        SourceSnapshot(spec: ap, status: .waitingForDevice, levelDb: -160, silent: false),
        SourceSnapshot(spec: bi, status: .running, levelDb: -20, silent: false),
    ]
    m.tick()
    #expect(m.warning == "AirPods: waiting for device — recording MacBook Air Microphone (backup)")
    #expect(m.rows.first { $0.id == "bi" }?.showsLevel == true)
    e.snapshots[0] = SourceSnapshot(spec: ap, status: .failed("x"), levelDb: -160, silent: false)
    e.snapshots[1] = SourceSnapshot(spec: bi, status: .running, levelDb: -70, silent: true)
    m.tick()
    #expect(m.warning == "AirPods: failed (x) — recording MacBook Air Microphone (backup); MacBook Air Microphone: no signal for 10 s")
    e.backupState = .missing
    e.snapshots = [SourceSnapshot(spec: ap, status: .waitingForDevice, levelDb: -160, silent: false)]
    m.tick()
    #expect(m.warning == "AirPods: waiting for device; Backup mic MacBook Air Microphone not connected")
    e.snapshots.append(SourceSnapshot(spec: bi, status: .waitingForDevice, levelDb: -160, silent: false))
    m.tick()
    #expect(m.warning == "AirPods: waiting for device; Backup mic MacBook Air Microphone not connected")
    e.backupState = .failed("boom")
    e.snapshots[1] = SourceSnapshot(spec: bi, status: .failed("boom"), levelDb: -160, silent: false)
    m.tick()
    #expect(m.warning == "AirPods: waiting for device; Backup mic MacBook Air Microphone failed (boom)")
    e.backupState = .off
    e.snapshots = [
        SourceSnapshot(spec: ap, status: .running, levelDb: -20, silent: false),
        SourceSnapshot(spec: bi, status: .stopped, levelDb: -160, silent: false),
    ]
    m.tick()
    #expect(m.warning == nil)
}

@MainActor @Test func aMicAbsentAtRecordThatRanAndWasLostNamesTheBackup() async {
    let e = FakeEngine()
    let ext = InputDevice(id: 7, uid: "ext", name: "External")
    let m = backupModel(
        e, enabled: ["computer", "ap", "usb", "ext"], devices: [ext, builtInMic], names: ["ap": "AirPods", "usb": "USB"])
    await m.startStop()
    #expect(m.warning == "AirPods, USB not connected")
    let ap = SourceSpec(kind: .mic, uid: "ap", name: "AirPods")
    let usbMic = SourceSpec(kind: .mic, uid: "usb", name: "USB")
    let bi = SourceSpec(kind: .mic, uid: "bi", name: "MacBook Air Microphone")
    e.snapshots = [
        SourceSnapshot(spec: ap, status: .running, levelDb: -20, silent: false),
        SourceSnapshot(spec: usbMic, status: .waitingForDevice, levelDb: -160, silent: false),
    ]
    m.tick()
    #expect(m.warning == "USB not connected")
    e.backupState = .recording
    e.snapshots = [
        SourceSnapshot(spec: ap, status: .waitingForDevice, levelDb: -160, silent: false),
        SourceSnapshot(spec: usbMic, status: .waitingForDevice, levelDb: -160, silent: false),
        SourceSnapshot(spec: bi, status: .running, levelDb: -20, silent: false),
    ]
    m.tick()
    #expect(m.warning == "USB not connected; AirPods: waiting for device — recording MacBook Air Microphone (backup)")
}

@MainActor
private func absentAirPodsModel(_ e: FakeEngine) async -> RecorderModel {
    let ext = InputDevice(id: 7, uid: "ext", name: "External")
    let m = backupModel(e, enabled: ["computer", "ap", "ext"], devices: [ext, builtInMic], names: ["ap": "AirPods"])
    await m.startStop()
    return m
}

@MainActor @Test func aSleepingMicAbsentAtRecordStaysListedAsNotConnected() async {
    let e = FakeEngine()
    let m = await absentAirPodsModel(e)
    #expect(m.warning == "AirPods not connected")
    e.snapshots = [SourceSnapshot(spec: SourceSpec(kind: .mic, uid: "ap", name: "AirPods"), status: .stopped, levelDb: -160, silent: false)]
    m.tick()
    #expect(m.warning == "AirPods not connected")
}

@MainActor @Test func aRecordingBackupIsNamedEvenWithoutALostMicNote() async {
    let e = FakeEngine()
    let m = await absentAirPodsModel(e)
    e.backupState = .recording
    e.snapshots = [
        SourceSnapshot(spec: SourceSpec(kind: .mic, uid: "ap", name: "AirPods"), status: .waitingForDevice, levelDb: -160, silent: false),
        SourceSnapshot(spec: SourceSpec(kind: .mic, uid: "bi", name: "MacBook Air Microphone"), status: .running, levelDb: -20, silent: false),
    ]
    m.tick()
    #expect(m.warning == "AirPods not connected; Recording MacBook Air Microphone (backup)")
}

@MainActor @Test func menuOpenFollowsTheMenu() {
    let m = model(FakeEngine())
    #expect(!m.menuOpen)
    m.menuOpened()
    #expect(m.menuOpen)
    m.menuClosed()
    #expect(!m.menuOpen)
}
