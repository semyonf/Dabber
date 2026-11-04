import AVFoundation
import DabberCore
import FluidAudio
import Foundation

/// Parakeet TDT 0.6B v3 on the Neural Engine. No language hint: with one, English terms in Russian speech come out
/// in Cyrillic. The model (about 470 MB, kept in FluidAudio's cache in Application Support) is downloaded and compiled
/// in the background by `prepare()`. `transcribe` never downloads the model itself: it runs inside finalize, which
/// holds the delivery lock and makes quitting wait. If the model is not loaded, it starts the background load and
/// throws at once, and the recording goes out without a transcript.
public final class ParakeetSpeech: @unchecked Sendable {
    public static let shared = ParakeetSpeech()

    public enum SpeechError: LocalizedError {
        case notReady(String?)
        case downmix(String)
        case noTimings

        public var errorDescription: String? {
            switch self {
            case .notReady(nil): "the speech model is not ready yet"
            case .notReady(let why?): "the speech model could not be loaded: \(why)"
            case .downmix(let name): "could not prepare \(name) for transcription"
            case .noTimings: "the model returned text without word timings"
            }
        }
    }

    /// The loader reports what it is doing; the report may come from any thread.
    public typealias Report = @Sendable (SpeechModelStatus) -> Void

    private let load: @Sendable (@escaping Report) async throws -> AsrManager
    private let lock = NSLock()
    private var manager: AsrManager?
    private var loading = false
    private var progress = SpeechModelStatus.preparing
    private var loadError: String?
    private var failures = 0
    private var networkFailures = 0
    private var markerDir: URL?
    private static let maxFailures = 3
    private static let maxNetworkFailures = 10

    init(load: @escaping @Sendable (@escaping Report) async throws -> AsrManager = makeManager) {
        self.load = load
    }

    /// Starts the download and load in the background. Calling it again is free; after a failure it retries,
    /// but gives up after three failures in one app run so a broken model is not downloaded again on every finalize.
    /// Network failures have a cap of their own, ten: a proxy that breaks every download would otherwise make each
    /// finalize download the 470 MB model again.
    public func prepare() {
        let start = lock.withLock {
            guard manager == nil, !loading, canRetry else { return false }
            loading = true
            progress = .preparing
            loadError = nil
            if let markerDir {
                try? FileManager.default.createDirectory(at: markerDir, withIntermediateDirectories: true)
                FileManager.default.createFile(atPath: Self.loadMarker(in: markerDir).path, contents: nil)
            }
            return true
        }
        guard start else { return }
        Task.detached(priority: .utility) {
            let result: Result<AsrManager, any Error>
            do { result = .success(try await self.load(self.report)) } catch { result = .failure(error) }
            self.lock.withLock {
                self.record(result)
                self.loading = false
                self.removeMarker()
            }
        }
    }

    /// For the menu. Read under the lock, so any thread may call it.
    public var status: SpeechModelStatus {
        lock.withLock {
            if manager != nil { return .ready }
            if loading { return progress }
            if let loadError { return .failed(loadError, gaveUp: !canRetry) }
            return .idle
        }
    }

    /// The caller holds the lock.
    private var canRetry: Bool { failures < Self.maxFailures && networkFailures < Self.maxNetworkFailures }

    /// Called on FluidAudio's threads while a load runs: it only stores the status.
    private func report(_ status: SpeechModelStatus) {
        lock.withLock { progress = status }
    }

    /// A crash in CoreML while the model loads kills the whole app, and the next launch would load it again and crash
    /// again. So, once the app calls this, `prepare()` keeps a marker file in `dir` while a load runs. A marker found
    /// at launch means the last load never finished. The headless mode does not call this.
    public func markLoads(in dir: URL) {
        lock.withLock { markerDir = dir }
    }

    public static func loadMarker(in dir: URL) -> URL {
        dir.appendingPathComponent("loading-model")
    }

    /// A normal quit may cut a load short. That is not a crash, so the marker goes, and later loads leave none.
    public func quitting() {
        lock.withLock {
            removeMarker()
            markerDir = nil
        }
    }

    /// The caller holds the lock.
    private func removeMarker() {
        guard let markerDir else { return }
        try? FileManager.default.removeItem(at: Self.loadMarker(in: markerDir))
    }

    /// Blocks until the model is loaded. For the headless mode only: it ignores `loading` and both failure caps,
    /// so it loads even while `prepare()` is loading, after three failures or after ten network failures.
    /// It leaves no load marker.
    public func prepareNow() throws {
        if lock.withLock({ manager }) != nil { return }
        let result = Result { try blocking { try await self.load(self.report) } }
        lock.withLock { record(result) }
        _ = try result.get()
    }

    /// Keeps the loaded model or the reason it failed, and counts network failures apart from the others.
    /// The caller holds the lock.
    private func record(_ result: Result<AsrManager, any Error>) {
        switch result {
        case .success(let asr):
            manager = asr
            loadError = nil
        case .failure(let error):
            loadError = error.localizedDescription
            if Self.isNetwork(error) { networkFailures += 1 } else { failures += 1 }
        }
    }

    /// For launch recovery: a session recovered before the model is loaded would lose its transcript. Returns at once
    /// if the model is loaded or is not on disk (waiting would mean a download); otherwise starts the load and waits
    /// for it, at most `seconds`.
    public func waitIfCached(seconds: Double) async {
        if lock.withLock({ manager }) != nil { return }
        guard AsrModels.modelsExist(at: AsrModels.defaultCacheDirectory(for: .v3), version: .v3) else { return }
        prepare()
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            let (ready, busy) = loadState()
            if ready || !busy { return }
            do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
        }
    }

    func loadState() -> (ready: Bool, busy: Bool) {
        lock.withLock { (manager != nil, loading) }
    }

    public func transcribe(_ url: URL) throws -> [SpokenWord] {
        let (asr, failure) = lock.withLock { (manager, loadError) }
        guard let asr else {
            prepare()
            throw SpeechError.notReady(failure)
        }
        let mono = try Self.monoCopy(of: url)
        defer { if let mono { try? FileManager.default.removeItem(at: mono) } }
        return try blocking {
            var state = TdtDecoderState.make(decoderLayers: await asr.decoderLayerCount)
            let result = try await asr.transcribe(mono ?? url, decoderState: &state)
            return try Self.words(of: result)
        }
    }

    /// Text without token timings would quietly give an empty transcript, so it is an error instead.
    static func words(of result: ASRResult) throws -> [SpokenWord] {
        let words = words(result.tokenTimings ?? [])
        guard words.isEmpty, !result.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return words }
        throw SpeechError.noTimings
    }

    private static let monoPrefix = "dabber-mono-"
    /// The temporary mono copy and FluidAudio's converted audio for a long file (`fluidaudio-streaming-*.raw`).
    private static let tempPrefixes = [monoPrefix, "fluidaudio-streaming-"]

    /// A crash or a kill during transcription leaves the temporary audio behind, about 0.5 GB per hour of stereo.
    /// This removes such files older than an hour; a younger one may belong to a transcription that is running now.
    public static func removeStaleTempFiles(in dir: URL = FileManager.default.temporaryDirectory, now: Date = Date()) {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        for url in files where tempPrefixes.contains(where: url.lastPathComponent.hasPrefix) {
            guard let date = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                  now.timeIntervalSince(date) > 3_600 else { continue }
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// Being offline is transient, so it uses up one of the ten network retries, not one of the three others.
    /// FluidAudio reports download problems as its own DownloadError (a stalled transfer, a rate limit, a server
    /// error). They count as network failures, except a model file that is missing on the server (HTTP 4xx other
    /// than 429) or in the cache.
    static func isNetwork(_ error: Error) -> Bool {
        if let download = error as? DownloadError {
            switch download {
            case .modelNotFound, .modelMissing, .networkDisabled:
                return false
            case .downloadFailed(_, let underlying):
                let http = underlying as NSError
                return http.domain == "HTTP" ? http.code == 429 || http.code >= 500 : isNetwork(underlying)
            case .invalidResponse, .rateLimited, .htmlErrorResponse, .invalidArtifact, .stalled:
                return true
            }
        }
        return error is URLError || (error as NSError).domain == NSURLErrorDomain
            || ((error as NSError).userInfo[NSUnderlyingErrorKey] as? NSError)?.domain == NSURLErrorDomain
    }

    @Sendable static func makeManager(report: @escaping Report) async throws -> AsrManager {
        let version = AsrModelVersion.v3
        let cached = AsrModels.modelsExist(at: AsrModels.defaultCacheDirectory(for: version), version: version)
        report(cached ? .preparing : .downloading(nil))
        let models = try await AsrModels.downloadAndLoad(version: version, progressHandler: { report(status(of: $0)) })
        let asr = AsrManager(config: ASRConfig(
            tdtConfig: TdtConfig(blankId: version.blankId), encoderHiddenSize: version.encoderHiddenSize))
        try await asr.loadModels(models)
        return asr
    }

    /// FluidAudio fills the first half of `fractionCompleted` with the download of the model repo and the second
    /// half with compiling, so the download's own fraction is twice the reported one. Models already in the cache
    /// are reported as a download of no files.
    static func status(of progress: DownloadProgress) -> SpeechModelStatus {
        switch progress.phase {
        case .listing: .downloading(nil)
        case .downloading(_, let total) where total > 0: .downloading(min(1, progress.fractionCompleted * 2))
        case .downloading, .compiling: .preparing
        }
    }

    /// FluidAudio's `WordTiming` has no confidence, so the tokens are split into words by the same rule as
    /// `buildWordTimings` (a word-boundary token or an empty current word starts a new one). Each group goes through
    /// `buildWordTimings` for the text and times; its confidence is the mean of its token confidences.
    static func words(_ tokens: [TokenTiming]) -> [SpokenWord] {
        var groups: [[TokenTiming]] = []
        var currentText = ""
        for t in tokens {
            if t.token.isEmpty || t.token == "<blank>" || t.token == "<pad>" { continue }
            if isWordBoundary(t.token) || currentText.isEmpty {
                groups.append([t])
                currentText = stripWordBoundaryPrefix(t.token)
            } else {
                groups[groups.count - 1].append(t)
                currentText += t.token
            }
        }
        return groups.flatMap { group in
            let mean = group.map { Double($0.confidence) }.reduce(0, +) / Double(group.count)
            return buildWordTimings(from: group).compactMap { word -> SpokenWord? in
                let text = word.word.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { return nil }
                return SpokenWord(
                    startMillis: Int((word.startTime * 1000).rounded()),
                    endMillis: Int((word.endTime * 1000).rounded()), text: text, confidence: mean)
            }
        }
    }

    /// For a file over 30 s FluidAudio takes its disk-backed path, which converts to mono without a downmix and so
    /// reads only the left channel. A multi-channel track is therefore downmixed to a temporary mono 16 kHz copy
    /// first. Returns nil for a mono file.
    static func monoCopy(of url: URL) throws -> URL? {
        let input = try AVAudioFile(forReading: url)
        guard input.fileFormat.channelCount > 1 else { return nil }
        let fail = SpeechError.downmix(url.lastPathComponent)
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
        let block: AVAudioFrameCount = 48_000 * 10
        guard let converter = AVAudioConverter(from: input.processingFormat, to: format),
              let inBuf = AVAudioPCMBuffer(pcmFormat: input.processingFormat, frameCapacity: block),
              let outBuf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16_000 * 11)
        else { throw fail }
        converter.downmix = true
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("\(monoPrefix)\(UUID().uuidString).caf")
        do {
            let file = try AVAudioFile(forWriting: out, settings: format.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
            var readError: Error?
            while true {
                var convError: NSError?
                let status = converter.convert(to: outBuf, error: &convError) { _, inStatus in
                    inBuf.frameLength = 0
                    if input.framePosition < input.length {
                        do { try input.read(into: inBuf, frameCount: block) } catch { readError = error }
                    }
                    if readError != nil || inBuf.frameLength == 0 { inStatus.pointee = .endOfStream; return nil }
                    inStatus.pointee = .haveData
                    return inBuf
                }
                if let readError { throw readError }
                if status == .error { throw convError ?? fail }
                if outBuf.frameLength > 0 { try file.write(from: outBuf) }
                if status == .endOfStream { break }
            }
            file.close()
        } catch {
            try? FileManager.default.removeItem(at: out)
            throw error
        }
        return out
    }
}

/// Finalizer is synchronous; this waits in it for the async FluidAudio call. It parks a cooperative-pool thread
/// while another task does the work. That is safe because Delivery.lock lets one transcription run at a time,
/// so at most one or two pool threads are parked.
func blocking<T: Sendable>(_ body: @escaping @Sendable () async throws -> T) throws -> T {
    let done = DispatchSemaphore(value: 0)
    nonisolated(unsafe) var result: Result<T, any Error>?
    Task.detached(priority: Task.currentPriority) {
        do { result = .success(try await body()) } catch { result = .failure(error) }
        done.signal()
    }
    done.wait()
    return try result!.get()
}
