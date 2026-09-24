import CoreAudio
import Foundation

public final class ComputerAudioSource: CaptureSource, @unchecked Sendable {
    private var tap: GlobalTap?

    public init(spec: SourceSpec, dir: URL, baseName: String) {
        super.init(spec: spec, dir: dir, baseName: baseName, channels: 2)
    }

    override func openDevice() throws -> OpenedDevice {
        let tap = try GlobalTap(excludingBundleIDs: spec.excludedBundleIDs)
        self.tap = tap
        let streams = try getArray(
            tap.aggregateID, address(kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeInput),
            filler: AudioObjectID(0))
        var watched: [(AudioObjectID, WatchedObject)] = [
            (tap.aggregateID, .device), (tap.tapID, .tap),
        ]
        if let stream = streams.first { watched.append((stream, .inputStream)) }
        return OpenedDevice(device: tap.aggregateID, format: tap.format, watched: watched)
    }

    override func closeDevice() {
        tap?.destroy()
        tap = nil
    }
}
