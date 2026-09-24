import CoreAudio
import Foundation

public enum FeedDevices {
    public static let micUID = "Dabber_UID"
    public static let feedUID = "Dabber_2_UID"
}

public enum FeedError: Error, Equatable, CustomStringConvertible {
    case driverMissing

    public var description: String { "Dabber Feed (\(FeedDevices.feedUID)) not present" }
}

public final class FeedAggregate: Sendable {
    public let aggregateID: AudioObjectID
    public let tapID: AudioObjectID?
    public let micID: AudioObjectID?

    public init(micUID: String?, tapExcluding bundleIDs: [String]?) throws {
        guard try deviceID(uid: FeedDevices.feedUID) != kAudioObjectUnknown else { throw FeedError.driverMissing }
        var subDevices: [[String: Any]] = [[kAudioSubDeviceUIDKey: FeedDevices.feedUID]]
        var mic: AudioObjectID?
        if let micUID {
            let id = try deviceID(uid: micUID)
            guard id != kAudioObjectUnknown else { throw SourceError.deviceMissing(micUID) }
            mic = id
            subDevices.append([kAudioSubDeviceUIDKey: micUID, kAudioSubDeviceDriftCompensationKey: 1])
        }
        var config: [String: Any] = [
            kAudioAggregateDeviceUIDKey: "local.dabber.feed.\(UUID().uuidString)",
            kAudioAggregateDeviceNameKey: "Dabber Feed Mix",
            kAudioAggregateDeviceIsPrivateKey: 1,
            kAudioAggregateDeviceMainSubDeviceKey: FeedDevices.feedUID,
            kAudioAggregateDeviceSubDeviceListKey: subDevices,
        ]
        var tap: AudioObjectID?
        if let bundleIDs {
            let t = try GlobalTap.createTap(excludingBundleIDs: bundleIDs)
            tap = t
            do {
                let uid = try getString(t, address(kAudioTapPropertyUID))
                config[kAudioAggregateDeviceTapListKey] = [[kAudioSubTapUIDKey: uid, kAudioSubTapDriftCompensationKey: 1]]
            } catch {
                AudioHardwareDestroyProcessTap(t)
                throw error
            }
        }
        var aggregate = AudioObjectID(kAudioObjectUnknown)
        let status = AudioHardwareCreateAggregateDevice(config as CFDictionary, &aggregate)
        if status != noErr {
            if let tap { AudioHardwareDestroyProcessTap(tap) }
            throw CAError(status: status, op: "create feed aggregate")
        }
        aggregateID = aggregate
        tapID = tap
        micID = mic
    }

    public var watched: [(AudioObjectID, WatchedObject)] { Self.watchList(aggregate: aggregateID, tap: tapID, mic: micID) }

    static func watchList(aggregate: AudioObjectID, tap: AudioObjectID?, mic: AudioObjectID?) -> [(AudioObjectID, WatchedObject)] {
        var list: [(AudioObjectID, WatchedObject)] = [(aggregate, .device)]
        if let tap { list.append((tap, .tap)) }
        if let mic { list.append((mic, .subDevice)) }
        return list
    }

    public func destroy() {
        AudioHardwareDestroyAggregateDevice(aggregateID)
        if let tapID { AudioHardwareDestroyProcessTap(tapID) }
    }
}
