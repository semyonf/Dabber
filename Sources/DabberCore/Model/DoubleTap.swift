public struct DoubleTap: Sendable {
    public enum Key: Sendable { case down, up, other }

    public static let window = 0.4

    private var downAt: Double?
    private var lastTap: Double?

    public init() {}

    public mutating func handle(_ key: Key, at time: Double) -> Bool {
        switch key {
        case .down:
            downAt = time
        case .up:
            defer { downAt = nil }
            guard let downAt, time - downAt < Self.window else {
                lastTap = nil
                return false
            }
            if let lastTap, time - lastTap < Self.window {
                self.lastTap = nil
                return true
            }
            lastTap = time
        case .other:
            downAt = nil
            lastTap = nil
        }
        return false
    }
}
