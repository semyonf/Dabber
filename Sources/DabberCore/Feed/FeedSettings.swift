import Foundation

public enum ExclusionList {
    public static let defaultApps = ["com.apple.Safari"]
    static let helpers = ["com.apple.Safari": ["com.apple.WebKit.GPU"]]

    public static func tapBundleIDs(apps: [String], own: String?) -> [String] {
        var ids = Set(apps)
        for app in apps { ids.formUnion(helpers[app] ?? []) }
        if let own { ids.insert(own) }
        return ids.sorted()
    }
}

public struct FeedSettings: Codable, Equatable, Sendable {
    public var computerAudio: Bool
    public var micUID: String?
    public var micName: String?
    public var excludedApps: [String]

    public init(computerAudio: Bool = true, micUID: String? = nil, micName: String? = nil,
                excludedApps: [String] = ExclusionList.defaultApps) {
        self.computerAudio = computerAudio
        self.micUID = micUID
        self.micName = micName
        self.excludedApps = excludedApps
    }

    public static func firstLaunch(defaultInput: InputDevice?) -> FeedSettings {
        guard let d = defaultInput, d.uid != FeedDevices.micUID else { return FeedSettings() }
        return FeedSettings(micUID: d.uid, micName: d.name)
    }

    public static func decode(_ data: Data?) -> FeedSettings? {
        data.flatMap { try? JSONDecoder().decode(FeedSettings.self, from: $0) }
    }

    public func encoded() -> Data { (try? JSONEncoder().encode(self)) ?? Data() }
}

public struct AppEntry: Sendable, Equatable, Identifiable {
    public let bundleID: String
    public let name: String
    public var id: String { bundleID }

    public init(bundleID: String, name: String) {
        self.bundleID = bundleID
        self.name = name
    }

    public static func candidates(
        running: [AppEntry], audioBundleIDs: [String], excluded: [String], own: String?
    ) -> [AppEntry] {
        var seen = Set(excluded + [own ?? "", ""])
        var out: [AppEntry] = []
        for app in running.sorted(by: { $0.name.localizedStandardCompare($1.name) == .orderedAscending })
        where seen.insert(app.bundleID).inserted {
            out.append(app)
        }
        for id in audioBundleIDs.sorted() where seen.insert(id).inserted {
            out.append(AppEntry(bundleID: id, name: id))
        }
        return out
    }
}
