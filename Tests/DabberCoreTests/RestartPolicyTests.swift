import Testing
import CoreAudio
@testable import DabberCore

@Test func spikeOneTriggersRestart() {
    #expect(RestartPolicy.shouldRestart(kAudioDevicePropertyNominalSampleRate, on: .device))
    #expect(RestartPolicy.shouldRestart(kAudioDevicePropertyDeviceHasChanged, on: .device))
    #expect(RestartPolicy.shouldRestart(kAudioDevicePropertyDeviceIsAlive, on: .device))
    #expect(RestartPolicy.shouldRestart(kAudioDevicePropertyIOStoppedAbnormally, on: .device))
    #expect(RestartPolicy.shouldRestart(kAudioStreamPropertyVirtualFormat, on: .inputStream))
    #expect(RestartPolicy.shouldRestart(kAudioHardwarePropertyServiceRestarted, on: .system))
    #expect(RestartPolicy.shouldRestart(kAudioTapPropertyFormat, on: .tap))
}

@Test func spikeOneNoiseDoesNotRestart() {
    for s in ["cfgb", "cfge", "stm#", "goin", "gone", "went", "mute"] {
        let sel = s.utf8.reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        #expect(!RestartPolicy.shouldRestart(sel, on: .device), "\(s)")
    }
    #expect(!RestartPolicy.shouldRestart(kAudioStreamPropertyVirtualFormat, on: .device))
    #expect(!RestartPolicy.shouldRestart(kAudioHardwarePropertyDevices, on: .system))
}

@Test func watchedSelectorsCoverTheTriggerSet() {
    #expect(RestartPolicy.selectors(for: .system) == [kAudioHardwarePropertyServiceRestarted, kAudioHardwarePropertyDevices])
    #expect(RestartPolicy.selectors(for: .inputStream) == [kAudioStreamPropertyVirtualFormat])
    #expect(RestartPolicy.selectors(for: .subDevice) == [kAudioDevicePropertyDeviceIsAlive, kAudioDevicePropertyIOStoppedAbnormally])
}
