import AppKit

public final class SleepWatcher: @unchecked Sendable {
    private var tokens: [NSObjectProtocol] = []

    public init(willSleep: @escaping @Sendable () -> Void, didWake: @escaping @Sendable () -> Void) {
        let center = NSWorkspace.shared.notificationCenter
        tokens.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: nil) { _ in willSleep() })
        tokens.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: nil) { _ in didWake() })
    }

    public func remove() {
        for t in tokens { NSWorkspace.shared.notificationCenter.removeObserver(t) }
        tokens.removeAll()
    }
}
