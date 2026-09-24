import CoreAudio
import Foundation

public final class DuplexIOProcRunner: @unchecked Sendable {
    public typealias Handler = @Sendable (
        UnsafePointer<AudioBufferList>, UnsafeMutablePointer<AudioBufferList>, UnsafePointer<AudioTimeStamp>
    ) -> Void

    private let device: AudioObjectID
    private var procID: AudioDeviceIOProcID?

    public init(device: AudioObjectID, handler: @escaping Handler) throws {
        self.device = device
        try check(
            AudioDeviceCreateIOProcIDWithBlock(&procID, device, nil) { _, input, _, output, outputTime in
                handler(input, output, outputTime)
            }, "create duplex ioproc")
        do {
            try check(AudioDeviceStart(device, procID), "start device")
        } catch {
            AudioDeviceDestroyIOProcID(device, procID!)
            procID = nil
            throw error
        }
    }

    public func stop() {
        guard let procID else { return }
        AudioDeviceStop(device, procID)
        AudioDeviceDestroyIOProcID(device, procID)
        self.procID = nil
    }
}
