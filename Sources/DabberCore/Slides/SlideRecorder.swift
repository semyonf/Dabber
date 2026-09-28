import CoreGraphics
import Foundation

public struct ScreenGrab: @unchecked Sendable {
    public let image: CGImage
    public let display: UInt32

    public init(image: CGImage, display: UInt32) {
        self.image = image
        self.display = display
    }
}

public protocol ScreenGrabber: Sendable {
    func allowed() -> Bool
    func grab() async throws -> ScreenGrab
}

public enum ScreenStatus: Equatable, Sendable {
    case on
    case noPermission
    case failed(String)
}

public final class SlideRecorder: @unchecked Sendable {
    public static let interval = Duration.seconds(2)

    private let grabber: any ScreenGrabber
    private let interval: Duration
    private let clock: @Sendable () -> UInt64
    private let lock = NSLock()
    private var task: Task<Void, Never>?
    private var current: ScreenStatus?

    public init(
        grabber: any ScreenGrabber, interval: Duration = SlideRecorder.interval,
        clock: @escaping @Sendable () -> UInt64 = HostClock.nowNanos
    ) {
        self.grabber = grabber
        self.interval = interval
        self.clock = clock
    }

    public var status: ScreenStatus? { lock.withLock { current } }

    public func start(store: @escaping @Sendable (UInt64, Data) throws -> Bool) {
        stop()
        guard grabber.allowed() else { return set(.noPermission) }
        set(.on)
        let (grabber, interval, clock) = (self.grabber, self.interval, self.clock)
        let task = Task.detached { [weak self] in
            let sampler = FrameSampler()
            while !Task.isCancelled {
                let at = clock()
                do {
                    let grab = try await grabber.grab()
                    if let data = try sampler.offer(grab.image, display: grab.display) { _ = try store(at, data) }
                    self?.set(.on)
                } catch {
                    self?.set(.failed("\(error)"))
                }
                try? await Task.sleep(for: interval)
            }
        }
        lock.withLock { self.task = task }
    }

    public func stop() {
        lock.withLock {
            task?.cancel()
            task = nil
            current = nil
        }
    }

    private func set(_ status: ScreenStatus) {
        lock.withLock { current = status }
    }
}
