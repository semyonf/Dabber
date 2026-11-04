@preconcurrency import AVFoundation
import DabberCore
import FluidAudio
import Foundation

/// Live transcript while recording, so you can read what you just missed. Each track gets its own sliding-window
/// stream of the same Parakeet model (FluidAudio): 6 s windows with 6 s of context before and 2 s after, so a line
/// appears about 8 s after it was said. Lines are only shown; the transcript saved after Stop is made again from
/// the whole recording, which is more accurate and removes the echo of Mac audio from «Я».
///
/// Fed from the recorder's writer threads (`feed`). Never downloads: while the model is not on disk it asks
/// `ParakeetSpeech` to download it and says so in `status`.
public final class LiveTranscriber: @unchecked Sendable {
    public static let shared = LiveTranscriber()

    public struct Line: Sendable, Identifiable, Equatable {
        public let id: Int
        public let speaker: String
        public let text: String
        public let at: Date
    }

    static let keep = 100
    static let retry: TimeInterval = 30
    static let config = SlidingWindowAsrConfig(
        chunkSeconds: 6, hypothesisChunkSeconds: 1, leftContextSeconds: 6, rightContextSeconds: 2,
        minContextForConfirmation: 6, confirmationThreshold: 0.5)

    private let lock = NSLock()
    private var on = false
    private var generation = 0
    private var models: AsrModels?
    private var loading = false
    private var lastAttempt = Date.distantPast
    private var problem: String?
    private var feeds: [String: AsyncStream<[Float]>.Continuation] = [:]
    private var tasks: [Task<Void, Never>] = []
    private var recent: [Line] = []
    private var nextID = 0

    /// The newest lines last.
    public var lines: [Line] { lock.withLock { recent } }
    /// Why there are no lines, if something is wrong.
    public var status: String? { lock.withLock { problem } }
    public var isOn: Bool { lock.withLock { on } }

    /// For a new recording, or when the switch is turned on during one: forgets earlier lines and starts loading.
    public func begin() {
        lock.withLock {
            stopStreams()
            on = true
            generation += 1
            recent = []
            problem = nil
        }
        load()
    }

    /// At Stop, or when the switch is turned off. The lines stay readable until the next `begin`.
    public func end() {
        lock.withLock {
            stopStreams()
            on = false
        }
    }

    /// 48 kHz float samples of one track (interleaved when `channels` > 1).
    public func feed(track: String, speaker: String, samples: [Float], channels: Int) {
        let (continuation, needsModel): (AsyncStream<[Float]>.Continuation?, Bool) = lock.withLock {
            guard on else { return (nil, false) }
            if let existing = feeds[track] { return (existing, false) }
            guard let models else { return (nil, true) }
            let (stream, continuation) = AsyncStream<[Float]>.makeStream(bufferingPolicy: .bufferingNewest(600))
            feeds[track] = continuation
            let generation = self.generation
            tasks.append(Task.detached(priority: .utility) { [weak self] in
                await self?.run(stream, models: models, speaker: speaker, generation: generation)
            })
            return (continuation, false)
        }
        if needsModel { load() }
        continuation?.yield(Self.mono(samples, channels: channels))
    }

    /// The caller holds the lock.
    private func stopStreams() {
        for continuation in feeds.values { continuation.finish() }
        feeds = [:]
        for task in tasks { task.cancel() }
        tasks = []
    }

    private func load() {
        let start = lock.withLock {
            guard models == nil, !loading, Date().timeIntervalSince(lastAttempt) > Self.retry else { return false }
            loading = true
            lastAttempt = Date()
            return true
        }
        guard start else { return }
        Task.detached(priority: .userInitiated) {
            let version = AsrModelVersion.v3
            guard AsrModels.modelsExist(at: AsrModels.defaultCacheDirectory(for: version), version: version) else {
                ParakeetSpeech.shared.prepare()
                self.lock.withLock {
                    self.loading = false
                    self.problem = "waits for the speech model to download"
                }
                return
            }
            do {
                let models = try await AsrModels.downloadAndLoad(version: version)
                self.lock.withLock {
                    self.models = models
                    self.loading = false
                    self.problem = nil
                }
            } catch {
                self.lock.withLock {
                    self.loading = false
                    self.problem = "the speech model could not be loaded: \(error.localizedDescription)"
                }
            }
        }
    }

    private func run(_ input: AsyncStream<[Float]>, models: AsrModels, speaker: String, generation: Int) async {
        let manager = SlidingWindowAsrManager(config: Self.config)
        do {
            try await manager.loadModels(models)
            try await manager.startStreaming(source: speaker == Transcript.me ? .microphone : .system)
        } catch {
            lock.withLock { problem = "could not start: \(error.localizedDescription)" }
            return
        }
        let updates = await manager.transcriptionUpdates
        let reader = Task { [weak self] in
            for await update in updates { self?.add(update.text, speaker: speaker, generation: generation) }
        }
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false)!
        for await samples in input {
            guard !samples.isEmpty,
                  let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))
            else { continue }
            buffer.frameLength = AVAudioFrameCount(samples.count)
            samples.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
            await manager.streamAudio(buffer)
        }
        await manager.cancel()
        reader.cancel()
    }

    private func add(_ text: String, speaker: String, generation: Int) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        lock.withLock {
            guard generation == self.generation else { return }
            recent.append(Line(id: nextID, speaker: speaker, text: text, at: Date()))
            nextID += 1
            if recent.count > Self.keep { recent.removeFirst(recent.count - Self.keep) }
        }
    }

    static func mono(_ samples: [Float], channels: Int) -> [Float] {
        guard channels > 1 else { return samples }
        let frames = samples.count / channels
        var out = [Float](repeating: 0, count: frames)
        for i in 0..<frames {
            var sum: Float = 0
            for c in 0..<channels { sum += samples[i * channels + c] }
            out[i] = sum / Float(channels)
        }
        return out
    }
}
