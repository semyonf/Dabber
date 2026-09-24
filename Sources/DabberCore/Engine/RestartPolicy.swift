import CoreAudio

public enum WatchedObject: Sendable, Equatable {
    case device
    case subDevice
    case inputStream
    case tap
    case system
}

public enum RestartPolicy {
    public static func selectors(for object: WatchedObject) -> [AudioObjectPropertySelector] {
        switch object {
        case .device:
            return [
                kAudioDevicePropertyNominalSampleRate, kAudioDevicePropertyDeviceHasChanged,
                kAudioDevicePropertyDeviceIsAlive, kAudioDevicePropertyIOStoppedAbnormally,
            ]
        case .subDevice: return [kAudioDevicePropertyDeviceIsAlive, kAudioDevicePropertyIOStoppedAbnormally]
        case .inputStream: return [kAudioStreamPropertyVirtualFormat]
        case .tap: return [kAudioTapPropertyFormat]
        case .system: return [kAudioHardwarePropertyServiceRestarted, kAudioHardwarePropertyDevices]
        }
    }

    public static func shouldRestart(_ selector: AudioObjectPropertySelector, on object: WatchedObject) -> Bool {
        selector != kAudioHardwarePropertyDevices && selectors(for: object).contains(selector)
    }
}
