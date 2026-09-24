public enum RecorderPhase: String, Sendable, Equatable { case idle, recording, stopping }

public struct SessionState: Sendable, Equatable {
    public private(set) var phase: RecorderPhase = .idle

    public init() {}

    public mutating func start() -> Bool {
        guard phase == .idle else { return false }
        phase = .recording
        return true
    }

    public mutating func stop() -> Bool {
        guard phase == .recording else { return false }
        phase = .stopping
        return true
    }

    public mutating func finished() { phase = .idle }
}
