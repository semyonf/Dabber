import Testing
import CoreAudio
@testable import DabberCore

@Test func fourCCPrintsAsciiCodes() {
    #expect(fourCC(OSStatus(bitPattern: 0x7768_6F3F)) == "who?")
    #expect(fourCC(OSStatus(-50)) == "-50")
}

@Test func systemHasADefaultOutputDevice() throws {
    let id: AudioObjectID = try getValue(
        AudioObjectID(kAudioObjectSystemObject),
        address(kAudioHardwarePropertyDefaultOutputDevice),
        default: AudioObjectID(kAudioObjectUnknown))
    #expect(id != kAudioObjectUnknown)
    #expect(!(try getString(id, address(kAudioDevicePropertyDeviceUID))).isEmpty)
}

@Test func inputDevicesHaveUIDs() throws {
    let devices = try inputDevices()
    #expect(!devices.isEmpty)
    #expect(devices.allSatisfy { !$0.uid.isEmpty })
}

@Test func ownPidMapsToAProcessObject() throws {
    #expect(try processObject(pid: getpid()) != kAudioObjectUnknown)
}

@Test func deviceUIDRoundTrips() throws {
    let first = try #require(try inputDevices().first)
    #expect(try deviceID(uid: first.uid) == first.id)
    #expect(try deviceID(uid: "no-such-device") == kAudioObjectUnknown)
}
