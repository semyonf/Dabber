import Foundation

public enum AppPaths {
    public static var recordingsRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Recordings/Dabber")
    }

    public static var workRoot: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Dabber/Sessions")
    }

    public static var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
    }
}
