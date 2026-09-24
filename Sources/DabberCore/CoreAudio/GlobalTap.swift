import CoreAudio
import Foundation

public final class GlobalTap: Sendable {
    public let tapID: AudioObjectID
    public let aggregateID: AudioObjectID
    public let format: AudioStreamBasicDescription

    public init(excludingBundleIDs bundleIDs: [String] = []) throws {
        let tap = try Self.createTap(excludingBundleIDs: bundleIDs)
        tapID = tap

        let tapUID = try getString(tap, address(kAudioTapPropertyUID))
        format = try getValue(tap, address(kAudioTapPropertyFormat), default: AudioStreamBasicDescription())

        let config: [String: Any] = [
            kAudioAggregateDeviceUIDKey: "local.dabber.tap.\(UUID().uuidString)",
            kAudioAggregateDeviceNameKey: "Dabber Tap",
            kAudioAggregateDeviceIsPrivateKey: 1,
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: tapUID]],
        ]
        var aggregate = AudioObjectID(kAudioObjectUnknown)
        let status = AudioHardwareCreateAggregateDevice(config as CFDictionary, &aggregate)
        if status != noErr {
            AudioHardwareDestroyProcessTap(tap)
            throw CAError(status: status, op: "create aggregate")
        }
        aggregateID = aggregate
    }

    public static func createTap(excludingBundleIDs bundleIDs: [String]) throws -> AudioObjectID {
        let me = try processObject(pid: getpid())
        let description = Self.description(
            excludingProcesses: me == kAudioObjectUnknown ? [] : [me], bundleIDs: bundleIDs)
        var tap = AudioObjectID(kAudioObjectUnknown)
        try check(AudioHardwareCreateProcessTap(description, &tap), "create process tap")
        return tap
    }

    static func description(excludingProcesses processes: [AudioObjectID], bundleIDs: [String]) -> CATapDescription {
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: processes)
        description.uuid = UUID()
        description.isPrivate = true
        description.muteBehavior = .unmuted
        if !bundleIDs.isEmpty {
            description.bundleIDs = bundleIDs
            description.isProcessRestoreEnabled = true
        }
        return description
    }

    public func destroy() {
        AudioHardwareDestroyAggregateDevice(aggregateID)
        AudioHardwareDestroyProcessTap(tapID)
    }
}
