import Foundation

public enum DiskCheck {
    public static let minimumFreeBytes: Int64 = 2_000_000_000

    public static let checkInterval: TimeInterval = 30
    public static let warnSeconds: Double = 20 * 60
    public static let stopSeconds: Double = 2 * 60

    public static let slidesBytesPerSecond = 80_000

    public static func secondsLeft(freeBytes: Int64, channels: [Int], elapsedSeconds: Double, slides: Bool = false) -> Double {
        let frames = slides ? Double(slidesBytesPerSecond) : 0
        let caf = Double(channels.reduce(0, +) * MemoryLayout<Float>.size * Timeline.rate) + frames
        let mixCopy = slides ? Double(AACWriter.bitRate(channels: 2)) / 8 : 0
        let m4a = Double((channels + [2]).map(AACWriter.bitRate).reduce(0, +)) / 8 + frames + mixCopy
        return (Double(freeBytes) - m4a * elapsedSeconds) / (caf + m4a)
    }

    public static func hasRoom(freeBytes: Int64) -> Bool { freeBytes >= minimumFreeBytes }

    public static func freeBytes(at url: URL) throws -> Int64 {
        let values = try url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values.volumeAvailableCapacityForImportantUsage ?? 0
    }
}
