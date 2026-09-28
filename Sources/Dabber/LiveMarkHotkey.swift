import AppKit
import DabberCore

final class LiveMarkHotkey: MarkHotkey, @unchecked Sendable {
    private static let rightOption: Int64 = 61
    private static let modifiers: CGEventFlags = [.maskShift, .maskControl, .maskAlternate, .maskCommand, .maskSecondaryFn]

    private let lock = NSLock()
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var detector = DoubleTap()
    private var fire: (@Sendable () -> Void)?

    func start(_ fire: @escaping @Sendable () -> Void) -> Bool {
        stop()
        guard CGPreflightListenEventAccess() || CGRequestListenEventAccess() else { return false }
        let mask = CGEventMask(1 << CGEventType.flagsChanged.rawValue) | CGEventMask(1 << CGEventType.keyDown.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly, eventsOfInterest: mask,
            callback: { _, type, event, info in
                if let info { Unmanaged<LiveMarkHotkey>.fromOpaque(info).takeUnretainedValue().handle(type, event) }
                return Unmanaged.passUnretained(event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque())
        else { return false }
        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        lock.withLock {
            self.tap = tap
            self.source = source
            self.fire = fire
            detector = DoubleTap()
        }
        return true
    }

    func stop() {
        lock.withLock {
            if let tap {
                CGEvent.tapEnable(tap: tap, enable: false)
                CFMachPortInvalidate(tap)
            }
            if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
            tap = nil
            source = nil
            fire = nil
        }
    }

    private func handle(_ type: CGEventType, _ event: CGEvent) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            lock.withLock { if let tap { CGEvent.tapEnable(tap: tap, enable: true) } }
            return
        }
        var key = DoubleTap.Key.other
        if type == .flagsChanged, event.getIntegerValueField(.keyboardEventKeycode) == Self.rightOption {
            let held = event.flags.intersection(Self.modifiers)
            key = held == .maskAlternate ? .down : held.isEmpty ? .up : .other
        }
        let time = Double(event.timestamp) / 1e9
        guard let fired = lock.withLock({ detector.handle(key, at: time) ? fire : nil }) else { return }
        NSSound(named: "Morse")?.play()
        fired()
    }
}
