import CoreAudio
import Foundation

public final class OutputIOProcRunner: @unchecked Sendable {
    public typealias Handler = @Sendable (UnsafeMutablePointer<AudioBufferList>, UnsafePointer<AudioTimeStamp>) -> Void

    private let device: AudioObjectID
    private var procID: AudioDeviceIOProcID?

    public init(device: AudioObjectID, handler: @escaping Handler) throws {
        self.device = device
        try check(
            AudioDeviceCreateIOProcIDWithBlock(&procID, device, nil) { _, _, _, output, outputTime in
                handler(output, outputTime)
            }, "create output ioproc")
        try check(AudioDeviceStart(device, procID), "start device")
    }

    public func stop() {
        guard let procID else { return }
        AudioDeviceStop(device, procID)
        AudioDeviceDestroyIOProcID(device, procID)
        self.procID = nil
    }
}
