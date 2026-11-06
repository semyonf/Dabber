import CoreImage
import CoreMedia
import DabberCore
import ImageIO
import ReplayKit
import UserNotifications

/// Started from the round button in Dabber or from Control Center (long press Screen Recording, choose Dabber).
/// ReplayKit hands over the sound of other apps (the call), the microphone (when its button is on) and the screen.
/// The extension only writes them down, in the same layout as a recording on the Mac; the app finishes the
/// recording (mix, cleaning, transcript, slides video) when it is opened. The extension may use about 50 MB.
final class SampleHandler: RPBroadcastSampleHandler {
    private var session: BroadcastSession?

    override func broadcastStarted(withSetupInfo setupInfo: [String: NSObject]?) {
        do {
            session = try BroadcastSession(slides: Group.defaults.object(forKey: Group.slidesKey) as? Bool ?? true)
        } catch {
            finishBroadcastWithError(error)
        }
    }

    override func broadcastFinished() {
        session?.finish()
        session = nil
        let content = UNMutableNotificationContent()
        content.title = "Recording stopped"
        content.body = "Open Dabber to finish it: mix, transcript and slides are made in the app."
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "stopped", content: content, trigger: nil))
    }

    override func processSampleBuffer(_ sampleBuffer: CMSampleBuffer, with sampleBufferType: RPSampleBufferType) {
        session?.add(sampleBuffer, sampleBufferType)
    }
}

enum BroadcastError: LocalizedError {
    case noGroup(String)

    var errorDescription: String? {
        switch self {
        case .noGroup(let id): "Dabber cannot reach its shared folder (App Group \(id))."
        }
    }
}

final class BroadcastSession {
    static let frameInterval: UInt64 = 2_000_000_000
    static let beatInterval: TimeInterval = 5

    let dir: URL
    private let lock = NSLock()
    private var manifest: SessionManifest
    private let app: AudioTrack
    private let mic: AudioTrack
    private let slides: Bool
    private let sampler = FrameSampler()
    private let images = CIContext(options: [.cacheIntermediates: false])
    private var lastFrame: UInt64 = 0
    private var lastBeat = Date.distantPast

    init(slides: Bool) throws {
        guard let root = Group.sessions else { throw BroadcastError.noGroup(Group.id) }
        let start = HostClock.nowNanos()
        let now = Date()
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH-mm-ss"
        dir = root.appendingPathComponent(formatter.string(from: now), isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.slides = slides
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        manifest = SessionManifest(appVersion: "iPad \(version)", startedAt: now, sessionStartNanos: start)
        let appBase = SessionNaming.trackBase(kind: .computer, name: "iPad audio", taken: [])
        let micBase = SessionNaming.trackBase(kind: .mic, name: "iPad microphone", taken: [appBase])
        manifest.sources = [
            SourceManifest(kind: .computer, uid: nil, name: "iPad audio", file: appBase + ".m4a", channels: 2,
                           segments: [], restarts: [], overruns: 0),
            SourceManifest(kind: .mic, uid: "ipad-mic", name: "iPad microphone", file: micBase + ".m4a", channels: 1,
                           segments: [], restarts: [], overruns: 0),
        ]
        app = AudioTrack(dir: dir, base: appBase, channels: 2)
        mic = AudioTrack(dir: dir, base: micBase, channels: 1)
        beat()
        try manifest.save(to: dir)
    }

    func add(_ buffer: CMSampleBuffer, _ type: RPSampleBufferType) {
        lock.withLock {
            switch type {
            case .audioApp: app.append(buffer)
            case .audioMic: mic.append(buffer)
            case .video: if slides { frame(buffer) }
            @unknown default: break
            }
            if Date().timeIntervalSince(lastBeat) > Self.beatInterval { beat() }
        }
    }

    func finish() {
        lock.withLock {
            app.close()
            mic.close()
            saveManifest()
            try? FileManager.default.removeItem(at: dir.appendingPathComponent(Group.liveMarker))
        }
    }

    /// Tells the app the recording is still going, and keeps `session.json` up to date in case the extension is
    /// killed: the app then finishes what was written.
    private func beat() {
        lastBeat = Date()
        try? String(lastBeat.timeIntervalSince1970)
            .write(to: dir.appendingPathComponent(Group.liveMarker), atomically: true, encoding: .utf8)
        saveManifest()
    }

    private func saveManifest() {
        manifest.sources[0].segments = app.records
        manifest.sources[1].segments = mic.records
        try? manifest.save(to: dir)
    }

    /// A screenshot every 2 s at half size, kept only when the screen changed (as on the Mac).
    private func frame(_ buffer: CMSampleBuffer) {
        let at = AudioTrack.nanos(CMSampleBufferGetPresentationTimeStamp(buffer)) ?? HostClock.nowNanos()
        guard at >= lastFrame + Self.frameInterval, let pixels = CMSampleBufferGetImageBuffer(buffer) else { return }
        lastFrame = at
        autoreleasepool {
            var image = CIImage(cvPixelBuffer: pixels)
            if let raw = CMGetAttachment(buffer, key: RPVideoSampleOrientationKey as CFString, attachmentModeOut: nil)
                as? NSNumber, let orientation = CGImagePropertyOrientation(rawValue: raw.uint32Value) {
                image = image.oriented(orientation)
            }
            image = image.transformed(by: CGAffineTransform(scaleX: 0.5, y: 0.5))
            guard let picture = images.createCGImage(image, from: image.extent),
                  let data = try? sampler.offer(picture, display: 0)
            else { return }
            let record = manifest.addFrame(atNanos: at)
            let url = dir.appendingPathComponent(record.file)
            do {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: url, options: .atomic)
            } catch {
                manifest.frames.removeLast()
            }
        }
    }
}
