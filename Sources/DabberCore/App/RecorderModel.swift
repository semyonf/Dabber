import Foundation
import Observation

public protocol RecordingEngine: Sendable {
    func start(specs: [SourceSpec], title: String, slides: Bool) throws -> URL
    func setTitle(_ title: String)
    func stop() -> URL?
    func status(at now: Date) -> RecorderStatus
    var lastSessionDir: URL? { get }
    func addMark(atNanos: UInt64) -> [Mark]
    func setMarkText(id: Int, _ text: String) -> [Mark]
    func removeMark(id: Int) -> [Mark]
    func addFrame(atNanos: UInt64, data: Data) throws -> Bool
}

extension SessionRecorder: RecordingEngine {
    public func start(specs: [SourceSpec], title: String, slides: Bool) throws -> URL {
        try start(specs: specs, title: title, slides: slides, at: Date())
    }
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

    public struct MarkRow: Identifiable, Equatable, Sendable {
        public let id: Int
        public let time: String
        public let title: String
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
    public private(set) var marks: [Mark] = []
    public private(set) var editingMarkID: Int?
    public var draft = ""
    public private(set) var title = ""
    public private(set) var outputFolder: URL
    public private(set) var slidesOn: Bool

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
    private var enabledIDs: Set<String>
    private var names: [String: String]
    private enum StartNote { case noneSelected(String), missing(String?), unavailable }
    private var startNote: StartNote?
    private var absentAtStart: Set<String> = []
    private var sessionMics: [SourceSpec] = []
    private var starting = false
    private var finalizedDir: URL?
    private var finalizeTask: Task<Void, Never>?
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
        persistSlides: @escaping @Sendable (Bool) -> Void = { _ in }
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
        lastSessionDir = engine.lastSessionDir
    }

    public var isRecording: Bool { phase != .idle }
    public var recordTitle: String {
        finalizing ? (quitting ? "Finalizing before quit…" : "Finalizing…") : isRecording ? "■ Stop" : "● Record"
    }
    public var canStartStop: Bool { !finalizing && !starting && (isRecording || rows.contains(where: \.enabled)) }
    public var canMark: Bool { phase == .recording && !finalizing }
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
        var next = names.filter { enabledIDs.contains($0.key) }
        for row in rows where row.connected && row.id != Self.computerID && enabledIDs.contains(row.id) {
            next[row.id] = row.name
        }
        guard next != names else { return }
        names = next
        persistNames(next)
    }

    public func startStop() async {
        guard !starting else { return }
        if isRecording {
            await stopAndFinalize()
        } else {
            await start()
        }
    }

    public func stopAndFinalize() async {
        saveComment()
        slides?.stop()
        finalizing = true
        let engine = self.engine
        guard let dir = await Task.detached(operation: { engine.stop() }).value else {
            finalizing = finalizeTask != nil
            return
        }
        await finalizeSession(dir).value
    }

    public func prepareToQuit() async {
        quitting = true
        if isRecording { await stopAndFinalize() }
        await finalizeTask?.value
    }

    public func menuClosed() {
        saveComment()
        guard warning != nil else { return }
        notices = []
        if phase == .idle, !finalizing { stopErrorSeen = true }
        tick()
    }

    public func recoveryFailed(_ dir: URL, _ error: any Error) {
        notices.append("Could not finish \(dir.lastPathComponent): \(error)")
        tick()
    }

    public func tick(now: Date = Date()) {
        guard !starting else { return }
        let status = engine.status(at: now)
        let stoppedItself = phase != .idle && status.phase == .idle && !finalizing
        if status.phase == .idle { slides?.stop() }
        phase = status.phase
        elapsed = Self.format(seconds: status.phase == .idle ? 0 : status.elapsedSeconds)
        var notes: [String] = []
        var next = rows
        for i in next.indices {
            let snapshot = status.sources.first { next[i].id == ($0.spec.kind == .computer ? Self.computerID : $0.spec.uid) }
            next[i].levelDb = snapshot?.levelDb ?? -160
            next[i].status = snapshot?.status
            next[i].silent = snapshot?.silent ?? false
            guard let snapshot else { continue }
            if snapshot.status == .waitingForDevice, absentAtStart.contains(next[i].id) { continue }
            if snapshot.silent { notes.append("\(next[i].label): no signal for 10 s") }
            switch snapshot.status {
            case .restarting(let reason): notes.append("\(next[i].label): restarting (\(reason))")
            case .waitingForDevice: notes.append("\(next[i].label): waiting for device")
            case .failed(let why): notes.append("\(next[i].label): failed (\(why))")
            case .running, .stopped: break
            }
        }
        if next != rows { rows = next }
        let connected = Set(status.sources.filter { $0.status != .waitingForDevice }.compactMap(\.spec.uid))
        let stillAbsent = absentAtStart.subtracting(connected)
        if status.phase == .idle || (!absentAtStart.isEmpty && stillAbsent.isEmpty) {
            startNote = nil
            absentAtStart = []
        }
        if status.phase == .idle, !marks.isEmpty || editingMarkID != nil {
            marks = []
            editingMarkID = nil
            draft = ""
        }
        if status.phase == .idle, !title.isEmpty { title = "" }
        if status.phase == .idle, !sessionMics.isEmpty {
            sessionMics = []
            refreshDevices()
        }
        if let startNote {
            let missing = rows.filter { stillAbsent.contains($0.id) }.map(\.name).joined(separator: ", ")
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

    nonisolated public static func format(seconds: Double) -> String {
        let s = Int(seconds)
        let h = s / 3600, m = s % 3600 / 60, r = s % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, r) : String(format: "%d:%02d", m, r)
    }

    @discardableResult
    private func finalizeSession(_ dir: URL) -> Task<Void, Never> {
        finalizedDir = dir
        phase = .idle
        finalizing = true
        let finalize = self.finalize
        let output = outputFolder
        let task = Task {
            do {
                lastSessionDir = try await Task.detached { try finalize(dir, output) }.value
                errorText = nil
                deliveryNote = nil
            } catch let failed as DeliveryFailed {
                lastSessionDir = failed.dir
                errorText = nil
                deliveryNote = failed.reason
            } catch {
                lastSessionDir = dir
                errorText = "finalize failed: \(error)"
            }
            if let done = lastSessionDir, let why = (try? SessionManifest.load(from: done))?.finalize?.slidesError {
                notices.append("Slides video failed: \(why)")
            }
            finalizing = false
            finalizeTask = nil
            tick()
        }
        finalizeTask = task
        return task
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
        let engine = self.engine
        let startSpecs = specs
        let recordSlides = slidesOn && slides != nil
        starting = true
        let now = Date()
        let events = await calendar.events(from: now, to: now.addingTimeInterval(CalendarEvent.lookahead))
        let title = CalendarEvent.pickTitle(events, at: now)
        do {
            _ = try await Task.detached { try engine.start(specs: startSpecs, title: title, slides: recordSlides) }.value
            if recordSlides { slides?.start { try engine.addFrame(atNanos: $0, data: $1) } }
            self.title = title
            sessionMics = startSpecs.filter { $0.kind == .mic }
            stopErrorSeen = false
            errorText = nil
        } catch {
            errorText = "\(error)"
        }
        starting = false
        tick()
    }
}
