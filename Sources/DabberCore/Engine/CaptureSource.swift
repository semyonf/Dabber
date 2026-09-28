import CoreAudio
import Foundation
import Synchronization

public struct SourceSpec: Sendable, Equatable {
    public let kind: SourceKind
    public let uid: String?
    public let name: String
    public let excludedBundleIDs: [String]

    public init(kind: SourceKind, uid: String?, name: String, excludedBundleIDs: [String] = []) {
        self.kind = kind
        self.uid = uid
        self.name = name
        self.excludedBundleIDs = excludedBundleIDs
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
    var formatRestartDelay = 0.1
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
            } catch SourceError.deviceMissing {
                setStatus(.waitingForDevice)
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
            guard deviceIsPresent() else { return setStatus(.waitingForDevice) }
            attempts = 0
            restartLocked(reason: "wake")
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
        let formatChange = [kAudioDevicePropertyNominalSampleRate, kAudioStreamPropertyVirtualFormat].contains(selector)
        scheduleRestart(reason: fourCC(selector), after: formatChange ? formatRestartDelay : restartDelay)
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
                attempts += 1
                scheduleRestart(reason: "device returned", after: retryDelay)
            }
        } else if !present, stopIO != nil {
            pendingRestart?.cancel()
            pendingRestart = nil
            tearDown()
            setStatus(.waitingForDevice)
        }
    }
}
