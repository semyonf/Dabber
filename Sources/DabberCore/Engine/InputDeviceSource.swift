import CoreAudio
import Foundation

public final class InputDeviceSource: CaptureSource, @unchecked Sendable {
    private let uid: String

    public init(spec: SourceSpec, dir: URL, baseName: String) {
        uid = spec.uid ?? ""
        super.init(spec: spec, dir: dir, baseName: baseName, channels: 1)
    }

    override func openDevice() throws -> OpenedDevice {
        let device = try deviceID(uid: uid)
        guard device != kAudioObjectUnknown else { throw SourceError.deviceMissing(uid) }
        let streams = try getArray(
            device, address(kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeInput),
            filler: AudioObjectID(0))
        guard let stream = streams.first else { throw SourceError.noInputStream(uid) }
        let format = try getValue(
            stream, address(kAudioStreamPropertyVirtualFormat), default: AudioStreamBasicDescription())
        return OpenedDevice(
            device: device, format: format,
            watched: [(device, .device), (stream, .inputStream)])
    }

    override func deviceIsPresent() -> Bool {
        ((try? deviceID(uid: uid)) ?? kAudioObjectUnknown) != kAudioObjectUnknown
    }
}
