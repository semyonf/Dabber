import Foundation
import Observation

public protocol RecordingEngine: Sendable {
    func start(specs: [SourceSpec], backup: SourceSpec?, title: String, slides: Bool) throws -> URL
    func setTitle(_ title: String)
    func setBackup(_ spec: SourceSpec?)
    func stop() -> URL?
    func status(at now: Date) -> RecorderStatus
    var lastSessionDir: URL? { get }
    func addMark(atNanos: UInt64) -> [Mark]
    func setMarkText(id: Int, _ text: String) -> [Mark]
    func removeMark(id: Int) -> [Mark]
    func addFrame(atNanos: UInt64, data: Data) throws -> Bool
}

extension SessionRecorder: RecordingEngine {
    public func start(specs: [SourceSpec], backup: SourceSpec?, title: String, slides: Bool) throws -> URL {
        try start(specs: specs, backup: backup, title: title, slides: slides, at: Date())
    }
}

public protocol MarkHotkey: Sendable {
    func start(_ fire: @escaping @Sendable () -> Void) -> Bool
    func stop()
}

public protocol DeviceCatalog: Sendable {
    func inputs() throws -> [InputDevice]
    func defaultInputUID() -> String?
}

public struct LiveDeviceCatalog: DeviceCatalog {
    public init() {}
    public func inputs() throws -> [InputDevice] { try inputDevices() }
    public func defaultInputUID() -> String? { defaultInputDeviceUID() }
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
        public var connected = true
        public var label: String { id == RecorderModel.computerID ? "Mac audio" : name }
        public var title: String { connected ? label : "\(label) (not connected)" }
        public var showsLevel: Bool { enabled || status != nil }
    }

    public struct BackupChoice: Identifiable, Equatable, Sendable {
        public let id: String
        public let title: String
    }

    public struct MarkRow: Identifiable, Equatable, Sendable {
        public let id: Int
        public let time: String
        public let title: String
    }

    nonisolated public static let computerID = "computer"

    nonisolated public static func defaultEnabledIDs(defaultInputUID: String?) -> Set<String> {
        Set([computerID] + (defaultInputUID.map { [$0] } ?? []))
    }

    nonisolated public static func backupSetting(saved: String?, devices: [InputDevice]) -> String? {
        guard let saved else { return devices.first(where: \.builtIn)?.uid }
        return saved.isEmpty ? nil : saved
    }

    public private(set) var rows: [Row] = []
    public private(set) var phase: RecorderPhase = .idle
    public private(set) var elapsed = "0:00"
    public private(set) var warning: String?
    public private(set) var errorText: String?
    public private(set) var lastSessionDir: URL?
    public private(set) var marks: [Mark] = []
    public private(set) var editingMarkID: Int?
    public var draft = ""
    public private(set) var title = ""
    public private(set) var outputFolder: URL
    public private(set) var slidesOn: Bool
    public private(set) var menuOpen = false
    public private(set) var hotkeyAllowed: Bool?
    public private(set) var backupUID: String?

    private let engine: any RecordingEngine
    private let catalog: any DeviceCatalog
    private let persist: @Sendable (Set<String>) -> Void
    private let persistNames: @Sendable ([String: String]) -> Void
    private let finalize: @Sendable (URL, URL) throws -> URL
    private let persistOutput: @Sendable (URL) -> Void
    private let clock: @Sendable () -> UInt64
    private let calendar: any CalendarSource
    private let slides: SlideRecorder?
    private let persistSlides: @Sendable (Bool) -> Void
    private let hotkey: (any MarkHotkey)?
    private let persistBackup: @Sendable (String?) -> Void
    private var enabledIDs: Set<String>
    private var names: [String: String]
    private enum StartNote { case noneSelected(String), missing(String?), unavailable }
    private var startNote: StartNote?
    private var absentAtStart: Set<String> = []
    private var sessionMics: [SourceSpec] = []
    private var sessionBackup: SourceSpec?
    private var starting = false
    private var finalizedDir: URL?
    private var finalizeTask: Task<Void, Never>?
    private var pending: [URL] = []
    private var stopTask: Task<Void, Never>?
    private var quitting = false
    private var stopErrorSeen = false
    private var notices: [String] = []
    private var deliveryNote: String?

    public init(
        engine: any RecordingEngine, catalog: any DeviceCatalog, enabledIDs: Set<String>,
        names: [String: String] = [:],
        persist: @escaping @Sendable (Set<String>) -> Void,
        persistNames: @escaping @Sendable ([String: String]) -> Void = { _ in },
        finalize: @escaping @Sendable (URL, URL) throws -> URL = { try Delivery.finishAndDeliver($0, output: $1) },
        clock: @escaping @Sendable () -> UInt64 = HostClock.nowNanos,
        calendar: any CalendarSource = NoCalendar(),
        outputFolder: URL = AppPaths.recordingsRoot,
        persistOutput: @escaping @Sendable (URL) -> Void = { _ in },
        slides: SlideRecorder? = nil,
        slidesOn: Bool = false,
        persistSlides: @escaping @Sendable (Bool) -> Void = { _ in },
        hotkey: (any MarkHotkey)? = nil,
        backupUID: String? = nil,
        persistBackup: @escaping @Sendable (String?) -> Void = { _ in }
    ) {
        self.engine = engine
        self.catalog = catalog
        self.enabledIDs = enabledIDs
        self.names = names
        self.persist = persist
        self.persistNames = persistNames
        self.finalize = finalize
        self.clock = clock
        self.calendar = calendar
        self.outputFolder = outputFolder
        self.persistOutput = persistOutput
        self.slides = slides
        self.slidesOn = slidesOn
        self.persistSlides = persistSlides
        self.hotkey = hotkey
        self.backupUID = backupUID
        self.persistBackup = persistBackup
        lastSessionDir = engine.lastSessionDir
    }

    public var isRecording: Bool { phase != .idle }
    public var stopping: Bool { stopTask != nil }
    public var recordTitle: String {
        quitting ? "Finalizing before quit…" : stopping ? "Stopping…" : isRecording ? "■ Stop" : "● Record"
    }
    public var canStartStop: Bool {
        !quitting && !stopping && !starting && (isRecording || rows.contains(where: \.enabled))
    }
    public var canMark: Bool { phase == .recording && !stopping }
    public var finishing: String? {
        switch pending.count {
        case 0: return nil
        case 1: return "Finishing: \(pending[0].lastPathComponent)…"
        default: return "Finishing \(pending.count) recordings…"
        }
    }
    public var hotkeyHint: String? {
        guard isRecording, let hotkeyAllowed else { return nil }
        return hotkeyAllowed ? "Double-tap left ⌥ to mark" : "Allow Input Monitoring for the ⌥⌥ hotkey"
    }
    public var markRows: [MarkRow] {
        marks.enumerated().map { i, m in MarkRow(id: m.id, time: Self.format(seconds: m.seconds), title: m.title(number: i + 1)) }
    }

    public func mark() {
        let now = clock()
        guard canMark else { return }
        saveComment()
        marks = engine.addMark(atNanos: now)
        editingMarkID = marks.last?.id
    }

    public func saveComment() {
        guard let id = editingMarkID else { return }
        marks = engine.setMarkText(id: id, draft)
        editingMarkID = nil
        draft = ""
    }

    public func removeMark(_ id: Int) {
        if editingMarkID == id {
            editingMarkID = nil
            draft = ""
        }
        marks = engine.removeMark(id: id)
    }

    public func setTitle(_ text: String) {
        title = text
        engine.setTitle(text)
    }

    public func setOutputFolder(_ url: URL) {
        outputFolder = url
        persistOutput(url)
    }

    public func toggleSlides() {
        guard !isRecording else { return }
        slidesOn.toggle()
        persistSlides(slidesOn)
    }

    public var backupChoices: [BackupChoice] {
        let recorded = recordedMics
        var choices = rows.filter { $0.id != Self.computerID && !recorded.contains($0.id) }.map {
            BackupChoice(id: $0.id, title: $0.title)
        }
        if let uid = backupSelection, !choices.contains(where: { $0.id == uid }) {
            choices.append(BackupChoice(id: uid, title: "\(names[uid] ?? uid) (not connected)"))
        }
        return choices
    }

    // A recorded mic is not listed, so the picker shows None while the chosen backup is recorded.
    // The setting stays and shows again once that mic is no longer recorded.
    public var backupSelection: String? { backupUID.flatMap { recordedMics.contains($0) ? nil : $0 } }

    private var recordedMics: Set<String> { Set(rows.filter(\.enabled).map(\.id) + sessionMics.compactMap(\.uid)) }

    public func setBackup(_ uid: String?) {
        backupUID = uid
        persistBackup(uid)
        rememberNames()
        guard isRecording else { return }
        sessionBackup = backupSpec(recorded: Set(sessionMics.compactMap(\.uid)))
        engine.setBackup(sessionBackup)
        tick()
    }

    private func backupSpec(recorded: Set<String>) -> SourceSpec? {
        backupUID.flatMap { uid in
            recorded.contains(uid)
                ? nil : SourceSpec(kind: .mic, uid: uid, name: rows.first { $0.id == uid }?.name ?? names[uid] ?? uid)
        }
    }

    public func deliveryDone(failure: String?) {
        deliveryNote = failure
        tick()
    }

    public func refreshDevices() {
        let devices = ((try? catalog.inputs()) ?? []).filter { $0.uid != FeedDevices.micUID }
        var next = [Row(id: Self.computerID, name: "Computer audio", enabled: enabledIDs.contains(Self.computerID))]
        next += devices.map { Row(id: $0.uid, name: $0.name, enabled: enabledIDs.contains($0.uid)) }
        let sessionNames = Dictionary(sessionMics.compactMap { s in s.uid.map { ($0, s.name) } }, uniquingKeysWith: { a, _ in a })
        let absent = enabledIDs.union(sessionNames.keys).subtracting(next.map(\.id) + [FeedDevices.micUID]).sorted()
        next += absent.map {
            Row(id: $0, name: names[$0] ?? sessionNames[$0] ?? $0, enabled: enabledIDs.contains($0), connected: false)
        }
        for i in next.indices {
            if let old = rows.first(where: { $0.id == next[i].id }) {
                next[i].levelDb = old.levelDb
                next[i].status = old.status
                next[i].silent = old.silent
            }
        }
        rows = next
        rememberNames()
    }

    public func toggle(_ id: String) {
        guard let i = rows.firstIndex(where: { $0.id == id }) else { return }
        rows[i].enabled.toggle()
        if rows[i].enabled { enabledIDs.insert(id) } else { enabledIDs.remove(id) }
        persist(enabledIDs)
        rememberNames()
    }

    private func rememberNames() {
        let kept = enabledIDs.union(backupUID.map { [$0] } ?? [])
        var next = names.filter { kept.contains($0.key) }
        for row in rows where row.connected && row.id != Self.computerID && kept.contains(row.id) {
            next[row.id] = row.name
        }
        guard next != names else { return }
        names = next
        persistNames(next)
    }

    public func startStop() async {
        guard !starting, !quitting else { return }
        if isRecording {
            await stopAndFinalize()
        } else {
            await start()
        }
    }

    public func stopAndFinalize() async {
        if let stopTask { return await stopTask.value }
        saveComment()
        slides?.stop()
        stopHotkey()
        let engine = self.engine
        let task = Task {
            defer {
                stopTask = nil
                tick()
            }
            guard let dir = await Task.detached(operation: { engine.stop() }).value else { return }
            finalizeSession(dir)
        }
        stopTask = task
        await task.value
    }

    public func prepareToQuit() async {
        quitting = true
        while starting { try? await Task.sleep(for: .milliseconds(20)) }
        if isRecording || stopTask != nil { await stopAndFinalize() }
        await finishPending()
    }

    public func finishPending() async {
        while let finalizeTask { await finalizeTask.value }
    }

    public func menuOpened() {
        menuOpen = true
    }

    public func menuClosed() {
        menuOpen = false
        saveComment()
        guard warning != nil else { return }
        notices = []
        if phase == .idle, !stopping, pending.isEmpty { stopErrorSeen = true }
        tick()
    }

    public func recovered(_ dir: URL, _ report: FinalizeReport) {
        notices += Self.problems(report).map { "\(dir.lastPathComponent): \($0)" }
        tick()
    }

    nonisolated static func problems(_ report: FinalizeReport) -> [String] {
        (report.slidesError.map { ["Slides video failed: \($0)"] } ?? [])
            + (report.unreadable.map { ["Could not read: \($0.joined(separator: ", "))"] } ?? [])
    }

    public func recoveryFailed(_ dir: URL, _ error: any Error) {
        notices.append("Could not finish \(dir.lastPathComponent): \(error)")
        tick()
    }

    public func tick(now: Date = Date()) {
        guard !starting else { return }
        let status = engine.status(at: now)
        let stoppedItself = phase != .idle && status.phase == .idle && !stopping
        if status.phase == .idle {
            slides?.stop()
            stopHotkey()
        }
        phase = status.phase
        elapsed = Self.format(seconds: status.phase == .idle ? 0 : status.elapsedSeconds)
        var notes: [String] = []
        let connected = Set(status.sources.filter {
            if case .restarting = $0.status { return true }
            return $0.status == .running
        }.compactMap(\.spec.uid))
        let wasAbsent = !absentAtStart.isEmpty
        absentAtStart.subtract(connected)
        if status.phase == .idle || (wasAbsent && absentAtStart.isEmpty) {
            startNote = nil
            absentAtStart = []
        }
        let backupNote = status.backup == .recording ? sessionBackup.map { " — recording \($0.name) (backup)" } ?? "" : ""
        var backupNamed = false
        var next = rows
        for i in next.indices {
            let snapshot = status.sources.first { next[i].id == ($0.spec.kind == .computer ? Self.computerID : $0.spec.uid) }
            next[i].levelDb = snapshot?.levelDb ?? -160
            next[i].status = snapshot?.status
            next[i].silent = snapshot.map { $0.silent && $0.status == .running } ?? false
            guard let snapshot else { continue }
            if snapshot.status == .waitingForDevice, absentAtStart.contains(next[i].id) { continue }
            if next[i].silent { notes.append("\(next[i].label): no signal for 10 s") }
            if snapshot.backup { continue }
            if let sessionBackup, snapshot.spec.uid == sessionBackup.uid { continue }
            switch snapshot.status {
            case .restarting(let reason): notes.append("\(next[i].label): restarting (\(reason))")
            case .waitingForDevice:
                notes.append("\(next[i].label): waiting for device" + backupNote)
                backupNamed = backupNamed || !backupNote.isEmpty
            case .failed(let why):
                notes.append("\(next[i].label): failed (\(why))" + backupNote)
                backupNamed = backupNamed || !backupNote.isEmpty
            case .running, .stopped: break
            }
        }
        if let name = sessionBackup?.name {
            switch status.backup {
            case .missing: notes.append("Backup mic \(name) not connected")
            case .failed(let why): notes.append("Backup mic \(name) failed (\(why))")
            case .recording: if !backupNamed { notes.append("Recording \(name) (backup)") }
            case .off: break
            }
        }
        if next != rows { rows = next }
        if status.phase == .idle, !marks.isEmpty || editingMarkID != nil {
            marks = []
            editingMarkID = nil
            draft = ""
        }
        if status.phase == .idle, !title.isEmpty { title = "" }
        if status.phase == .idle { sessionBackup = nil }
        if status.phase == .idle, !sessionMics.isEmpty {
            sessionMics = []
            refreshDevices()
        }
        if let startNote {
            let missing = rows.filter { absentAtStart.contains($0.id) }.map(\.name).joined(separator: ", ")
            switch startNote {
            case .noneSelected(let fallback): notes.insert("No microphone selected — recording \(fallback)", at: 0)
            case .missing(let fallback): notes.insert("\(missing) not connected" + (fallback.map { " — recording \($0)" } ?? ""), at: 0)
            case .unavailable: notes.insert("No microphone available", at: 0)
            }
        }
        switch slides?.status {
        case .noPermission: notes.append("Screen: no permission (Privacy & Security > Screen & System Audio Recording)")
        case .failed(let why): notes.append("Screen: \(why)")
        case .on, nil: break
        }
        if let note = status.diskWarning { notes.append(note) }
        if let error = status.lastError, !stopErrorSeen { notes.append("stopped: \(error)") }
        if let deliveryNote { notes.append("Saved in the local folder: \(deliveryNote)") }
        notes += notices
        warning = notes.isEmpty ? nil : notes.joined(separator: "; ")
        if stoppedItself, let dir = engine.lastSessionDir, dir != finalizedDir {
            finalizeSession(dir)
        }
    }

    private func stopHotkey() {
        guard hotkeyAllowed != nil else { return }
        hotkey?.stop()
        hotkeyAllowed = nil
    }

    nonisolated public static func format(seconds: Double) -> String {
        let s = Int(seconds)
        let h = s / 3600, m = s % 3600 / 60, r = s % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, r) : String(format: "%d:%02d", m, r)
    }

    private func finalizeSession(_ dir: URL) {
        finalizedDir = dir
        phase = .idle
        pending.append(dir)
        let finalize = self.finalize
        let output = outputFolder
        let previous = finalizeTask
        finalizeTask = Task.detached(priority: .utility) {
            await previous?.value
            let result = Result { try finalize(dir, output) }
            await self.finished(dir, result)
        }
    }

    private func finished(_ dir: URL, _ result: Result<URL, any Error>) {
        switch result {
        case .success(let done):
            lastSessionDir = done
            deliveryNote = nil
        case .failure(let failed as DeliveryFailed):
            lastSessionDir = failed.dir
            deliveryNote = failed.reason
        case .failure(let error):
            lastSessionDir = dir
            errorText = "Could not finish \(dir.lastPathComponent): \(error)"
        }
        if let done = lastSessionDir, let report = (try? SessionManifest.load(from: done))?.finalize {
            notices += Self.problems(report).map { "\(done.lastPathComponent): \($0)" }
        }
        pending.removeAll { $0 == dir }
        if pending.isEmpty { finalizeTask = nil }
        tick()
    }

    private func start() async {
        refreshDevices()
        let enabled = rows.filter(\.enabled)
        var specs = enabled.map { row in
            row.id == Self.computerID
                ? SourceSpec(kind: .computer, uid: nil, name: row.name)
                : SourceSpec(kind: .mic, uid: row.id, name: row.name)
        }
        let mics = enabled.filter { $0.id != Self.computerID }
        let absent = mics.filter { !$0.connected }
        absentAtStart = Set(absent.map(\.id))
        if mics.contains(where: \.connected) {
            startNote = absent.isEmpty ? nil : .missing(nil)
        } else if let uid = catalog.defaultInputUID(), let row = rows.first(where: { $0.id == uid && $0.connected }) {
            specs.append(SourceSpec(kind: .mic, uid: row.id, name: row.name))
            startNote = absent.isEmpty ? .noneSelected(row.name) : .missing(row.name)
        } else {
            startNote = .unavailable
        }
        let backup = backupSpec(recorded: Set(specs.compactMap(\.uid)))
        let engine = self.engine
        let startSpecs = specs
        let recordSlides = slidesOn && slides != nil
        starting = true
        let now = Date()
        let events = await calendar.events(from: now, to: now.addingTimeInterval(CalendarEvent.lookahead))
        let title = CalendarEvent.pickTitle(events, at: now)
        do {
            _ = try await Task.detached { try engine.start(specs: startSpecs, backup: backup, title: title, slides: recordSlides) }.value
            if recordSlides { slides?.start { try engine.addFrame(atNanos: $0, data: $1) } }
            hotkeyAllowed = hotkey?.start { [weak self] in Task { @MainActor in self?.mark() } }
            self.title = title
            sessionMics = startSpecs.filter { $0.kind == .mic }
            sessionBackup = backupSpec(recorded: Set(startSpecs.compactMap(\.uid)))
            if sessionBackup != backup { engine.setBackup(sessionBackup) }
            stopErrorSeen = false
            finalizedDir = nil
            errorText = nil
        } catch {
            errorText = "\(error)"
        }
        starting = false
        tick()
    }
}
