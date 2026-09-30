import AppKit
import CoreAudio
import DabberCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    private static let enabledKey = "enabledSources"
    private static let namesKey = "sourceNames"
    private static let outputKey = "outputFolder"
    private static let legacyKey = "legacySessionsAdopted"
    private static let slidesKey = "recordSlides"
    private static let backupKey = "backupMic"

    @MainActor static let model = RecorderModel(
        engine: SessionRecorder(root: AppPaths.workRoot, appVersion: AppPaths.version),
        catalog: LiveDeviceCatalog(),
        enabledIDs: UserDefaults.standard.stringArray(forKey: enabledKey).map(Set.init)
            ?? RecorderModel.defaultEnabledIDs(defaultInputUID: defaultInputDeviceUID()),
        names: UserDefaults.standard.dictionary(forKey: namesKey) as? [String: String] ?? [:],
        persist: { UserDefaults.standard.set(Array($0).sorted(), forKey: enabledKey) },
        persistNames: { UserDefaults.standard.set($0, forKey: namesKey) },
        calendar: EventKitCalendar(),
        outputFolder: UserDefaults.standard.string(forKey: outputKey).map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? AppPaths.recordingsRoot,
        persistOutput: { UserDefaults.standard.set($0.path, forKey: outputKey) },
        slides: SlideRecorder(grabber: LiveScreenGrabber()),
        slidesOn: UserDefaults.standard.bool(forKey: slidesKey),
        persistSlides: { UserDefaults.standard.set($0, forKey: slidesKey) },
        hotkey: LiveMarkHotkey(),
        backupUID: RecorderModel.backupSetting(
            saved: UserDefaults.standard.string(forKey: backupKey), devices: (try? inputDevices()) ?? []),
        persistBackup: { UserDefaults.standard.set($0 ?? "", forKey: backupKey) })

    private static let feedKey = "virtualMic"

    @MainActor static let feed = FeedModel(
        engine: FeedEngine(), catalog: LiveDeviceCatalog(), apps: LiveAppCatalog(),
        ownBundleID: Bundle.main.bundleIdentifier,
        saved: FeedSettings.decode(UserDefaults.standard.data(forKey: feedKey)),
        firstLaunch: {
            FeedSettings.firstLaunch(defaultInput: defaultInputDeviceUID().flatMap { uid in
                (try? inputDevices())?.first { $0.uid == uid }
            })
        },
        persist: { UserDefaults.standard.set($0.encoded(), forKey: feedKey) })

    private var timer: Timer?
    private var devices: PropertyWatcher?
    private var appObservers: [NSObjectProtocol] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        let work = AppPaths.workRoot
        let output = Self.model.outputFolder
        if output.path == AppPaths.recordingsRoot.path {
            try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        }
        let defaults = UserDefaults.standard
        if !defaults.bool(forKey: Self.legacyKey),
           (try? Delivery.adoptUnfinished(from: AppPaths.recordingsRoot, into: work)) != nil {
            defaults.set(true, forKey: Self.legacyKey)
        }
        let pending = Finalizer.sessionFolders(root: work)
        Task.detached(priority: .utility) {
            let failure = Delivery.recover(
                pending, work: work, output: output,
                onError: { dir, error in Task { @MainActor in Self.model.recoveryFailed(dir, error) } },
                onReport: { dir, report in Task { @MainActor in Self.model.recovered(dir, report) } })
            await MainActor.run { Self.model.deliveryDone(failure: failure) }
        }
        Task { @MainActor in
            Self.model.refreshDevices()
            Self.feed.refresh()
        }
        timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { _ in
            Task { @MainActor in
                Self.model.tick()
                Self.feed.tick()
            }
        }
        devices = try? PropertyWatcher(objects: [(systemObject, [kAudioHardwarePropertyDevices])]) { _, _ in
            Task { @MainActor in
                Self.model.refreshDevices()
                Self.feed.refresh()
            }
        }
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            appObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { _ in
                Task { @MainActor in Self.feed.refreshApps() }
            })
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        Task { @MainActor in
            await Self.model.prepareToQuit()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
