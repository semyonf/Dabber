import AppKit
import Foundation
import Observation

public protocol FeedControlling: Sendable {
    func apply(_ config: FeedConfig?)
    var status: FeedStatus { get }
    var levelDb: Double { get }
}

extension FeedEngine: FeedControlling {}

public protocol AppCatalog: Sendable {
    func running() -> [AppEntry]
    func audioBundleIDs() -> [String]
    func name(bundleID: String) -> String
}

public struct LiveAppCatalog: AppCatalog {
    public init() {}

    public func running() -> [AppEntry] {
        NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }.compactMap { app in
            app.bundleIdentifier.map { AppEntry(bundleID: $0, name: app.localizedName ?? $0) }
        }
    }

    public func audioBundleIDs() -> [String] { ((try? audioProcesses()) ?? []).map(\.bundleID) }

    public func name(bundleID: String) -> String {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
            .map { FileManager.default.displayName(atPath: $0.path) } ?? bundleID
    }
}

@MainActor @Observable
public final class FeedModel {
    public struct MicChoice: Identifiable, Equatable, Sendable {
        public let id: String
        public let name: String
        public let connected: Bool
    }

    public private(set) var isOn = false
    public private(set) var settings: FeedSettings
    public private(set) var micChoices: [MicChoice] = []
    public private(set) var driverInstalled = false
    public private(set) var excluded: [AppEntry] = []
    public private(set) var candidates: [AppEntry] = []
    public private(set) var status: FeedStatus = .off
    public private(set) var levelDb: Double = -160

    private let engine: any FeedControlling
    private let catalog: any DeviceCatalog
    private let apps: any AppCatalog
    private let ownBundleID: String?
    private let persist: @Sendable (FeedSettings) -> Void
    private var appsGeneration = 0

    public init(
        engine: any FeedControlling, catalog: any DeviceCatalog, apps: any AppCatalog, ownBundleID: String?,
        saved: FeedSettings?, firstLaunch: () -> FeedSettings, persist: @escaping @Sendable (FeedSettings) -> Void
    ) {
        self.engine = engine
        self.catalog = catalog
        self.apps = apps
        self.ownBundleID = ownBundleID
        self.settings = saved ?? firstLaunch()
        self.persist = persist
        if saved == nil { persist(settings) }
    }

    public var canTurnOn: Bool { driverInstalled && (settings.computerAudio || settings.micUID != nil) }

    public var showsDetails: Bool { isOn || (driverInstalled && !canTurnOn) }
    public var showsStatus: Bool { isOn || !driverInstalled }

    public var hasProblem: Bool {
        guard isOn else { return false }
        switch status {
        case .driverMissing, .failed: return true
        case .off, .idle, .running, .micMissing, .restarting: return !driverInstalled
        }
    }

    public var showsLevel: Bool {
        guard isOn else { return false }
        switch status {
        case .running, .micMissing: return true
        case .off, .idle, .restarting, .driverMissing, .failed: return false
        }
    }

    public var statusText: String {
        let noDriver = "Driver not installed (run scripts/install-driver.sh)"
        if !driverInstalled { return noDriver }
        switch status {
        case .off: return "Off"
        case .idle: return "Waiting for an app to use Dabber Mic"
        case .running: return "Sending"
        case .micMissing: return "Microphone missing — sending " + (settings.computerAudio ? "Mac audio only" : "silence")
        case .restarting: return "Restarting…"
        case .driverMissing: return noDriver
        case .failed(let why): return "Failed: \(why)"
        }
    }

    public func refresh() {
        let inputs = (try? catalog.inputs()) ?? []
        driverInstalled = inputs.contains { $0.uid == FeedDevices.micUID }
        var choices = inputs.filter { $0.uid != FeedDevices.micUID }.map { MicChoice(id: $0.uid, name: $0.name, connected: true) }
        if let uid = settings.micUID {
            if let live = choices.first(where: { $0.id == uid }), live.name != settings.micName {
                settings.micName = live.name
                persist(settings)
            }
            if !choices.contains(where: { $0.id == uid }) {
                choices.append(MicChoice(id: uid, name: settings.micName ?? uid, connected: false))
            }
        }
        micChoices = choices
        refreshApps()
    }

    @discardableResult
    public func refreshApps() -> Task<Void, Never> {
        excluded = settings.excludedApps.map { AppEntry(bundleID: $0, name: apps.name(bundleID: $0)) }
        appsGeneration += 1
        let generation = appsGeneration
        let apps = self.apps, excludedIDs = settings.excludedApps, own = ownBundleID
        return Task {
            let next = await Task.detached {
                AppEntry.candidates(
                    running: apps.running(), audioBundleIDs: apps.audioBundleIDs(), excluded: excludedIDs, own: own)
            }.value
            if generation == appsGeneration { candidates = next }
        }
    }

    public func setOn(_ on: Bool) {
        guard on != isOn, !on || canTurnOn else { return }
        isOn = on
        engine.apply(on ? config : nil)
    }

    public func setComputerAudio(_ on: Bool) {
        settings.computerAudio = on
        changed()
    }

    public func selectMic(_ uid: String?) {
        settings.micUID = uid
        settings.micName = uid.flatMap { id in micChoices.first { $0.id == id }?.name }
        changed()
    }

    public func exclude(_ bundleID: String) {
        guard !settings.excludedApps.contains(bundleID) else { return }
        settings.excludedApps.append(bundleID)
        changed()
    }

    public func include(_ bundleID: String) {
        settings.excludedApps.removeAll { $0 == bundleID }
        changed()
    }

    public func tick() {
        status = engine.status
        levelDb = isOn ? engine.levelDb : -160
    }

    var config: FeedConfig {
        FeedConfig(
            micUID: settings.micUID, computerAudio: settings.computerAudio,
            tapBundleIDs: ExclusionList.tapBundleIDs(apps: settings.excludedApps, own: ownBundleID))
    }

    private func changed() {
        persist(settings)
        refresh()
        if isOn { engine.apply(config) }
    }
}
