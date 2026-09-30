public enum BackupPolicy {
    public static func active(_ mics: [SourceStatus], was: Bool) -> Bool {
        if mics.contains(where: lost) { return true }
        if mics.allSatisfy({ $0 == .running }) { return false }
        return was
    }

    private static func lost(_ status: SourceStatus) -> Bool {
        switch status {
        case .waitingForDevice, .failed: return true
        case .running, .restarting, .stopped: return false
        }
    }
}
