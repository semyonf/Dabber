import Foundation
import Testing
@testable import DabberCore

private final class FakeFeed: FeedControlling, @unchecked Sendable {
    var applied: [FeedConfig?] = []
    var status: FeedStatus = .off
    var levelDb: Double = -160
    func apply(_ config: FeedConfig?) { applied.append(config) }
}

private final class Devices: DeviceCatalog, @unchecked Sendable {
    var devices: [InputDevice]
    init(_ devices: [InputDevice]) { self.devices = devices }
    func inputs() throws -> [InputDevice] { devices }
    func defaultInputUID() -> String? { nil }
}

private struct Apps: AppCatalog {
    func running() -> [AppEntry] { [AppEntry(bundleID: "us.zoom.xos", name: "zoom.us")] }
    func audioBundleIDs() -> [String] { ["com.apple.WebKit.GPU"] }
    func name(bundleID: String) -> String { bundleID == "com.apple.Safari" ? "Safari" : bundleID }
}

private let airpods = InputDevice(id: 1, uid: "ap", name: "AirPods")
private let dabberMic = InputDevice(id: 9, uid: FeedDevices.micUID, name: "Dabber Mic")

@MainActor
private func makeModel(
    _ feed: FakeFeed, devices: [InputDevice] = [airpods, dabberMic], settings: FeedSettings = FeedSettings(micUID: "ap", micName: "AirPods"),
    saved: @escaping @Sendable (FeedSettings) -> Void = { _ in }
) -> FeedModel {
    let m = FeedModel(
        engine: feed, catalog: Devices(devices), apps: Apps(), ownBundleID: "local.dabber.Dabber", saved: settings,
        firstLaunch: { FeedSettings() }, persist: saved)
    m.refresh()
    return m
}

@MainActor @Test func micPickerHidesDabberMicAndDetectsTheDriver() {
    let m = makeModel(FakeFeed())
    #expect(m.micChoices.map(\.id) == ["ap"])
    #expect(m.driverInstalled)
    #expect(m.canTurnOn)
}

@MainActor @Test func missingDriverBlocksTurningOnAndSaysSo() {
    let feed = FakeFeed()
    let m = makeModel(feed, devices: [airpods])
    #expect(!m.driverInstalled)
    m.setOn(true)
    #expect(!m.isOn)
    #expect(feed.applied.isEmpty)
    #expect(m.statusText == "Driver not installed (run scripts/install-driver.sh)")
}

@MainActor @Test func turningOnAppliesTheExpandedConfigAndOffStops() {
    let feed = FakeFeed()
    let m = makeModel(feed)
    m.setOn(true)
    m.setOn(false)
    #expect(feed.applied == [
        FeedConfig(micUID: "ap", computerAudio: true,
                   tapBundleIDs: ["com.apple.Safari", "com.apple.WebKit.GPU", "local.dabber.Dabber"]),
        nil,
    ])
}

@MainActor @Test func settingChangesPersistAndReachARunningFeed() {
    let feed = FakeFeed()
    nonisolated(unsafe) var saved: [FeedSettings] = []
    let m = makeModel(feed) { saved.append($0) }
    m.setComputerAudio(false)
    #expect(feed.applied.isEmpty)
    m.setOn(true)
    m.exclude("us.zoom.xos")
    m.include("com.apple.Safari")
    m.selectMic(nil)
    #expect(saved.last == FeedSettings(computerAudio: false, micUID: nil, micName: nil, excludedApps: ["us.zoom.xos"]))
    #expect(feed.applied.last == FeedConfig(micUID: nil, computerAudio: false, tapBundleIDs: ["local.dabber.Dabber", "us.zoom.xos"]))
    #expect(feed.applied.count == 4)
}

@MainActor @Test func excludedAndCandidateAppsAreListed() async {
    let m = makeModel(FakeFeed())
    await m.refreshApps().value
    #expect(m.excluded == [AppEntry(bundleID: "com.apple.Safari", name: "Safari")])
    #expect(m.candidates.map(\.bundleID) == ["us.zoom.xos", "com.apple.WebKit.GPU"])
    m.exclude("us.zoom.xos")
    await m.refreshApps().value
    #expect(m.candidates.map(\.bundleID) == ["com.apple.WebKit.GPU"])
}

@MainActor @Test func disconnectedMicStaysSelectableAndStatusSaysMacAudioOnly() {
    let feed = FakeFeed()
    let m = makeModel(feed, devices: [dabberMic])
    #expect(m.micChoices == [FeedModel.MicChoice(id: "ap", name: "AirPods", connected: false)])
    m.setOn(true)
    feed.status = .micMissing
    m.tick()
    #expect(m.statusText == "Microphone missing — sending Mac audio only")
}

@MainActor @Test func statusAndLevelFollowTheEngine() {
    let feed = FakeFeed()
    let m = makeModel(feed)
    feed.levelDb = -12
    m.tick()
    #expect(m.levelDb == -160)
    m.setOn(true)
    feed.status = .running
    m.tick()
    #expect(m.levelDb == -12)
    #expect(m.statusText == "Sending")
    feed.status = .restarting("nsrt")
    m.tick()
    #expect(m.statusText == "Restarting…")
}

@MainActor @Test func nothingSelectedCannotTurnOn() {
    let m = makeModel(FakeFeed(), settings: FeedSettings(computerAudio: false))
    #expect(!m.canTurnOn)
}

@MainActor @Test func firstLaunchSettingsArePersistedOnce() {
    nonisolated(unsafe) var saved: [FeedSettings] = []
    let first = FeedSettings(micUID: "ap", micName: "AirPods")
    let m = FeedModel(
        engine: FakeFeed(), catalog: Devices([airpods, dabberMic]), apps: Apps(), ownBundleID: nil, saved: nil,
        firstLaunch: { first }, persist: { saved.append($0) })
    m.refresh()
    #expect(m.settings == first)
    #expect(saved == [first])
}

@MainActor @Test func savedSettingsAreNotRewrittenOnLaunch() {
    nonisolated(unsafe) var saved: [FeedSettings] = []
    _ = makeModel(FakeFeed()) { saved.append($0) }
    #expect(saved.isEmpty)
}

@MainActor @Test func statusTextUsesPlainWords() {
    let feed = FakeFeed()
    let m = makeModel(feed)
    #expect(m.statusText == "Off")
    m.setOn(true)
    feed.status = .failed("boom")
    m.tick()
    #expect(m.statusText == "Failed: boom")
    feed.status = .driverMissing
    m.tick()
    #expect(m.statusText == "Driver not installed (run scripts/install-driver.sh)")
    m.setComputerAudio(false)
    feed.status = .micMissing
    m.tick()
    #expect(m.statusText == "Microphone missing — sending silence")
}

@MainActor @Test func detailsShowOnlyWhenOnOrNeededToTurnOn() {
    let feed = FakeFeed()
    let m = makeModel(feed)
    #expect(!m.showsDetails)
    #expect(!m.showsStatus)
    m.setOn(true)
    #expect(m.showsDetails)
    #expect(m.showsStatus)
    m.setOn(false)
    let empty = makeModel(FakeFeed(), settings: FeedSettings(computerAudio: false))
    #expect(empty.showsDetails)
    #expect(!empty.showsStatus)
    let noDriver = makeModel(FakeFeed(), devices: [airpods])
    #expect(!noDriver.showsDetails)
    #expect(noDriver.showsStatus)
}

@MainActor @Test func levelShowsOnlyWhileSending() {
    let feed = FakeFeed()
    let m = makeModel(feed)
    feed.status = .running
    m.tick()
    #expect(!m.showsLevel)
    m.setOn(true)
    m.tick()
    #expect(m.showsLevel)
    feed.status = .micMissing
    m.tick()
    #expect(m.showsLevel)
    feed.status = .restarting("x")
    m.tick()
    #expect(!m.showsLevel)
}

@MainActor @Test func feedProblemOnlyWhenTurnedOnAndFailedOrDriverMissing() {
    let feed = FakeFeed()
    let m = makeModel(feed)
    feed.status = .failed("boom")
    m.tick()
    #expect(!m.hasProblem)
    m.setOn(true)
    for (status, problem) in [
        (FeedStatus.running, false), (.micMissing, false), (.restarting("x"), false), (.off, false),
        (.failed("boom"), true), (.driverMissing, true),
    ] {
        feed.status = status
        m.tick()
        #expect(m.hasProblem == problem)
    }
}

@MainActor @Test func driverVanishingWhileOnIsAFeedProblem() {
    let feed = FakeFeed()
    let devices = Devices([airpods, dabberMic])
    let m = FeedModel(
        engine: feed, catalog: devices, apps: Apps(), ownBundleID: nil, saved: FeedSettings(micUID: "ap", micName: "AirPods"),
        firstLaunch: { FeedSettings() }, persist: { _ in })
    m.refresh()
    m.setOn(true)
    feed.status = .running
    m.tick()
    #expect(!m.hasProblem)
    devices.devices = [airpods]
    m.refresh()
    #expect(m.hasProblem)
}

private final class ThreadProbeApps: AppCatalog, @unchecked Sendable {
    private let lock = NSLock()
    private var threads: [Bool] = []
    var onMain: [Bool] { lock.withLock { threads } }
    func running() -> [AppEntry] { [AppEntry(bundleID: "us.zoom.xos", name: "zoom.us")] }
    func audioBundleIDs() -> [String] {
        lock.withLock { threads.append(Thread.isMainThread) }
        return []
    }
    func name(bundleID: String) -> String { bundleID }
}

@MainActor @Test func appCandidatesAreComputedOffTheMainThread() async {
    let apps = ThreadProbeApps()
    let m = FeedModel(
        engine: FakeFeed(), catalog: Devices([airpods, dabberMic]), apps: apps, ownBundleID: nil,
        saved: FeedSettings(), firstLaunch: { FeedSettings() }, persist: { _ in })
    m.refresh()
    for _ in 0..<200 where m.candidates.isEmpty { try? await Task.sleep(for: .milliseconds(5)) }
    #expect(m.candidates.map(\.bundleID) == ["us.zoom.xos"])
    #expect(!apps.onMain.isEmpty && !apps.onMain.contains(true))
}

@MainActor @Test func idleFeedSaysItWaitsForAnApp() {
    let feed = FakeFeed()
    let m = makeModel(feed)
    m.setOn(true)
    feed.status = .idle
    m.tick()
    #expect(m.statusText == "Waiting for an app to use Dabber Mic")
    #expect(!m.showsLevel)
    #expect(!m.hasProblem)
}
