import CoreAudio
import Foundation

public final class IOProcRunner: @unchecked Sendable {
    public typealias Handler = @Sendable (UnsafePointer<AudioBufferList>, UnsafePointer<AudioTimeStamp>) -> Void

    private let device: AudioObjectID
    private var procID: AudioDeviceIOProcID?

    public init(device: AudioObjectID, handler: @escaping Handler) throws {
        self.device = device
        try check(
            AudioDeviceCreateIOProcIDWithBlock(&procID, device, nil) { _, input, inputTime, _, _ in
                handler(input, inputTime)
            }, "create ioproc")
        try check(AudioDeviceStart(device, procID), "start device")
    }

    public func stop() {
        guard let procID else { return }
        AudioDeviceStop(device, procID)
        AudioDeviceDestroyIOProcID(device, procID)
        self.procID = nil
    }
}
