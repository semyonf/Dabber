import Foundation

/// Where the broadcast extension leaves its recordings for the app: the shared App Group container.
enum Store {
    static let summaryFile = "summary.json"
    static let logFile = "log.txt"

    static var groupID: String {
        Bundle.main.object(forInfoDictionaryKey: "DabberAppGroup") as? String ?? ""
    }

    static var root: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupID)?
            .appendingPathComponent("Recordings", isDirectory: true)
    }

    static func newSession() throws -> URL {
        guard let root else { throw StoreError.noGroup(groupID) }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH-mm-ss"
        let dir = root.appendingPathComponent(formatter.string(from: Date()), isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Newest first.
    static func sessions() -> [URL] {
        guard let root,
              let dirs = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        else { return [] }
        return dirs.filter(\.hasDirectoryPath).sorted { $0.lastPathComponent > $1.lastPathComponent }
    }
}

enum StoreError: LocalizedError {
    case noGroup(String)

    var errorDescription: String? {
        switch self {
        case .noGroup(let id): "App Group \"\(id)\" is not available: check Signing & Capabilities"
        }
    }
}

/// What the extension found out about one audio track; the app shows it.
struct TrackSummary: Codable {
    var name: String
    /// One entry per file: the format changed mid-way when there are several.
    var segments: [String] = []
    var formats: [String] = []
    var buffers = 0
    var frames: Int64 = 0
    var seconds: Double = 0
    /// Holes in the timestamps longer than 50 ms, and how long they were together.
    var gaps = 0
    var gapSeconds: Double = 0
    /// Loudness of every second of the track in dBFS (RMS), from the first buffer on.
    var levels: [Int] = []

    var silentSeconds: Int { levels.filter { $0 <= -60 }.count }
    var loudest: Int? { levels.max() }
}

struct SessionSummary: Codable {
    var started: Date
    var finished: Date?
    var tracks: [TrackSummary] = []
    var videoFrames = 0
    var savedFrames = 0
    var events: [String] = []
}
