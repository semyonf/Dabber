import AppKit
import CoreAudio
import DabberCore
import DabberSpeech

final class AppDelegate: NSObject, NSApplicationDelegate {
    private static let enabledKey = "enabledSources"
    private static let namesKey = "sourceNames"
    private static let outputKey = "outputFolder"
    private static let legacyKey = "legacySessionsAdopted"
    private static let slidesKey = "recordSlides"
    private static let screenTargetKey = "screenTarget"
    private static let backupKey = "backupMic"
    private static let transcribeKey = "transcribe"

    /// On unless switched off in the menu. Read where it is used, so a change applies to the next finalize.
    nonisolated private static var transcribeOn: Bool {
        UserDefaults.standard.object(forKey: transcribeKey) as? Bool ?? true
    }
    nonisolated private static var speech: SpeechToText? { transcribeOn ? ParakeetSpeech.shared.transcribe : nil }
    /// "Clean up microphones" in the menu; on unless switched off. Read when a recording is finished.
    static let cleanMicsKey = "cleanMics"
    nonisolated private static var cleanMicsOn: Bool {
        UserDefaults.standard.object(forKey: cleanMicsKey) as? Bool ?? true
    }

    /// "Live transcript" in the menu; off unless switched on.
    static let liveKey = "liveTranscript"
    nonisolated static var liveOn: Bool { UserDefaults.standard.bool(forKey: liveKey) }
    @MainActor private static var wasRecording = false

    static let recorder = SessionRecorder(root: AppPaths.workRoot, appVersion: AppPaths.version)

    @MainActor static let model = RecorderModel(
        engine: recorder,
        catalog: LiveDeviceCatalog(),
        enabledIDs: UserDefaults.standard.stringArray(forKey: enabledKey).map(Set.init)
            ?? RecorderModel.defaultEnabledIDs(defaultInputUID: defaultInputDeviceUID()),
        names: UserDefaults.standard.dictionary(forKey: namesKey) as? [String: String] ?? [:],
        persist: { UserDefaults.standard.set(Array($0).sorted(), forKey: enabledKey) },
        persistNames: { UserDefaults.standard.set($0, forKey: namesKey) },
        finalize: {
            try Delivery.finishAndDeliver(
                $0, output: $1, speech: speech, cleanMics: cleanMicsOn, micModel: LocalVqeModel.shared.model)
        },
        calendar: EventKitCalendar(),
        outputFolder: UserDefaults.standard.string(forKey: outputKey).map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? AppPaths.recordingsRoot,
        persistOutput: { UserDefaults.standard.set($0.path, forKey: outputKey) },
        slides: SlideRecorder(grabber: LiveScreenGrabber()),
        slidesOn: UserDefaults.standard.bool(forKey: slidesKey),
        persistSlides: { UserDefaults.standard.set($0, forKey: slidesKey) },
        screenTarget: ScreenTarget.decode(UserDefaults.standard.data(forKey: screenTargetKey)),
        persistScreenTarget: { UserDefaults.standard.set($0.encoded(), forKey: screenTargetKey) },
        transcribeOn: transcribeOn,
        persistTranscribe: {
            UserDefaults.standard.set($0, forKey: transcribeKey)
            if $0 { ParakeetSpeech.shared.prepare() }
        },
        speechStatus: { ParakeetSpeech.shared.status },
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
    @MainActor private static var ticks = 0
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
        let marker = ParakeetSpeech.loadMarker(in: AppPaths.supportRoot)
        if FileManager.default.fileExists(atPath: marker.path) {
            try? FileManager.default.removeItem(at: marker)
            Self.model.speechLoadStoppedDabber()
        }
        ParakeetSpeech.shared.markLoads(in: AppPaths.supportRoot)
        if Self.transcribeOn { ParakeetSpeech.shared.prepare() }
        if Self.cleanMicsOn { LocalVqeModel.shared.prepare() }
        let pending = Finalizer.sessionFolders(root: work)
        Self.model.finishBeforeQuit(Task.detached(priority: .utility) {
            ParakeetSpeech.removeStaleTempFiles()
            let speech = Self.speech
            if speech != nil, pending.contains(where: Finalizer.needsRecovery) {
                await ParakeetSpeech.shared.waitIfCached(seconds: 60)
            }
            let failure = Delivery.recover(
                pending, work: work, output: output, speech: speech, cleanMics: Self.cleanMicsOn,
                micModel: LocalVqeModel.shared.model,
                onError: { dir, error in Task { @MainActor in Self.model.recoveryFailed(dir, error) } },
                onReport: { dir, report in Task { @MainActor in Self.model.recovered(dir, report) } })
            await MainActor.run { Self.model.deliveryDone(failure: failure) }
        })
        Task { @MainActor in
            Self.model.refreshDevices()
            Self.feed.refresh()
        }
        Self.recorder.setLiveAudio { track, kind, samples, channels in
            LiveTranscriber.shared.feed(
                track: track, speaker: kind == .mic ? Transcript.me : Transcript.others, samples: samples, channels: channels)
        }
        timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { _ in
            Task { @MainActor in
                if Self.model.isRecording != Self.wasRecording {
                    Self.wasRecording = Self.model.isRecording
                    if Self.wasRecording, Self.liveOn { LiveTranscriber.shared.begin() }
                    if !Self.wasRecording { LiveTranscriber.shared.end() }
                }
                Self.ticks += 1
                guard Self.model.menuOpen || Self.ticks % 4 == 0 else { return }
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
            ParakeetSpeech.shared.quitting()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
