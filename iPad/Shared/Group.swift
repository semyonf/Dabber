import Foundation

/// The App Group shared by the app and the broadcast extension: the extension records into `sessions`, the app
/// finishes what is there. Settings the extension needs live in the group's defaults.
enum Group {
    static var id: String { Bundle.main.object(forInfoDictionaryKey: "DabberAppGroup") as? String ?? "" }

    static var sessions: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: id)?
            .appendingPathComponent("Sessions", isDirectory: true)
    }

    static var defaults: UserDefaults { UserDefaults(suiteName: id) ?? .standard }

    static let slidesKey = "recordSlides"

    /// In a session folder while the extension records it; holds the time of the last sign of life.
    static let liveMarker = "recording"
    /// A recording whose marker is older than this was cut off: the extension was stopped or killed.
    static let liveTimeout: TimeInterval = 20

    static func isLive(_ dir: URL, now: Date = Date()) -> Bool {
        guard let text = try? String(contentsOf: dir.appendingPathComponent(liveMarker), encoding: .utf8),
              let beat = Double(text)
        else { return false }
        return now.timeIntervalSince1970 - beat < liveTimeout
    }
}
