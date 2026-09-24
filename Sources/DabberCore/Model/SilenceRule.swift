public struct SilenceRule: Sendable, Equatable {
    public static let thresholdDb: Double = -60
    public static let windowSeconds: Double = 10
    private var silentSince: Double?

    public init() {}

    public mutating func update(micDb: Double, computerDb: Double, now: Double) -> Bool {
        guard micDb < Self.thresholdDb, computerDb >= Self.thresholdDb else {
            silentSince = nil
            return false
        }
        let since = silentSince ?? now
        silentSince = since
        return now - since >= Self.windowSeconds
    }
}
