public enum BackupPolicy {
    public static let settleSeconds = 2.5
    public static let retrySeconds = 2.0

    public static func active(_ mics: [SourceStatus], was: Bool, calmFor: Double) -> Bool {
        if mics.contains(where: lost) { return true }
        if mics.allSatisfy({ $0 == .running }) { return was && calmFor < settleSeconds }
        return was
    }

    private static func lost(_ status: SourceStatus) -> Bool {
        switch status {
        case .waitingForDevice, .failed: return true
        case .running, .restarting, .stopped: return false
        }
    }
}
