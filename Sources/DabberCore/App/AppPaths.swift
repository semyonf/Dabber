#if os(macOS)
import Foundation

public enum AppPaths {
    public static var recordingsRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Recordings/Dabber")
    }

    public static var supportRoot: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Dabber")
    }

    public static var workRoot: URL {
        supportRoot.appendingPathComponent("Sessions")
    }

    /// "1.0.0 (Screaming Ant)": the version with the release's code name, written into every recording.
    public static var version: String {
        let info = Bundle.main.infoDictionary
        let number = info?["CFBundleShortVersionString"] as? String ?? "dev"
        return codename.map { "\(number) (\($0))" } ?? number
    }

    /// The release's code name, `DabberCodename` in Info.plist.
    public static var codename: String? {
        Bundle.main.infoDictionary?["DabberCodename"] as? String
    }
}
#endif
