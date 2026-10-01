import CoreAudio
import Foundation
import Synchronization

public struct FeedConfig: Sendable, Equatable {
    public var micUID: String?
    public var computerAudio: Bool
    public var tapBundleIDs: [String]

    public init(micUID: String?, computerAudio: Bool, tapBundleIDs: [String]) {
        self.micUID = micUID
        self.computerAudio = computerAudio
        self.tapBundleIDs = tapBundleIDs
    }
}

public enum FeedStatus: Sendable, Equatable {
    case off
    case idle
    case running
    case micMissing
    case restarting(String)
    case driverMissing
    case failed(String)
}

public struct OpenedFeed: Sendable {
    public let device: AudioObjectID
    public let watched: [(AudioObjectID, WatchedObject)]
    public let close: CaptureHooks.Stop

    public init(device: AudioObjectID, watched: [(AudioObjectID, WatchedObject)], close: @escaping CaptureHooks.Stop) {
        self.device = device
        self.watched = watched
        self.close = close
    }
}

public struct FeedHooks: Sendable {
    public typealias Open = @Sendable (_ config: FeedConfig, _ withMic: Bool) throws -> OpenedFeed
    public typealias StartIO = @Sendable (AudioObjectID, FeedRenderer) throws -> CaptureHooks.Stop

    public var micPresent: @Sendable (String) -> Bool
    public var micDevice: @Sendable () -> AudioObjectID?
    public var inUse: @Sendable (AudioObjectID) -> Bool
    public var open: Open
    public var startIO: StartIO
    public var watch: CaptureHooks.Watch

    public init(
        micPresent: @escaping @Sendable (String) -> Bool, micDevice: @escaping @Sendable () -> AudioObjectID?,
        inUse: @escaping @Sendable (AudioObjectID) -> Bool, open: @escaping Open, startIO: @escaping StartIO,
        watch: @escaping CaptureHooks.Watch
    ) {
        self.micPresent = micPresent
        self.micDevice = micDevice
        self.inUse = inUse
        self.open = open
        self.startIO = startIO
        self.watch = watch
    }

    public static let live = FeedHooks(
        micPresent: { inputDeviceIsPresent(uid: $0) },
        micDevice: {
            let id = (try? deviceID(uid: FeedDevices.micUID)) ?? kAudioObjectUnknown
            return id == kAudioObjectUnknown ? nil : id
        },
        inUse: { id in
            let running = try? getValue(id, address(kAudioDevicePropertyDeviceIsRunningSomewhere), default: UInt32(0))
            return (running ?? 0) != 0
        },
        open: { config, withMic in
            let aggregate = try FeedAggregate(
                micUID: withMic ? config.micUID : nil,
                tapExcluding: config.computerAudio ? config.tapBundleIDs : nil)
            return OpenedFeed(device: aggregate.aggregateID, watched: aggregate.watched) { aggregate.destroy() }
        },
        startIO: { device, renderer in
            let runner = try DuplexIOProcRunner(device: device) { input, output, time in
                renderer.render(input, output, time)
            }
            return { runner.stop() }
        },
        watch: CaptureHooks.live.watch)
}

public final class FeedEngine: @unchecked Sendable {
    let queue = DispatchQueue(label: "dabber.feed")
    var restartDelay = 0.5
    var retryDelay = 2.0
    var idleDelay = 1.0
    private let hooks: FeedHooks
    private var config: FeedConfig?
    private var opened: OpenedFeed?
    private var openedWithMic = false
    private var stopIO: CaptureHooks.Stop?
    private var stopWatcher: CaptureHooks.Stop?
    private var stopSystemWatcher: CaptureHooks.Stop?
    private var stopDemandWatcher: CaptureHooks.Stop?
    private var demandDevice: AudioObjectID?
    private var pendingIdle: DispatchWorkItem?
    private var kinds: [AudioObjectID: WatchedObject] = [:]
    private var pendingRestart: DispatchWorkItem?
    private var attempts = 0
    private let statusValue = Mutex<FeedStatus>(.off)
    private let rendererValue = Mutex<FeedRenderer?>(nil)

    public init(hooks: FeedHooks = .live) {
        self.hooks = hooks
    }

    public var status: FeedStatus { statusValue.withLock { $0 } }
    public var renderer: FeedRenderer? { rendererValue.withLock { $0 } }
    public var levelDb: Double { renderer?.meter.decibels ?? -160 }

    public func apply(_ next: FeedConfig?) {
        queue.async { self.applyLocked(next) }
    }

    public func applyAndWait(_ next: FeedConfig?) {
        queue.sync { applyLocked(next) }
    }

    private func applyLocked(_ next: FeedConfig?) {
        guard next != config else { return }
        config = next
        pendingRestart?.cancel()
        pendingRestart = nil
        pendingIdle?.cancel()
        pendingIdle = nil
        tearDown()
        attempts = 0
        guard next != nil else {
            stopSystemWatcher?()
            stopSystemWatcher = nil
            stopWatchingDemand()
            return setStatus(.off)
        }
        if stopSystemWatcher == nil {
            do {
                stopSystemWatcher = try hooks.watch([(systemObject, RestartPolicy.selectors(for: .system))]) {
                    [weak self] _, selector in
                    guard let self else { return }
                    queue.async { self.handleSystem(selector) }
                }
            } catch {
                return setStatus(.failed("\(error)"))
            }
        }
        openLocked()
    }

    private func openLocked() {
        guard let config else { return }
        let demand: AudioObjectID?
        do {
            demand = try watchDemand()
        } catch {
            return setStatus(.failed("\(error)"))
        }
        guard let demand else { return setStatus(.driverMissing) }
        guard hooks.inUse(demand) else { return setStatus(.idle) }
        let withMic = config.micUID.map(hooks.micPresent) ?? false
        do {
            let opened = try hooks.open(config, withMic)
            self.opened = opened
            openedWithMic = withMic
            let renderer = FeedRenderer()
            stopIO = try hooks.startIO(opened.device, renderer)
            rendererValue.withLock { $0 = renderer }
            kinds = Dictionary(opened.watched.map { ($0.0, $0.1) }, uniquingKeysWith: { a, _ in a })
            stopWatcher = try hooks.watch(opened.watched.map { ($0.0, RestartPolicy.selectors(for: $0.1)) }) {
                [weak self] object, selector in
                guard let self else { return }
                queue.async { self.handle(object: object, selector: selector) }
            }
        } catch FeedError.driverMissing {
            tearDown()
            return setStatus(.driverMissing)
        } catch {
            tearDown()
            attempts += 1
            if attempts < 3 {
                scheduleRestart(reason: "\(error)", after: retryDelay)
            } else {
                setStatus(.failed("\(error)"))
            }
            return
        }
        attempts = 0
        setStatus(config.micUID != nil && !withMic ? .micMissing : .running)
    }

    private func tearDown() {
        stopWatcher?()
        stopWatcher = nil
        stopIO?()
        stopIO = nil
        opened?.close()
        opened = nil
        kinds = [:]
        rendererValue.withLock { $0 = nil }
    }

    private func setStatus(_ s: FeedStatus) { statusValue.withLock { $0 = s } }

    private func watchDemand() throws -> AudioObjectID? {
        let id = hooks.micDevice()
        if id != demandDevice { stopWatchingDemand() }
        guard let id else { return nil }
        if stopDemandWatcher == nil {
            stopDemandWatcher = try hooks.watch([(id, [kAudioDevicePropertyDeviceIsRunningSomewhere])]) {
                [weak self] _, _ in
                guard let self else { return }
                queue.async { self.handleDemand() }
            }
            demandDevice = id
        }
        return id
    }

    private func stopWatchingDemand() {
        stopDemandWatcher?()
        stopDemandWatcher = nil
        demandDevice = nil
    }

    private func handleDemand() {
        guard config != nil, let demandDevice else { return }
        if hooks.inUse(demandDevice) {
            pendingIdle?.cancel()
            pendingIdle = nil
            guard opened == nil, pendingRestart == nil else { return }
            attempts = 0
            return openLocked()
        }
        guard opened != nil, pendingIdle == nil else { return }
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            pendingIdle = nil
            guard opened != nil, let device = self.demandDevice, !hooks.inUse(device) else { return }
            tearDown()
            setStatus(.idle)
        }
        pendingIdle = item
        queue.asyncAfter(deadline: .now() + idleDelay, execute: item)
    }

    private func handle(object: AudioObjectID, selector: AudioObjectPropertySelector) {
        guard config != nil, let kind = kinds[object], RestartPolicy.shouldRestart(selector, on: kind) else { return }
        scheduleRestart(reason: fourCC(selector), after: restartDelay)
    }

    private func handleSystem(_ selector: AudioObjectPropertySelector) {
        guard let config, pendingRestart == nil else { return }
        if selector != kAudioHardwarePropertyDevices {
            stopWatchingDemand()
            return scheduleRestart(reason: fourCC(selector), after: restartDelay)
        }
        if opened == nil {
            attempts = 0
            return openLocked()
        }
        let micPresent = config.micUID.map(hooks.micPresent) ?? false
        if micPresent != openedWithMic {
            scheduleRestart(reason: micPresent ? "mic returned" : "mic gone", after: restartDelay)
        }
    }

    private func scheduleRestart(reason: String, after delay: Double) {
        guard config != nil else { return }
        setStatus(.restarting(reason))
        tearDown()
        pendingRestart?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            pendingRestart = nil
            openLocked()
        }
        pendingRestart = item
        queue.asyncAfter(deadline: .now() + delay, execute: item)
    }
}
