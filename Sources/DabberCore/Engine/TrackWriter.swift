import AVFoundation
import AudioToolbox
import CoreAudio
import Foundation
import Synchronization

public final class LevelMeter: Sendable {
    private let bits = Atomic<UInt32>(Float(-160).bitPattern)

    public var decibels: Double { Double(Float(bitPattern: bits.load(ordering: .relaxed))) }

    func update(_ samples: UnsafePointer<Float>, count: Int) {
        guard count > 0 else { return }
        var sum: Float = 0
        for i in 0..<count { sum += samples[i] * samples[i] }
        let rms = (sum / Float(count)).squareRoot()
        bits.store((rms > 0 ? 20 * log10(rms) : -160).bitPattern, ordering: .relaxed)
    }
}

public struct WriteFailure: Error, CustomStringConvertible {
    public let status: OSStatus
    public var description: String { "caf write failed: \(fourCC(status))" }
}

public final class TrackWriter: @unchecked Sendable {
    public let baseName: String
    public let channels: Int
    public let meter = LevelMeter()
    public var onFormatMismatch: (@Sendable () -> Void)?
    public var onWriteError: (@Sendable (Error) -> Void)?
    public var onSegmentsChanged: (@Sendable ([SegmentRecord]) -> Void)?

    private let ring: RingBuffer
    private let dir: URL
    private let queue = DispatchQueue(label: "dabber.writer")
    private let events = DispatchQueue(label: "dabber.writer.events")
    private var timer: DispatchSourceTimer?
    private var current: OpenSegment?
    private var records: [SegmentRecord] = []

    private struct OpenSegment {
        var record: SegmentRecord
        let file: ExtAudioFileRef
        let converter: AVAudioConverter
        let input: AVAudioPCMBuffer
        let output: AVAudioPCMBuffer
        var tracker: SegmentTracker
        var lastHeader: SlotHeader?
    }

    public init(dir: URL, baseName: String, channels: Int, ring: RingBuffer) {
        self.dir = dir
        self.baseName = baseName
        self.channels = channels
        self.ring = ring
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(50))
        timer.setEventHandler { [weak self] in self?.drain() }
        timer.resume()
        self.timer = timer
    }

    public var segments: [SegmentRecord] { queue.sync { allRecords() } }

    public func openSegment(format: AudioStreamBasicDescription, reason: String) throws {
        try queue.sync {
            finishCurrent()
            try open(format: format, reason: reason)
        }
    }

    public func closeSegment() {
        queue.sync {
            drain()
            finishCurrent()
        }
    }

    public func stop() {
        closeSegment()
        timer?.cancel()
        timer = nil
    }

    private func allRecords() -> [SegmentRecord] { records + (current.map { [$0.record] } ?? []) }

    private func notifySegments() {
        let snapshot = allRecords()
        events.async { [self] in onSegmentsChanged?(snapshot) }
    }

    private func open(format: AudioStreamBasicDescription, reason: String) throws {
        var asbd = format
        guard let sourceFormat = AVAudioFormat(streamDescription: &asbd),
              let targetFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: AVAudioChannelCount(channels),
                interleaved: true),
              let converter = AVAudioConverter(from: sourceFormat, to: targetFormat)
        else {
            throw CAError(status: kAudioFormatUnsupportedDataFormatError,
                          op: "converter for \(format.mSampleRate) Hz \(format.mChannelsPerFrame) ch")
        }
        converter.downmix = true
        let bufferCount = sourceFormat.isInterleaved ? 1 : Int(format.mChannelsPerFrame)
        let slotFrames = ring.slotBytes / Int(format.mBytesPerFrame) / bufferCount
        guard let input = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: AVAudioFrameCount(slotFrames)),
              let output = AVAudioPCMBuffer(
                pcmFormat: targetFormat,
                frameCapacity: AVAudioFrameCount(Double(slotFrames) * 48_000 / format.mSampleRate) + 64)
        else { throw CAError(status: kAudio_MemFullError, op: "pcm buffers") }
        let file = SessionNaming.segmentFile(base: baseName, index: records.count)
        var fileFormat = targetFormat.streamDescription.pointee
        var ref: ExtAudioFileRef?
        try check(
            ExtAudioFileCreateWithURL(
                dir.appendingPathComponent(file) as CFURL, kAudioFileCAFType, &fileFormat, nil,
                AudioFileFlags.eraseFile.rawValue, &ref),
            "create caf")
        var client = fileFormat
        try check(
            ExtAudioFileSetProperty(
                ref!, kExtAudioFileProperty_ClientDataFormat,
                UInt32(MemoryLayout<AudioStreamBasicDescription>.size), &client),
            "set client format")
        current = OpenSegment(
            record: SegmentRecord(
                file: file, startNanos: 0, frames: 0, endNanos: nil, sourceRate: format.mSampleRate,
                sourceChannels: Int(format.mChannelsPerFrame), reason: reason),
            file: ref!, converter: converter, input: input, output: output,
            tracker: SegmentTracker(bytesPerFrame: Int(format.mBytesPerFrame), bufferCount: bufferCount),
            lastHeader: nil)
        notifySegments()
    }

    private func drain() {
        while ring.pop({ header, bytes in handle(header, bytes) }) {}
    }

    private func handle(_ header: SlotHeader, _ bytes: UnsafeRawPointer) {
        guard current != nil else { return }
        switch current!.tracker.classify(header) {
        case .formatMismatch:
            finishCurrent()
            events.async { [self] in onFormatMismatch?() }
            return
        case .gap:
            let format = current!.input.format.streamDescription.pointee
            finishCurrent()
            do {
                try open(format: format, reason: "sample time jump")
            } catch {
                events.async { [self] in onWriteError?(error) }
                return
            }
            _ = current!.tracker.classify(header)
        case .continues:
            break
        }
        write(header, bytes)
    }

    private func write(_ header: SlotHeader, _ bytes: UnsafeRawPointer) {
        guard var seg = current else { return }
        let first = seg.lastHeader == nil
        if first { seg.record.startNanos = HostClock.nanos(hostTime: header.hostTime) }
        seg.lastHeader = header
        let list = UnsafeMutableAudioBufferListPointer(seg.input.mutableAudioBufferList)
        for i in 0..<header.bufferCount {
            list[i].mData!.copyMemory(from: bytes + i * header.bytesPerBuffer, byteCount: header.bytesPerBuffer)
            list[i].mDataByteSize = UInt32(header.bytesPerBuffer)
            if seg.input.format.commonFormat == .pcmFormatFloat32 {
                let samples = list[i].mData!.assumingMemoryBound(to: Float.self)
                for j in 0..<header.bytesPerBuffer / 4 where !samples[j].isFinite { samples[j] = 0 }
            }
        }
        seg.input.frameLength = AVAudioFrameCount(seg.tracker.frames(in: header))
        current = seg
        if first { notifySegments() }
        convert(endOfStream: false)
    }

    private func convert(endOfStream: Bool) {
        guard var seg = current else { return }
        var fed = false
        var error: NSError?
        seg.output.frameLength = 0
        let input = seg.input
        seg.converter.convert(to: seg.output, error: &error) { _, status in
            if endOfStream { status.pointee = .endOfStream; return nil }
            if fed { status.pointee = .noDataNow; return nil }
            fed = true
            status.pointee = .haveData
            return input
        }
        let produced = seg.output.frameLength
        if produced > 0 {
            let status = ExtAudioFileWrite(seg.file, produced, seg.output.audioBufferList)
            if status != noErr {
                current = seg
                finishCurrent()
                events.async { [self] in onWriteError?(WriteFailure(status: status)) }
                return
            }
            seg.record.frames += Int(produced)
            meter.update(seg.output.floatChannelData![0], count: Int(produced) * channels)
        }
        current = seg
    }

    private func finishCurrent() {
        guard current != nil else { return }
        convert(endOfStream: true)
        guard var done = current else { return }
        ExtAudioFileDispose(done.file)
        if let last = done.lastHeader {
            let seconds = Double(done.tracker.frames(in: last)) / done.record.sourceRate
            done.record.endNanos = HostClock.nanos(hostTime: last.hostTime) + UInt64(seconds * 1e9)
        }
        records.append(done.record)
        current = nil
        notifySegments()
    }
}
