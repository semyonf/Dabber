import DabberCore
import FluidAudio
import Foundation

/// LocalVQE v1.3 (FluidAudio, Core ML on the CPU): removes the echo of Mac audio, noise and room from microphone
/// tracks after Stop. The model (about 19 MB, kept in FluidAudio's cache in Application Support) is downloaded and
/// loaded in the background by `prepare()`. Like Parakeet, finalize never waits for a download: while the model is
/// not loaded, `open` starts the load and throws, and that recording is cleaned by `MicCleaner`.
public final class LocalVqeModel: @unchecked Sendable {
    public static let shared = LocalVqeModel()

    public enum ModelError: LocalizedError {
        case notReady(String?)

        public var errorDescription: String? {
            switch self {
            case .notReady(nil): "the model is not loaded yet"
            case .notReady(let why?): "the model could not be loaded: \(why)"
            }
        }
    }

    private static let config = LocalVqeConfig(variant: .v13, chunk: .batch256ms)
    private static let maxFailures = 3
    private let lock = NSLock()
    private var manager: LocalVqeManager?
    private var loading = false
    private var loadError: String?
    private var failures = 0

    /// Starts the download and load in the background; free to call again. Gives up after three failures in one run.
    public func prepare() {
        let start = lock.withLock {
            guard manager == nil, !loading, failures < Self.maxFailures else { return false }
            loading = true
            loadError = nil
            return true
        }
        guard start else { return }
        Task.detached(priority: .utility) {
            let result: Result<LocalVqeManager, any Error>
            do { result = .success(try await LocalVqeManager(config: Self.config)) } catch { result = .failure(error) }
            self.lock.withLock {
                switch result {
                case .success(let manager): self.manager = manager
                case .failure(let error):
                    self.loadError = error.localizedDescription
                    self.failures += 1
                }
                self.loading = false
            }
        }
    }

    /// Starts the load and waits for it, at most `seconds`: for a device that finishes recordings right after
    /// launch (the iPad app), where the first recording would otherwise get the older cleaner.
    public func waitUntilLoaded(seconds: Double) async {
        prepare()
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            let (ready, busy) = lock.withLock { (manager != nil, loading) }
            if ready || !busy { return }
            do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
        }
    }

    /// For `Finalizer`: a stream for one track.
    public var model: MicModel { { try self.open() } }

    func open() throws -> any MicModelStream {
        let (manager, failure) = lock.withLock { (self.manager, loadError) }
        guard let manager else {
            prepare()
            throw ModelError.notReady(failure)
        }
        let stream = try blocking { try await manager.makeStream() }
        return Track(stream: stream, buffering: Self.config.chunk.samplesPerCall + LocalVqeManager.hopSize)
    }

    /// Finalizer is synchronous and cleans the tracks side by side on its own threads; each push waits for the model.
    private final class Track: MicModelStream {
        let stream: LocalVqeStream
        let buffering: Int

        init(stream: LocalVqeStream, buffering: Int) {
            self.stream = stream
            self.buffering = buffering
        }

        func enhance(mic: [Float], reference: [Float]) throws -> [Float] {
            let stream = self.stream
            return try blocking { try await stream.enhance(mic: mic, reference: reference) }
        }
    }
}
