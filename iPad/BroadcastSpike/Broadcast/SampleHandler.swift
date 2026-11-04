import AudioToolbox
import CoreImage
import CoreMedia
import ImageIO
import ReplayKit

/// The broadcast extension: started from Control Center (Screen Recording > Dabber Spike). ReplayKit hands it the
/// sound of apps, the microphone and the screen. It writes each audio stream as it comes (`app-1.caf`, `mic-1.caf`,
/// a new file whenever the format changes), a screenshot every 2 s to `frames/`, and `summary.json`: formats,
/// gaps and the loudness of every second, so a silent track is plain without listening.
/// The extension may use about 50 MB of memory, so nothing is kept in memory but the per-second levels.
final class SampleHandler: RPBroadcastSampleHandler {
    private var session: SessionWriter?

    override func broadcastStarted(withSetupInfo setupInfo: [String: NSObject]?) {
        do {
            session = try SessionWriter()
        } catch {
            finishBroadcastWithError(error)
        }
    }

    override func broadcastPaused() { session?.event("paused") }
    override func broadcastResumed() { session?.event("resumed") }

    override func broadcastFinished() {
        session?.finish()
        session = nil
    }

    override func processSampleBuffer(_ sampleBuffer: CMSampleBuffer, with sampleBufferType: RPSampleBufferType) {
        session?.add(sampleBuffer, sampleBufferType)
    }
}

final class SessionWriter {
    let dir: URL
    private let lock = NSLock()
    private var summary: SessionSummary
    private var tracks: [String: TrackWriter] = [:]
    private var origin: CMTime?
    private var lastFrame: CMTime?
    private var lastSaved = Date.distantPast
    private let images = CIContext()
    private let log: FileHandle?

    init() throws {
        dir = try Store.newSession()
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("frames"), withIntermediateDirectories: true)
        let logURL = dir.appendingPathComponent(Store.logFile)
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        log = try? FileHandle(forWritingTo: logURL)
        summary = SessionSummary(started: Date())
        event("started")
        save()
    }

    func event(_ text: String) {
        lock.withLock {
            let line = String(format: "%.3f %@", Date().timeIntervalSince(summary.started), text)
            summary.events.append(line)
            log?.write(Data((line + "\n").utf8))
        }
    }

    func add(_ buffer: CMSampleBuffer, _ type: RPSampleBufferType) {
        lock.withLock {
            let time = CMSampleBufferGetPresentationTimeStamp(buffer)
            if origin == nil, time.isValid { origin = time }
            let origin = origin ?? .zero
            switch type {
            case .audioApp: track("app").append(buffer, origin: origin)
            case .audioMic: track("mic").append(buffer, origin: origin)
            case .video: frame(buffer, at: time)
            @unknown default: break
            }
            if Date().timeIntervalSince(lastSaved) > 5 { saveLocked() }
        }
    }

    func finish() {
        lock.withLock {
            for track in tracks.values { track.close() }
            summary.finished = Date()
            summary.events.append(String(format: "%.3f finished", Date().timeIntervalSince(summary.started)))
            saveLocked()
            try? log?.close()
        }
    }

    private func track(_ name: String) -> TrackWriter {
        if let track = tracks[name] { return track }
        let track = TrackWriter(name: name, dir: dir)
        tracks[name] = track
        return track
    }

    /// Every 2 s of screen time, half size, as JPEG.
    private func frame(_ buffer: CMSampleBuffer, at time: CMTime) {
        summary.videoFrames += 1
        if let lastFrame, time.isValid, (time - lastFrame).seconds < 2 { return }
        lastFrame = time
        guard let pixels = CMSampleBufferGetImageBuffer(buffer) else { return }
        let image = CIImage(cvPixelBuffer: pixels).transformed(by: CGAffineTransform(scaleX: 0.5, y: 0.5))
        let url = dir.appendingPathComponent("frames").appendingPathComponent(String(format: "%05d.jpg", summary.savedFrames))
        do {
            try images.writeJPEGRepresentation(
                of: image, to: url, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: 0.6])
            summary.savedFrames += 1
        } catch {
            summary.events.append("frame: \(error.localizedDescription)")
        }
    }

    private func save() { lock.withLock { saveLocked() } }

    private func saveLocked() {
        lastSaved = Date()
        summary.tracks = tracks.values.map(\.summary).sorted { $0.name < $1.name }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try? encoder.encode(summary).write(to: dir.appendingPathComponent(Store.summaryFile), options: .atomic)
    }
}

/// One audio stream into CAF files in the format it comes in (ReplayKit's app audio is often big-endian 16-bit).
final class TrackWriter {
    private var counted: TrackSummary
    /// The levels are worked out here, when the summary is saved, not on every buffer.
    var summary: TrackSummary {
        var s = counted
        s.levels = zip(sums, counts).map { sum, n in
            n == 0 ? -120 : Int((10 * log10(max(sum / Double(n), 1e-12))).rounded())
        }
        return s
    }
    private let dir: URL
    private var file: ExtAudioFileRef?
    private var format: AudioStreamBasicDescription?
    private var lastEnd: CMTime?
    private var sums: [Double] = []
    private var counts: [Int] = []

    init(name: String, dir: URL) {
        counted = TrackSummary(name: name)
        self.dir = dir
    }

    func append(_ buffer: CMSampleBuffer, origin: CMTime) {
        guard let description = CMSampleBufferGetFormatDescription(buffer),
              let pointer = CMAudioFormatDescriptionGetStreamBasicDescription(description)
        else { return }
        let asbd = pointer.pointee
        if format.map({ !Self.same($0, asbd) }) ?? true { open(asbd) }
        let frames = CMSampleBufferGetNumSamples(buffer)
        let time = CMSampleBufferGetPresentationTimeStamp(buffer)
        if let lastEnd, time.isValid, (time - lastEnd).seconds > 0.05 {
            counted.gaps += 1
            counted.gapSeconds += (time - lastEnd).seconds
        }
        if time.isValid { lastEnd = time + CMTime(value: CMTimeValue(frames), timescale: CMTimeScale(asbd.mSampleRate)) }

        var needed = 0
        CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            buffer, bufferListSizeNeededOut: &needed, bufferListOut: nil, bufferListSize: 0,
            blockBufferAllocator: nil, blockBufferMemoryAllocator: nil, flags: 0, blockBufferOut: nil)
        guard needed > 0 else { return }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: needed, alignment: 16)
        defer { raw.deallocate() }
        let list = raw.bindMemory(to: AudioBufferList.self, capacity: 1)
        var block: CMBlockBuffer?
        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            buffer, bufferListSizeNeededOut: nil, bufferListOut: list, bufferListSize: needed,
            blockBufferAllocator: nil, blockBufferMemoryAllocator: nil,
            flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment, blockBufferOut: &block)
        guard status == noErr else { return }
        if let file { ExtAudioFileWrite(file, UInt32(frames), list) }
        counted.buffers += 1
        counted.frames += Int64(frames)
        counted.seconds = Double(counted.frames) / asbd.mSampleRate
        let second = max(0, Int((time - origin).seconds))
        measure(UnsafeMutableAudioBufferListPointer(list), asbd, second: second)
    }

    func close() {
        if let file { ExtAudioFileDispose(file) }
        file = nil
    }

    private func open(_ asbd: AudioStreamBasicDescription) {
        close()
        format = asbd
        let name = "\(counted.name)-\(counted.segments.count + 1).caf"
        counted.segments.append(name)
        counted.formats.append(Self.describe(asbd))
        // Files hold interleaved samples; the extension still hands over what ReplayKit gives.
        var fileFormat = asbd
        let nonInterleaved = asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0
        if nonInterleaved, asbd.mFormatID == kAudioFormatLinearPCM {
            fileFormat.mFormatFlags &= ~kAudioFormatFlagIsNonInterleaved
            fileFormat.mBytesPerFrame = asbd.mBytesPerFrame * asbd.mChannelsPerFrame
            fileFormat.mBytesPerPacket = fileFormat.mBytesPerFrame
        }
        var created: ExtAudioFileRef?
        let url = dir.appendingPathComponent(name) as CFURL
        guard ExtAudioFileCreateWithURL(url, kAudioFileCAFType, &fileFormat, nil, AudioFileFlags.eraseFile.rawValue, &created) == noErr,
              let created
        else { return }
        var client = asbd
        ExtAudioFileSetProperty(
            created, kExtAudioFileProperty_ClientDataFormat, UInt32(MemoryLayout<AudioStreamBasicDescription>.size), &client)
        file = created
    }

    /// Adds the buffer to the loudness of its second and updates the levels.
    private func measure(_ buffers: UnsafeMutableAudioBufferListPointer, _ asbd: AudioStreamBasicDescription, second: Int) {
        let float = asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0
        let bigEndian = asbd.mFormatFlags & kAudioFormatFlagIsBigEndian != 0
        let bits = Int(asbd.mBitsPerChannel)
        var sum = 0.0
        var count = 0
        for buffer in buffers {
            guard let data = buffer.mData else { continue }
            let bytes = Int(buffer.mDataByteSize)
            switch (float, bits) {
            case (true, 32):
                let p = data.assumingMemoryBound(to: Float.self)
                for i in 0..<bytes / 4 { sum += Double(p[i] * p[i]) }
                count += bytes / 4
            case (false, 16):
                let p = data.assumingMemoryBound(to: Int16.self)
                for i in 0..<bytes / 2 {
                    let v = Double(bigEndian ? Int16(bigEndian: p[i]) : Int16(littleEndian: p[i])) / 32_768
                    sum += v * v
                }
                count += bytes / 2
            case (false, 32):
                let p = data.assumingMemoryBound(to: Int32.self)
                for i in 0..<bytes / 4 {
                    let v = Double(bigEndian ? Int32(bigEndian: p[i]) : Int32(littleEndian: p[i])) / 2_147_483_648
                    sum += v * v
                }
                count += bytes / 4
            default:
                return
            }
        }
        while sums.count <= second {
            sums.append(0)
            counts.append(0)
        }
        sums[second] += sum
        counts[second] += count
    }

    private static func same(_ a: AudioStreamBasicDescription, _ b: AudioStreamBasicDescription) -> Bool {
        a.mSampleRate == b.mSampleRate && a.mFormatID == b.mFormatID && a.mFormatFlags == b.mFormatFlags
            && a.mChannelsPerFrame == b.mChannelsPerFrame && a.mBitsPerChannel == b.mBitsPerChannel
    }

    private static func describe(_ a: AudioStreamBasicDescription) -> String {
        let kind = a.mFormatFlags & kAudioFormatFlagIsFloat != 0 ? "float" : "int"
        let endian = a.mFormatFlags & kAudioFormatFlagIsBigEndian != 0 ? " big-endian" : ""
        let layout = a.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0 ? " non-interleaved" : ""
        return "\(Int(a.mSampleRate)) Hz, \(a.mChannelsPerFrame) ch, \(a.mBitsPerChannel)-bit \(kind)\(endian)\(layout)"
    }
}
