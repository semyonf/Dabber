import CoreAudio

public struct InputDevice: Sendable, Equatable {
    public let id: AudioObjectID
    public let uid: String
    public let name: String
    public var builtIn = false
}

public let systemObject = AudioObjectID(kAudioObjectSystemObject)

public func inputDevices() throws -> [InputDevice] {
    let ids = try getArray(systemObject, address(kAudioHardwarePropertyDevices), filler: AudioObjectID(0))
    return collectInputDevices(ids: ids, describe: describeInputDevice)
}

public func collectInputDevices(
    ids: [AudioObjectID], describe: (AudioObjectID) throws -> InputDevice?
) -> [InputDevice] {
    ids.compactMap { id in (try? describe(id)) ?? nil }.filter { !$0.uid.hasPrefix(privateAggregatePrefix) }
}

let privateAggregatePrefix = "local.dabber."

func describeInputDevice(_ id: AudioObjectID) throws -> InputDevice? {
    let streams = try getArray(
        id, address(kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeInput), filler: AudioObjectID(0))
    guard !streams.isEmpty else { return nil }
    let transport = try? getValue(id, address(kAudioDevicePropertyTransportType), default: UInt32(0))
    return InputDevice(
        id: id,
        uid: try getString(id, address(kAudioDevicePropertyDeviceUID)),
        name: try getString(id, address(kAudioObjectPropertyName)),
        builtIn: transport == kAudioDeviceTransportTypeBuiltIn)
}

public func processObject(pid: pid_t) throws -> AudioObjectID {
    var a = address(kAudioHardwarePropertyTranslatePIDToProcessObject)
    var p = pid
    var object = AudioObjectID(kAudioObjectUnknown)
    var size = UInt32(MemoryLayout<AudioObjectID>.size)
    try check(
        AudioObjectGetPropertyData(systemObject, &a, UInt32(MemoryLayout<pid_t>.size), &p, &size, &object),
        "translate pid")
    return object
}

public func deviceID(uid: String) throws -> AudioObjectID {
    var a = address(kAudioHardwarePropertyTranslateUIDToDevice)
    var cfUID = uid as CFString
    var id = AudioObjectID(kAudioObjectUnknown)
    var size = UInt32(MemoryLayout<AudioObjectID>.size)
    try withUnsafeMutablePointer(to: &cfUID) { q in
        try check(
            AudioObjectGetPropertyData(systemObject, &a, UInt32(MemoryLayout<CFString>.size), q, &size, &id),
            "translate uid")
    }
    return id
}

// Presence follows the system device list. AirPods put in the case leave the list at once, yet their
// UID still translates to the old object and DeviceIsAlive comes late or never. Input streams are not
// required here: a listed device without them is opened, fails with noInputStream and is retried,
// instead of waiting for a device list change that may never come.
public func inputDeviceIsPresent(uid: String) -> Bool {
    (try? listedDeviceID(uid: uid)) != nil
}

func listedDeviceID(uid: String) throws -> AudioObjectID? {
    try getArray(systemObject, address(kAudioHardwarePropertyDevices), filler: AudioObjectID(0))
        .first { (try? getString($0, address(kAudioDevicePropertyDeviceUID))) == uid }
}

public func defaultInputDeviceUID() -> String? {
    guard let id = try? getValue(
        systemObject, address(kAudioHardwarePropertyDefaultInputDevice), default: AudioObjectID(kAudioObjectUnknown)),
        id != kAudioObjectUnknown
    else { return nil }
    return try? getString(id, address(kAudioDevicePropertyDeviceUID))
}

public struct AudioProcess: Sendable, Equatable {
    public let pid: pid_t
    public let bundleID: String
    public let isRunningOutput: Bool
}

public func audioProcesses() throws -> [AudioProcess] {
    let ids = try getArray(systemObject, address(kAudioHardwarePropertyProcessObjectList), filler: AudioObjectID(0))
    return ids.compactMap { id in
        guard let pid = try? getValue(id, address(kAudioProcessPropertyPID), default: pid_t(-1)) else { return nil }
        let running = (try? getValue(id, address(kAudioProcessPropertyIsRunningOutput), default: UInt32(0))) ?? 0
        return AudioProcess(
            pid: pid,
            bundleID: (try? getString(id, address(kAudioProcessPropertyBundleID))) ?? "",
            isRunningOutput: running != 0)
    }
}
