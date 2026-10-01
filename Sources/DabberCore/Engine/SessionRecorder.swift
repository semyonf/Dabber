import Foundation

public enum RecorderError: Error, CustomStringConvertible {
    case busy
    case lowDisk(freeBytes: Int64)
    case diskFull(freeBytes: Int64)
    case noSources

    public var description: String {
        switch self {
        case .busy: return "already recording"
        case .lowDisk(let free): return "only \(free / 1_000_000) MB free, need \(DiskCheck.minimumFreeBytes / 1_000_000) MB"
        case .diskFull(let free): return "disk almost full (\(free / 1_000_000) MB free)"
        case .noSources: return "no sources selected"
        }
    }
}

public struct SourceSnapshot: Sendable, Equatable {
    public let spec: SourceSpec
    public let status: SourceStatus
    public let levelDb: Double
    public let silent: Bool
    public var backup = false
}

public enum BackupState: Sendable, Equatable {
    case off
    case recording
    case missing
    case failed(String)
}

public struct RecorderStatus: Sendable, Equatable {
    public let phase: RecorderPhase
    public let elapsedSeconds: Double
    public let sources: [SourceSnapshot]
    public let sessionDir: URL?
    public let lastError: String?
    public var diskWarning: String? = nil
    public var backup: BackupState = .off
}

public final class SessionRecorder: @unchecked Sendable {
    private struct Backup {
        var spec: SourceSpec?
        var recorded: Set<String> = []
        var made: [String: CaptureSource] = [:]
        var started: Set<String> = []
        var on = false
        var pending = 0
        var present = true
        var nextTry = Date.distantPast
        var calmSince: Date?
        var lastFailure: String?

        var source: CaptureSource? { spec?.uid.flatMap { made[$0] } }
        var isStarted: Bool { spec?.uid.map(started.contains) ?? false }
        func usable(_ spec: SourceSpec?) -> SourceSpec? { spec.flatMap { s in s.uid.flatMap { recorded.contains($0) ? nil : s } } }
        func owns(_ source: CaptureSource) -> Bool { made.values.contains { $0 === source } }
        func startedSource(_ uid: String?) -> CaptureSource? { uid.flatMap { started.contains($0) ? made[$0] : nil } }
    }

    public typealias MakeSource = @Sendable (SourceSpec, URL, String) -> CaptureSource

    public let root: URL
    public let appVersion: String
    private let makeSource: MakeSource
    private let freeBytes: @Sendable (URL) throws -> Int64
    private let devicePresent: @Sendable (String) -> Bool
    private let backupQueue = DispatchQueue(label: "dabber.backup")
    private let lock = NSLock()
    private var state = SessionState()
    private var sources: [CaptureSource] = []
    private var manifest: SessionManifest?
    private var dir: URL?
    private var startedAt: Date?
    private var silence: [String: SilenceRule] = [:]
    private var sleepWatcher: SleepWatcher?
    private var lastError: String?
    private var lastDiskCheck: Date?
    private var diskWarning: String?
    private var slides = false
    private var backup = Backup()
    private var ran: Set<ObjectIdentifier> = []
    private var sleeping = false
    public private(set) var lastSessionDir: URL?

    public init(
        root: URL, appVersion: String,
        makeSource: @escaping MakeSource = SessionRecorder.defaultSource,
        freeBytes: @escaping @Sendable (URL) throws -> Int64 = DiskCheck.freeBytes,
        devicePresent: @escaping @Sendable (String) -> Bool = { inputDeviceIsPresent(uid: $0) }
    ) {
        self.root = root
        self.appVersion = appVersion
        self.makeSource = makeSource
        self.freeBytes = freeBytes
        self.devicePresent = devicePresent
    }

    public static let defaultSource: MakeSource = { spec, dir, base in
        switch spec.kind {
        case .computer: return ComputerAudioSource(spec: spec, dir: dir, baseName: base)
        case .mic: return InputDeviceSource(spec: spec, dir: dir, baseName: base)
        }
    }

    @discardableResult
    public func start(
        specs: [SourceSpec], backup: SourceSpec? = nil, title: String = "", slides: Bool = false, at date: Date = Date()
    ) throws -> URL {
        lock.lock(); defer { lock.unlock() }
        guard state.phase == .idle else { throw RecorderError.busy }
        guard !specs.isEmpty else { throw RecorderError.noSources }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let free = try freeBytes(root)
        guard DiskCheck.hasRoom(freeBytes: free) else { throw RecorderError.lowDisk(freeBytes: free) }
        let dir = try Self.createSessionDir(in: root, name: SessionNaming.sessionName(date, title: title))
        var manifest = SessionManifest(appVersion: appVersion, startedAt: date, sessionStartNanos: HostClock.nowNanos())
        manifest.title = title
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
        for (i, source) in created.enumerated() { wire(source, index: i) }
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
        lastDiskCheck = nil
        diskWarning = nil
        self.slides = slides
        let recorded = Set(specs.compactMap(\.uid))
        self.backup = Backup(recorded: recorded)
        self.backup.spec = self.backup.usable(backup)
        ran = Set(created.filter { $0.spec.kind == .mic && $0.status == .running }.map(ObjectIdentifier.init))
        sleeping = false
        _ = state.start()
        sleepWatcher = SleepWatcher(
            willSleep: { [weak self] in self?.willSleep() },
            didWake: { [weak self] in self?.didWake() })
        try manifest.save(to: dir)
        return dir
    }

    private func wire(_ source: CaptureSource, index: Int) {
        source.writer.onSegmentsChanged = { [weak self] records in self?.segmentsChanged(index: index, records) }
        source.writer.onWriteError = { [weak self] error in self?.stopAfterError(error) }
    }

    private static func createSessionDir(in root: URL, name: String) throws -> URL {
        var n = 1
        while true {
            let dir = root.appendingPathComponent(n == 1 ? name : "\(name) \(n)")
            do {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false)
                return dir
            } catch CocoaError.fileWriteFileExists {
                n += 1
            }
        }
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
        backupQueue.sync {}
        for source in sources { source.stop() }
        lock.lock(); defer { lock.unlock() }
        for (i, source) in sources.enumerated() {
            manifest.sources[i].segments = source.writer.segments
            manifest.sources[i].restarts = source.restarts
            manifest.sources[i].overruns = source.overruns
        }
        manifest.sources.removeAll { $0.backup == true && $0.segments.isEmpty }
        try? manifest.save(to: dir)
        self.manifest = nil
        self.sources = []
        self.dir = nil
        startedAt = nil
        diskWarning = nil
        backup = Backup()
        ran = []
        lastSessionDir = dir
        state.finished()
        return dir
    }

    @discardableResult
    public func addMark(atNanos: UInt64) -> [Mark] { edit { $0.addMark(atNanos: atNanos) }?.marks ?? [] }

    @discardableResult
    public func setMarkText(id: Int, _ text: String) -> [Mark] { edit { $0.setMarkText(id: id, text) }?.marks ?? [] }

    @discardableResult
    public func removeMark(id: Int) -> [Mark] { edit { $0.removeMark(id: id) }?.marks ?? [] }

    public func setTitle(_ title: String) { _ = edit { $0.title = title } }

    @discardableResult
    public func addFrame(atNanos: UInt64, data: Data) throws -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard state.phase == .recording, var manifest, let dir else { return false }
        let frame = manifest.addFrame(atNanos: atNanos)
        let url = dir.appendingPathComponent(frame.file)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
        self.manifest = manifest
        try manifest.save(to: dir)
        return true
    }

    private func edit(_ change: (inout SessionManifest) -> Void) -> SessionManifest? {
        lock.lock(); defer { lock.unlock() }
        guard state.phase == .recording, var manifest, let dir else { return nil }
        change(&manifest)
        self.manifest = manifest
        try? manifest.save(to: dir)
        return manifest
    }

    public func status(at now: Date = Date()) -> RecorderStatus {
        lock.lock()
        let backupState = updateBackup(at: now)
        let computerDb = sources.first { $0.spec.kind == .computer }?.writer.meter.decibels ?? -160
        var snapshots: [SourceSnapshot] = []
        for source in sources {
            let db = source.writer.meter.decibels
            var silent = false
            let isBackup = backup.owns(source)
            if isBackup, !(source === backup.source && backup.on) {
                silence[source.writer.baseName] = nil
            } else if source.spec.kind == .mic {
                var rule = silence[source.writer.baseName] ?? SilenceRule()
                silent = rule.update(micDb: db, computerDb: computerDb, now: now.timeIntervalSince1970)
                silence[source.writer.baseName] = rule
            }
            snapshots.append(SourceSnapshot(spec: source.spec, status: source.status, levelDb: db, silent: silent, backup: isBackup))
        }
        let full = checkDisk(at: now)
        let status = RecorderStatus(
            phase: state.phase,
            elapsedSeconds: startedAt.map { now.timeIntervalSince($0) } ?? 0,
            sources: snapshots, sessionDir: dir, lastError: lastError, diskWarning: diskWarning, backup: backupState)
        lock.unlock()
        if let full {
            DispatchQueue.global().async { [weak self] in self?.stopAfterError(RecorderError.diskFull(freeBytes: full)) }
        }
        return status
    }

    private func updateBackup(at now: Date) -> BackupState {
        guard state.phase == .recording, let spec = backup.spec, let uid = spec.uid, let manifest else { return .off }
        for (i, source) in sources.enumerated()
        where source.spec.kind == .mic && !backup.owns(source)
            && (source.status == .running || !manifest.sources[i].segments.isEmpty) {
            ran.insert(ObjectIdentifier(source))
        }
        let mics = sources.filter { ran.contains(ObjectIdentifier($0)) }.map(\.status)
        backup.calmSince = mics.allSatisfy { $0 == .running } ? backup.calmSince ?? now : nil
        let wanted = BackupPolicy.active(
            mics, was: backup.on, calmFor: now.timeIntervalSince(backup.calmSince ?? now))
        if !sleeping {
            if wanted {
                let turningOn = !backup.on
                backup.on = true
                if turningOn || (backup.pending == 0 && backupStalled && now >= backup.nextTry) {
                    backup.pending += 1
                    backup.nextTry = now.addingTimeInterval(BackupPolicy.retrySeconds)
                    backupQueue.async { [self] in runBackup(spec, uid: uid) }
                }
            } else if backup.on {
                backup.on = false
                pauseBackup(uid)
            }
        }
        guard wanted else { return .off }
        guard let source = backup.source else { return backup.present ? .recording : .missing }
        switch source.status {
        case .running:
            backup.lastFailure = nil
            return .recording
        case .restarting: return backup.lastFailure.map { .failed($0) } ?? .recording
        case .waitingForDevice: return .missing
        case .failed(let why):
            backup.lastFailure = why
            return .failed(why)
        case .stopped: return backup.pending > 0 ? .recording : .missing
        }
    }

    public func setBackup(_ spec: SourceSpec?) {
        lock.withLock {
            let spec = backup.usable(spec)
            guard state.phase == .recording, spec?.uid != backup.spec?.uid else { return }
            if backup.on {
                backup.on = false
                pauseBackup(backup.spec?.uid)
            }
            backup.spec = spec
            backup.present = true
            backup.nextTry = .distantPast
            backup.lastFailure = nil
        }
    }

    private func pauseBackup(_ uid: String?) {
        backupQueue.async { [self] in lock.withLock { backup.startedSource(uid) }?.pause() }
    }

    private var backupStalled: Bool {
        guard let source = backup.source, backup.isStarted else { return true }
        if case .failed = source.status { return true }
        return false
    }

    private func runBackup(_ spec: SourceSpec, uid: String) {
        defer { lock.withLock { backup.pending -= 1 } }
        guard let source = backupSource(spec, uid: uid),
              lock.withLock({ state.phase == .recording && backup.on && !sleeping && backup.spec?.uid == uid })
        else { return }
        if lock.withLock({ backup.started.contains(uid) }) {
            switch source.status {
            case .stopped, .failed: resumeBackup(source, reason: "backup")
            case .running, .restarting, .waitingForDevice: break
            }
        } else if (try? source.start()) != nil {
            lock.withLock { _ = backup.started.insert(uid) }
        }
    }

    private func backupSource(_ spec: SourceSpec, uid: String) -> CaptureSource? {
        if let source = lock.withLock({ backup.made[uid] }) { return source }
        let present = devicePresent(uid)
        lock.lock(); defer { lock.unlock() }
        guard backup.spec?.uid == uid else { return nil }
        backup.present = present
        guard present, state.phase == .recording, backup.on, let dir, var manifest else { return nil }
        let base = SessionNaming.trackBase(kind: .mic, name: spec.name + " (backup)", taken: manifest.sources.map(\.trackBase))
        let source = makeSource(spec, dir, base)
        wire(source, index: sources.count)
        sources.append(source)
        manifest.sources.append(SourceManifest(
            kind: spec.kind, uid: spec.uid, name: spec.name, file: base + ".m4a",
            channels: source.writer.channels, segments: [], restarts: [], overruns: 0, backup: true))
        self.manifest = manifest
        try? manifest.save(to: dir)
        backup.made[uid] = source
        return source
    }

    func willSleep() {
        lock.withLock { sleeping = true }
        forEachSource { $0.pause() }
        backupQueue.async { [self] in lock.withLock { backup.on && backup.isStarted ? backup.source : nil }?.pause() }
    }

    func didWake() {
        lock.withLock {
            sleeping = false
            backup.pending += 1
        }
        forEachSource { $0.resume() }
        backupQueue.async { [self] in
            defer { lock.withLock { backup.pending -= 1 } }
            if let source = lock.withLock({ backup.on && backup.isStarted ? backup.source : nil }) {
                resumeBackup(source, reason: "wake")
            }
        }
    }

    private func resumeBackup(_ source: CaptureSource, reason: String) {
        source.resume(reason: reason)
        source.queue.sync {}
    }

    private func checkDisk(at now: Date) -> Int64? {
        guard state.phase == .recording, let startedAt, let dir,
              now.timeIntervalSince(lastDiskCheck ?? .distantPast) >= DiskCheck.checkInterval
        else { return nil }
        lastDiskCheck = now
        guard let free = try? freeBytes(dir) else { return nil }
        let left = DiskCheck.secondsLeft(
            freeBytes: free, channels: sources.map(\.writer.channels), elapsedSeconds: now.timeIntervalSince(startedAt),
            slides: slides)
        diskWarning = left < DiskCheck.warnSeconds
            ? "disk space low: about \(max(0, Int(left / 60))) min of recording left" : nil
        return left < DiskCheck.stopSeconds ? free : nil
    }

    private func forEachSource(_ body: (CaptureSource) -> Void) {
        lock.lock()
        let sources = self.sources.filter { !backup.owns($0) }
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
