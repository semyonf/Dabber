@preconcurrency import AVFoundation
import DabberCore
import FluidAudio
import Foundation
import os

/// Live transcript while recording, so you can read what you just missed. Each track gets its own sliding-window
/// stream of the same Parakeet model (FluidAudio): 6 s windows with 6 s of context before and 2 s after, so a line
/// appears about 8 s after it was said. Lines are only shown; the transcript saved after Stop is made again from
/// the whole recording, which is more accurate and removes the echo of Mac audio from «Я».
///
/// `feed` only appends to a buffer under a lock: it is called for every 50 ms of every track, and must never block
/// or grow without bound. The audio is taken to 16 kHz mono there (the model's rate), and each track's task hands it
/// to the model half a second at a time. While the model is busy with a window it takes no audio; if a track falls
/// more than 20 s behind, the oldest audio is dropped and `status` says so.
///
/// Never downloads: while the model is not on disk it asks `ParakeetSpeech` to download it and says so in `status`.
/// Logs to the unified log, subsystem `local.dabber.Dabber`, category `live`.
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
    static let rate = 16_000
    /// Most audio a track may have waiting: 20 s.
    static let maxPending = 20 * rate
    /// What the task hands to the model at once: 0.5 s.
    static let portion = rate / 2
    static let config = SlidingWindowAsrConfig(
        chunkSeconds: 6, hypothesisChunkSeconds: 1, leftContextSeconds: 6, rightContextSeconds: 2,
        minContextForConfirmation: 6, confirmationThreshold: 0.5)
    static let log = Logger(subsystem: "local.dabber.Dabber", category: "live")

    /// One track: its audio waiting for the model, and how it is taken to 16 kHz.
    private final class Track {
        var pending: [Float] = []
        var downsampler = Downsampler()
        var dropped = 0
    }

    private let lock = NSLock()
    private var on = false
    private var generation = 0
    private var models: AsrModels?
    private var loading = false
    private var lastAttempt = Date.distantPast
    private var problem: String?
    private var tracks: [String: Track] = [:]
    private var tasks: [Task<Void, Never>] = []
    private var recent: [Line] = []
    private var nextID = 0

    /// The newest lines last.
    public var lines: [Line] { lock.withLock { recent } }
    /// Why there are no lines, or that some audio was skipped.
    public var status: String? { lock.withLock { problem } }
    public var isOn: Bool { lock.withLock { on } }

    /// For a new recording, or when the switch is turned on during one: forgets earlier lines and starts loading.
    public func begin() {
        lock.withLock {
            stopTracks()
            on = true
            generation += 1
            recent = []
            problem = nil
        }
        Self.log.info("begin")
        load()
    }

    /// At Stop, or when the switch is turned off. The lines stay readable until the next `begin`.
    public func end() {
        lock.withLock {
            stopTracks()
            on = false
        }
        Self.log.info("end")
    }

    /// 48 kHz float samples of one track (interleaved when `channels` > 1). Only appends to the track's buffer.
    public func feed(track name: String, speaker: String, samples: [Float], channels: Int) {
        let needsModel: Bool = lock.withLock {
            guard on else { return false }
            let track: Track
            if let existing = tracks[name] {
                track = existing
            } else {
                guard let models else { return true }
                track = Track()
                tracks[name] = track
                let generation = self.generation
                tasks.append(Task.detached(priority: .utility) { [weak self] in
                    await self?.run(track: name, models: models, speaker: speaker, generation: generation)
                })
                Self.log.info("track \(name, privacy: .public) started")
            }
            track.pending += track.downsampler.process(Self.mono(samples, channels: channels))
            let excess = track.pending.count - Self.maxPending
            if excess > 0 {
                track.pending.removeFirst(excess)
                track.dropped += excess
                problem = "is behind: skipped \(track.dropped / Self.rate) s of \(name)"
                Self.log.error("track \(name, privacy: .public) behind, dropped \(excess) samples")
            }
            return false
        }
        if needsModel { load() }
    }

    /// The caller holds the lock.
    private func stopTracks() {
        for task in tasks { task.cancel() }
        tasks = []
        tracks = [:]
    }

    /// Takes what a track has waiting, if it still belongs to the running generation.
    private func take(_ name: String, generation: Int) -> [Float]? {
        lock.withLock {
            guard generation == self.generation, on, let track = tracks[name] else { return nil }
            let out = track.pending
            track.pending = []
            return out
        }
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
                Self.log.info("model not on disk yet")
                return
            }
            do {
                let models = try await AsrModels.downloadAndLoad(version: version)
                self.lock.withLock {
                    self.models = models
                    self.loading = false
                    self.problem = nil
                }
                Self.log.info("model loaded")
            } catch {
                self.lock.withLock {
                    self.loading = false
                    self.problem = "the speech model could not be loaded: \(error.localizedDescription)"
                }
                Self.log.error("model failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func run(track name: String, models: AsrModels, speaker: String, generation: Int) async {
        let manager = SlidingWindowAsrManager(config: Self.config)
        do {
            try await manager.loadModels(models)
            try await manager.startStreaming(source: speaker == Transcript.me ? .microphone : .system)
        } catch {
            lock.withLock { problem = "could not start: \(error.localizedDescription)" }
            Self.log.error("track \(name, privacy: .public) could not start: \(error.localizedDescription, privacy: .public)")
            return
        }
        let updates = await manager.transcriptionUpdates
        let reader = Task { [weak self] in
            for await update in updates { self?.add(update.text, speaker: speaker, generation: generation) }
        }
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: Double(Self.rate), channels: 1, interleaved: false)!
        var held: [Float] = []
        while !Task.isCancelled {
            guard let next = take(name, generation: generation) else { break }
            held += next
            if held.count < Self.portion {
                try? await Task.sleep(for: .milliseconds(250))
                continue
            }
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(held.count))
            else { break }
            buffer.frameLength = AVAudioFrameCount(held.count)
            held.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: held.count) }
            held = []
            await manager.streamAudio(buffer)
        }
        await manager.cancel()
        reader.cancel()
        Self.log.info("track \(name, privacy: .public) stopped")
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
