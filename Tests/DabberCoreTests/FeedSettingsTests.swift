import Foundation
import Testing
@testable import DabberCore

@Test func safariExpandsToItsWebKitAudioHelperAndDabberIsAlwaysExcluded() {
    #expect(ExclusionList.tapBundleIDs(apps: ["com.apple.Safari"], own: "local.dabber.Dabber")
        == ["com.apple.Safari", "com.apple.WebKit.GPU", "local.dabber.Dabber"])
}

@Test func otherAppsAreExcludedAsIs() {
    #expect(ExclusionList.tapBundleIDs(apps: ["us.zoom.xos", "us.zoom.xos"], own: nil) == ["us.zoom.xos"])
}

@Test func defaultSettingsExcludeSafariAndSendComputerAudio() {
    let s = FeedSettings()
    #expect(s.excludedApps == ["com.apple.Safari"])
    #expect(s.computerAudio)
    #expect(s.micUID == nil)
}

@Test func firstLaunchPicksTheDefaultInputButNeverDabberMic() {
    #expect(FeedSettings.firstLaunch(defaultInput: InputDevice(id: 1, uid: "ap", name: "AirPods")).micUID == "ap")
    #expect(FeedSettings.firstLaunch(defaultInput: InputDevice(id: 2, uid: FeedDevices.micUID, name: "Dabber Mic")).micUID == nil)
    #expect(FeedSettings.firstLaunch(defaultInput: nil).micUID == nil)
}

@Test func settingsRoundTrip() {
    let s = FeedSettings(computerAudio: false, micUID: "ap", micName: "AirPods", excludedApps: ["us.zoom.xos"])
    #expect(FeedSettings.decode(s.encoded()) == s)
    #expect(FeedSettings.decode(nil) == nil)
    #expect(FeedSettings.decode(Data("junk".utf8)) == nil)
}

@Test func candidatesAreRunningAppsThenOtherAudioProcessesWithoutExcludedOrOwn() {
    let list = AppEntry.candidates(
        running: [AppEntry(bundleID: "us.zoom.xos", name: "zoom.us"), AppEntry(bundleID: "com.apple.Music", name: "Music"),
                  AppEntry(bundleID: "com.apple.Safari", name: "Safari")],
        audioBundleIDs: ["com.apple.WebKit.GPU", "us.zoom.xos", "", "local.dabber.Dabber"],
        excluded: ["com.apple.Safari"], own: "local.dabber.Dabber")
    #expect(list.map(\.bundleID) == ["com.apple.Music", "us.zoom.xos", "com.apple.WebKit.GPU"])
}
