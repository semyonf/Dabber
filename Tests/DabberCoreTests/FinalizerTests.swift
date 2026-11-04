import AVFoundation
import CoreGraphics
import AudioToolbox
import Foundation
import Testing
@testable import DabberCore

private func writeCAF(_ url: URL, samples: [Float], channels: Int) throws {
    let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: AVAudioChannelCount(channels), interleaved: true)!
    var asbd = format.streamDescription.pointee
    var ref: ExtAudioFileRef?
    try check(ExtAudioFileCreateWithURL(url as CFURL, kAudioFileCAFType, &asbd, nil, AudioFileFlags.eraseFile.rawValue, &ref), "create")
    var client = asbd
    try check(ExtAudioFileSetProperty(ref!, kExtAudioFileProperty_ClientDataFormat, UInt32(MemoryLayout<AudioStreamBasicDescription>.size), &client), "client")
    let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count / channels))!
    buf.frameLength = buf.frameCapacity
    samples.withUnsafeBufferPointer { buf.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
    try check(ExtAudioFileWrite(ref!, buf.frameLength, buf.audioBufferList), "write")
    ExtAudioFileDispose(ref!)
}

private func sine(frames: Int, channels: Int, amplitude: Float = 0.5) -> [Float] {
    (0..<(frames * channels)).map { i in amplitude * Float(sin(Double(i / channels) / 48_000 * 2 * .pi * 440)) }
}

private func rms(_ url: URL, from: Int, frames: Int) throws -> Float {
    let f = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: true)
    f.framePosition = AVAudioFramePosition(from)
    let buf = AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: AVAudioFrameCount(frames))!
    try f.read(into: buf, frameCount: AVAudioFrameCount(frames))
    let n = Int(buf.frameLength) * Int(f.processingFormat.channelCount)
    var sum: Float = 0
    for i in 0..<n { sum += buf.floatChannelData![0][i] * buf.floatChannelData![0][i] }
    return (sum / Float(max(n, 1))).squareRoot()
}

private let startedAt = Date(timeIntervalSince1970: 1_800_000_000)

private func makeSession() throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("fin-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let s: UInt64 = 10_000_000_000
    var m = SessionManifest(appVersion: "t", startedAt: startedAt, sessionStartNanos: s)
    m.sources = [
        SourceManifest(kind: .mic, uid: "u", name: "A", file: "mic - A.m4a", channels: 1, segments: [
            SegmentRecord(file: "mic - A.seg000.caf", startNanos: s, frames: 48_000, endNanos: s + 1_000_000_000, sourceRate: 24_000, sourceChannels: 1, reason: "start"),
            SegmentRecord(file: "mic - A.seg001.caf", startNanos: s + 2_000_000_000, frames: 0, endNanos: nil, sourceRate: 48_000, sourceChannels: 1, reason: "restart: nsrt"),
        ], restarts: [], overruns: 0),
        SourceManifest(kind: .computer, uid: nil, name: "Computer audio", file: "computer audio.m4a", channels: 2, segments: [
            SegmentRecord(file: "computer audio.seg000.caf", startNanos: s, frames: 144_000, endNanos: s + 3_000_000_000, sourceRate: 48_000, sourceChannels: 2, reason: "start"),
        ], restarts: [], overruns: 0),
    ]
    try m.save(to: dir)
    try writeCAF(dir.appendingPathComponent("mic - A.seg000.caf"), samples: sine(frames: 48_000, channels: 1), channels: 1)
    try writeCAF(dir.appendingPathComponent("mic - A.seg001.caf"), samples: sine(frames: 24_000, channels: 1), channels: 1)
    try writeCAF(dir.appendingPathComponent("computer audio.seg000.caf"), samples: sine(frames: 144_000, channels: 2, amplitude: 0.25), channels: 2)
    return dir
}

@Suite(.serialized) struct FinalizerTests {}

extension FinalizerTests {
    @Test func finalizerRendersTracksMixAndReportThenDeletesCAFs() throws {
        let dir = try makeSession()
        let report = try Finalizer.run(dir)
        #expect(report.totalFrames == 144_000)
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()
        #expect(names == ["computer audio.m4a", "mic - A.m4a", "mix.m4a", "session.json"])
        for n in ["computer audio.m4a", "mic - A.m4a", "mix.m4a"] {
            #expect(try AVAudioFile(forReading: dir.appendingPathComponent(n)).length == 144_000, "\(n)")
        }
        #expect(try rms(dir.appendingPathComponent("mic - A.m4a"), from: 10_000, frames: 4_800) > 0.2)
        #expect(try rms(dir.appendingPathComponent("mic - A.m4a"), from: 60_000, frames: 4_800) < 0.01)
        #expect(try rms(dir.appendingPathComponent("mic - A.m4a"), from: 100_000, frames: 4_800) > 0.2)
        #expect(try rms(dir.appendingPathComponent("mix.m4a"), from: 60_000, frames: 4_800) > 0.05)
        #expect(report.gaps == [GapRecord(track: "mic - A", atFrame: 48_000, frames: 48_000)])
        #expect(report.driftMillis["mic - A.seg000.caf"] == 0)
        #expect(report.resampled.isEmpty)
        #expect(try SessionManifest.load(from: dir).finalize == report)
    }

    @Test func recoveryFinalizesFoldersWithCAFsButNoMix() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("rec-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let unfinished = try makeSession()
        let pending = root.appendingPathComponent("pending")
        try FileManager.default.moveItem(at: unfinished, to: pending)
        let done = root.appendingPathComponent("done")
        try FileManager.default.createDirectory(at: done, withIntermediateDirectories: true)
        try Data().write(to: done.appendingPathComponent("mix.m4a"))
        try Data().write(to: done.appendingPathComponent("stray.caf"))
        let name = SessionNaming.sessionName(startedAt, title: "")
        #expect(Finalizer.recoverAll(dirs: Finalizer.sessionFolders(root: root)).map(\.path) == [root.appendingPathComponent(name).path])
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent(name).appendingPathComponent(name + ".m4a").path))
        #expect(FileManager.default.fileExists(atPath: done.appendingPathComponent("stray.caf").path))
    }

    @Test func recoveryReportsWhatItCouldNotRead() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("rec-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let pending = root.appendingPathComponent("pending")
        try FileManager.default.moveItem(at: try makeSession(), to: pending)
        try Data(repeating: 1, count: 100).write(to: pending.appendingPathComponent("mic - A.seg001.caf"))
        var reports: [(String, [String]?)] = []
        let done = Finalizer.recoverAll(dirs: [pending], onReport: { dir, report in reports.append((dir.lastPathComponent, report.unreadable)) })
        let name = SessionNaming.sessionName(startedAt, title: "")
        #expect(done.map(\.lastPathComponent) == [name])
        #expect(reports.map(\.0) == [name])
        #expect(reports.map(\.1) == [["mic - A.seg001.caf"]])
    }

    @Test func missingSegmentFileIsSkippedNotFatal() throws {
        let dir = try makeSession()
        try FileManager.default.removeItem(at: dir.appendingPathComponent("mic - A.seg001.caf"))
        let report = try Finalizer.run(dir)
        #expect(report.totalFrames == 144_000)
        #expect(try rms(dir.appendingPathComponent("mic - A.m4a"), from: 100_000, frames: 4_800) < 0.01)
    }

    @Test func partialOutputFromAnInterruptedFinalizeIsRecovered() throws {
        let dir = try makeSession()
        try Data(repeating: 7, count: 1000).write(to: dir.appendingPathComponent("mix.m4a"))
        #expect(Finalizer.needsRecovery(dir))
        #expect(try Finalizer.run(dir).totalFrames == 144_000)
        #expect(!Finalizer.needsRecovery(dir))
    }

    @Test func tracksStartingAtDifferentHostTimesAreAlignedInTheMix() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("fin-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let s: UInt64 = 10_000_000_000
        var m = SessionManifest(appVersion: "t", startedAt: Date(), sessionStartNanos: s)
        m.sources = [
            SourceManifest(kind: .computer, uid: nil, name: "Computer audio", file: "computer audio.m4a", channels: 2, segments: [
                SegmentRecord(file: "computer audio.seg000.caf", startNanos: s, frames: 144_000, endNanos: s + 3_000_000_000, sourceRate: 48_000, sourceChannels: 2, reason: "start"),
            ], restarts: [], overruns: 0),
            SourceManifest(kind: .mic, uid: "u", name: "A", file: "mic - A.m4a", channels: 1, segments: [
                SegmentRecord(file: "mic - A.seg000.caf", startNanos: s + 1_000_000_000, frames: 48_000, endNanos: s + 2_000_000_000, sourceRate: 48_000, sourceChannels: 1, reason: "start"),
            ], restarts: [], overruns: 0),
        ]
        try m.save(to: dir)
        try writeCAF(dir.appendingPathComponent("computer audio.seg000.caf"), samples: [Float](repeating: 0, count: 144_000 * 2), channels: 2)
        try writeCAF(dir.appendingPathComponent("mic - A.seg000.caf"), samples: sine(frames: 48_000, channels: 1), channels: 1)
        let report = try Finalizer.run(dir)
        #expect(report.totalFrames == 144_000)
        #expect(report.gaps == [GapRecord(track: "mic - A", atFrame: 0, frames: 48_000)])
        let mix = dir.appendingPathComponent("mix.m4a")
        #expect(try rms(mix, from: 20_000, frames: 4_800) < 0.01)
        #expect(try rms(mix, from: 60_000, frames: 4_800) > 0.1)
        #expect(try rms(mix, from: 120_000, frames: 4_800) < 0.01)
    }

    @Test func aBackupTrackThatStartsLateAndPausesIsPlacedOnTheTimeline() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("fin-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let s: UInt64 = 10_000_000_000
        var m = SessionManifest(appVersion: "t", startedAt: Date(), sessionStartNanos: s)
        m.sources = [
            SourceManifest(kind: .computer, uid: nil, name: "Computer audio", file: "computer audio.m4a", channels: 2, segments: [
                SegmentRecord(file: "computer audio.seg000.caf", startNanos: s, frames: 144_000, endNanos: s + 3_000_000_000, sourceRate: 48_000, sourceChannels: 2, reason: "start"),
            ], restarts: [], overruns: 0),
            SourceManifest(kind: .mic, uid: "ap", name: "AirPods", file: "mic - AirPods.m4a", channels: 1, segments: [
                SegmentRecord(file: "mic - AirPods.seg000.caf", startNanos: s, frames: 48_000, endNanos: s + 1_000_000_000, sourceRate: 48_000, sourceChannels: 1, reason: "start"),
            ], restarts: [], overruns: 0),
            SourceManifest(kind: .mic, uid: "bi", name: "Built-in", file: "mic - Built-in (backup).m4a", channels: 1, segments: [
                SegmentRecord(file: "mic - Built-in (backup).seg000.caf", startNanos: s + 1_000_000_000, frames: 48_000, endNanos: s + 2_000_000_000, sourceRate: 48_000, sourceChannels: 1, reason: "start"),
                SegmentRecord(file: "mic - Built-in (backup).seg001.caf", startNanos: s + 2_500_000_000, frames: 24_000, endNanos: s + 3_000_000_000, sourceRate: 48_000, sourceChannels: 1, reason: "restart: backup"),
            ], restarts: [], overruns: 0),
        ]
        try m.save(to: dir)
        try writeCAF(dir.appendingPathComponent("computer audio.seg000.caf"), samples: [Float](repeating: 0, count: 144_000 * 2), channels: 2)
        try writeCAF(dir.appendingPathComponent("mic - AirPods.seg000.caf"), samples: sine(frames: 48_000, channels: 1), channels: 1)
        try writeCAF(dir.appendingPathComponent("mic - Built-in (backup).seg000.caf"), samples: sine(frames: 48_000, channels: 1), channels: 1)
        try writeCAF(dir.appendingPathComponent("mic - Built-in (backup).seg001.caf"), samples: sine(frames: 24_000, channels: 1), channels: 1)
        let report = try Finalizer.run(dir)
        #expect(report.totalFrames == 144_000)
        #expect(report.gaps.filter { $0.track == "mic - Built-in (backup)" } == [
            GapRecord(track: "mic - Built-in (backup)", atFrame: 0, frames: 48_000),
            GapRecord(track: "mic - Built-in (backup)", atFrame: 96_000, frames: 24_000),
        ])
        let backup = dir.appendingPathComponent("mic - Built-in (backup).m4a")
        #expect(try AVAudioFile(forReading: backup).length == 144_000)
        #expect(try rms(backup, from: 20_000, frames: 4_800) < 0.01)
        #expect(try rms(backup, from: 60_000, frames: 4_800) > 0.1)
        #expect(try rms(backup, from: 105_000, frames: 4_800) < 0.01)
        #expect(try rms(backup, from: 130_000, frames: 4_800) > 0.1)
        let mix = dir.appendingPathComponent("mix.m4a")
        #expect(try rms(mix, from: 60_000, frames: 4_800) > 0.1)
        #expect(try rms(mix, from: 105_000, frames: 4_800) < 0.01)
        #expect(try rms(mix, from: 130_000, frames: 4_800) > 0.1)
    }

    @Test func backupTracksDoNotLowerTheMix() throws {
        func mixRMS(backups: Int) throws -> Float {
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("fin-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let s: UInt64 = 10_000_000_000
            var m = SessionManifest(appVersion: "t", startedAt: Date(), sessionStartNanos: s)
            m.sources = [
                SourceManifest(kind: .computer, uid: nil, name: "Computer audio", file: "computer audio.m4a", channels: 2, segments: [
                    SegmentRecord(file: "computer audio.seg000.caf", startNanos: s, frames: 144_000, endNanos: s + 3_000_000_000, sourceRate: 48_000, sourceChannels: 2, reason: "start"),
                ], restarts: [], overruns: 0),
                SourceManifest(kind: .mic, uid: "ap", name: "AirPods", file: "mic - AirPods.m4a", channels: 1, segments: [
                    SegmentRecord(file: "mic - AirPods.seg000.caf", startNanos: s, frames: 96_000, endNanos: s + 2_000_000_000, sourceRate: 48_000, sourceChannels: 1, reason: "start"),
                ], restarts: [], overruns: 0),
            ]
            for (uid, name) in [("bi", "Built-in"), ("usb", "USB")].prefix(backups) {
                let base = "mic - \(name) (backup)"
                m.sources.append(SourceManifest(kind: .mic, uid: uid, name: name, file: base + ".m4a", channels: 1, segments: [
                    SegmentRecord(file: base + ".seg000.caf", startNanos: s + 2_000_000_000, frames: 48_000, endNanos: s + 3_000_000_000, sourceRate: 48_000, sourceChannels: 1, reason: "start"),
                ], restarts: [], overruns: 0, backup: true))
                try writeCAF(dir.appendingPathComponent(base + ".seg000.caf"), samples: sine(frames: 48_000, channels: 1), channels: 1)
            }
            try m.save(to: dir)
            try writeCAF(dir.appendingPathComponent("computer audio.seg000.caf"), samples: [Float](repeating: 0, count: 144_000 * 2), channels: 2)
            try writeCAF(dir.appendingPathComponent("mic - AirPods.seg000.caf"), samples: sine(frames: 96_000, channels: 1), channels: 1)
            try Finalizer.run(dir)
            return try rms(dir.appendingPathComponent("mix.m4a"), from: 24_000, frames: 4_800)
        }
        let without = try mixRMS(backups: 0)
        #expect(without > 0.1)
        for backups in [1, 2] {
            #expect(abs(20 * log10(try mixRMS(backups: backups) / without)) < 0.5)
        }
    }

    @Test func sourceThatNeverConnectedBecomesASilentFullLengthTrack() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("fin-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let s: UInt64 = 10_000_000_000
        var m = SessionManifest(appVersion: "t", startedAt: Date(), sessionStartNanos: s)
        m.sources = [
            SourceManifest(kind: .computer, uid: nil, name: "Computer audio", file: "computer audio.m4a", channels: 2, segments: [
                SegmentRecord(file: "computer audio.seg000.caf", startNanos: s, frames: 96_000, endNanos: s + 2_000_000_000, sourceRate: 48_000, sourceChannels: 2, reason: "start"),
            ], restarts: [], overruns: 0),
            SourceManifest(kind: .mic, uid: "ap", name: "AirPods", file: "mic - AirPods.m4a", channels: 1, segments: [], restarts: [], overruns: 0),
        ]
        try m.save(to: dir)
        try writeCAF(dir.appendingPathComponent("computer audio.seg000.caf"), samples: sine(frames: 96_000, channels: 2, amplitude: 0.25), channels: 2)
        let report = try Finalizer.run(dir)
        #expect(report.totalFrames == 96_000)
        #expect(report.gaps.isEmpty)
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()
        #expect(names == ["computer audio.m4a", "mic - AirPods.m4a", "mix.m4a", "session.json"])
        let mic = dir.appendingPathComponent("mic - AirPods.m4a")
        #expect(try AVAudioFile(forReading: mic).length == 96_000)
        #expect(try rms(mic, from: 40_000, frames: 4_800) < 0.01)
        #expect(try rms(dir.appendingPathComponent("mix.m4a"), from: 40_000, frames: 4_800) > 0.15)
        #expect(try SessionManifest.load(from: dir).sources[1].segments.isEmpty)
    }

    @Test func sessionWithNoAudioAtAllFinalizesToEmptyFiles() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("fin-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var m = SessionManifest(appVersion: "t", startedAt: Date(), sessionStartNanos: 10_000_000_000)
        m.sources = [
            SourceManifest(kind: .mic, uid: "ap", name: "AirPods", file: "mic - AirPods.m4a", channels: 1, segments: [], restarts: [], overruns: 0),
        ]
        try m.save(to: dir)
        let report = try Finalizer.run(dir)
        #expect(report.totalFrames == 0)
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()
        #expect(names == ["mic - AirPods.m4a", "mix.m4a", "session.json"])
        #expect(try AVAudioFile(forReading: dir.appendingPathComponent("mix.m4a")).length == 0)
        #expect(try SessionManifest.load(from: dir).finalize == report)
    }

    @Test func manySegmentsFinalizeUnderTheDefaultOpenFileLimit() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("fin-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let s: UInt64 = 10_000_000_000
        let n = 400
        var segments: [SegmentRecord] = []
        for i in 0..<n {
            let file = SessionNaming.segmentFile(base: "mic - A", index: i)
            try writeCAF(dir.appendingPathComponent(file), samples: sine(frames: 4_800, channels: 1), channels: 1)
            let start = s + UInt64(i) * 100_000_000
            segments.append(SegmentRecord(
                file: file, startNanos: start, frames: 4_800, endNanos: start + 100_000_000, sourceRate: 48_000,
                sourceChannels: 1, reason: "restart"))
        }
        var m = SessionManifest(appVersion: "t", startedAt: Date(), sessionStartNanos: s)
        m.sources = [SourceManifest(kind: .mic, uid: "u", name: "A", file: "mic - A.m4a", channels: 1, segments: segments, restarts: [], overruns: 0)]
        try m.save(to: dir)
        var limit = rlimit()
        getrlimit(RLIMIT_NOFILE, &limit)
        var saved = limit
        limit.rlim_cur = 256
        setrlimit(RLIMIT_NOFILE, &limit)
        defer { setrlimit(RLIMIT_NOFILE, &saved) }
        let report = try Finalizer.run(dir)
        #expect(report.totalFrames == n * 4_800)
        #expect(report.gaps.isEmpty)
        #expect(try AVAudioFile(forReading: dir.appendingPathComponent("mic - A.m4a")).length == AVAudioFramePosition(n * 4_800))
        #expect(try rms(dir.appendingPathComponent("mic - A.m4a"), from: (n - 2) * 4_800, frames: 4_800) > 0.2)
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasSuffix(".caf") }.isEmpty)
    }

    @Test func aSegmentThatBreaksWhileReadingKeepsItsStartAndIsReported() throws {
        let dir = try makeSession()
        let url = dir.appendingPathComponent("mic - A.seg000.caf")
        let size = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as! Int
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: UInt64(size / 2))
        try handle.close()
        let report = try Finalizer.run(dir)
        #expect(report.totalFrames == 144_000)
        #expect(report.unreadable == ["mic - A.seg000.caf"])
        #expect(try rms(dir.appendingPathComponent("mic - A.m4a"), from: 5_000, frames: 4_800) > 0.2)
        #expect(FileManager.default.fileExists(atPath: url.path))
        #expect(try SessionManifest.load(from: dir).finalize == report)
    }

    @Test func unreadableSegmentIsSkippedKeptAndReported() throws {
        let dir = try makeSession()
        try Data(repeating: 1, count: 100).write(to: dir.appendingPathComponent("mic - A.seg001.caf"))
        let report = try Finalizer.run(dir)
        #expect(report.totalFrames == 144_000)
        #expect(report.unreadable == ["mic - A.seg001.caf"])
        #expect(try rms(dir.appendingPathComponent("mic - A.m4a"), from: 10_000, frames: 4_800) > 0.2)
        #expect(try rms(dir.appendingPathComponent("mic - A.m4a"), from: 100_000, frames: 4_800) < 0.01)
        let cafs = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasSuffix(".caf") }
        #expect(cafs == ["mic - A.seg001.caf"])
        #expect(try SessionManifest.load(from: dir).finalize == report)
    }

    private func decode(_ url: URL) throws -> [Float] {
        let f = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: true)
        let buf = AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: AVAudioFrameCount(f.length))!
        try f.read(into: buf)
        return Array(UnsafeBufferPointer(start: buf.floatChannelData![0], count: Int(buf.frameLength) * Int(f.processingFormat.channelCount)))
    }

    private func encodeSerially(_ pcm: [Float], channels: Int, to url: URL) throws {
        let w = try AACWriter(url: url, channels: channels)
        var start = 0
        while start < pcm.count {
            let end = min(start + Finalizer.chunkFrames * channels, pcm.count)
            try w.write(Array(pcm[start..<end]))
            start = end
        }
        try w.closeAndVerify()
    }

    @Test func concurrentEncodingMatchesSerialEncoding() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("fin-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let s: UInt64 = 10_000_000_000
        let frames = 240_000
        let tracks: [(base: String, channels: Int, amplitude: Float)] = [("computer audio", 2, 0.25), ("mic - A", 1, 0.5), ("mic - B", 1, 0.3)]
        var m = SessionManifest(appVersion: "t", startedAt: Date(), sessionStartNanos: s)
        var pcms: [[Float]] = []
        for t in tracks {
            let file = SessionNaming.segmentFile(base: t.base, index: 0)
            let pcm = sine(frames: frames, channels: t.channels, amplitude: t.amplitude)
            pcms.append(pcm)
            try writeCAF(dir.appendingPathComponent(file), samples: pcm, channels: t.channels)
            m.sources.append(SourceManifest(
                kind: t.channels == 2 ? .computer : .mic, uid: nil, name: t.base, file: t.base + ".m4a", channels: t.channels,
                segments: [SegmentRecord(
                    file: file, startNanos: s, frames: frames, endNanos: s + 5_000_000_000, sourceRate: 48_000,
                    sourceChannels: t.channels, reason: "start")],
                restarts: [], overruns: 0))
        }
        try m.save(to: dir)
        #expect(try Finalizer.run(dir).totalFrames == frames)
        let ref = FileManager.default.temporaryDirectory.appendingPathComponent("ref-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: ref, withIntermediateDirectories: true)
        let mix = Mixer.mixToStereo(mono: [pcms[1], pcms[2]], stereo: [pcms[0]])
        let expected = zip(tracks, pcms).map { ($0.base + ".m4a", $0.channels, $1) } + [(Finalizer.mixFile, 2, mix)]
        for (name, channels, pcm) in expected {
            try encodeSerially(pcm, channels: channels, to: ref.appendingPathComponent(name))
            let got = try decode(dir.appendingPathComponent(name))
            let want = try decode(ref.appendingPathComponent(name))
            #expect(got.count == frames * channels, "\(name)")
            #expect(got.count == want.count, "\(name)")
            let diff = zip(got, want).map { abs($0 - $1) }.max() ?? 0
            #expect(diff <= 0.01, "\(name) max diff \(diff)")
        }
    }

    private final class LiveFakeSource: CaptureSource, @unchecked Sendable {
        override func start() throws {}
        override func stop() { writer.stop() }
    }

    @Test func launchRecoveryLeavesALiveSessionAloneAndRecoversOldOnes() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("lr-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let old = root.appendingPathComponent("old")
        try FileManager.default.moveItem(at: try makeSession(), to: old)
        let snapshot = Finalizer.sessionFolders(root: root)
        let r = SessionRecorder(
            root: root, appVersion: "t",
            makeSource: { spec, dir, base in LiveFakeSource(spec: spec, dir: dir, baseName: base, channels: 2) },
            freeBytes: { _ in 3_000_000_000 })
        let live = try r.start(specs: [SourceSpec(kind: .computer, uid: nil, name: "Computer audio")])
        try Data([1, 2, 3]).write(to: live.appendingPathComponent("computer audio.seg000.caf"))
        let before = try FileManager.default.contentsOfDirectory(atPath: live.path).sorted()
        let recovered = Finalizer.recoverAll(dirs: snapshot)
        #expect(recovered.map(\.path) == [root.appendingPathComponent(SessionNaming.sessionName(startedAt, title: "")).path])
        #expect(try FileManager.default.contentsOfDirectory(atPath: live.path).sorted() == before)
        #expect(try SessionManifest.load(from: live).finalize == nil)
        r.stop()
    }

    private func chapterList(_ url: URL) async throws -> [String] {
        let groups = try await AVURLAsset(url: url).loadChapterMetadataGroups(bestMatchingPreferredLanguages: ["und"])
        var result: [String] = []
        for g in groups {
            let title = try await g.items.first?.load(.stringValue) ?? ""
            result.append(String(format: "%.3f ", g.timeRange.start.seconds) + title)
        }
        return result
    }

    private func pcm(_ url: URL) throws -> [Float] {
        let f = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: true)
        let buf = AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: AVAudioFrameCount(f.length))!
        try f.read(into: buf)
        return Array(UnsafeBufferPointer(start: buf.floatChannelData![0], count: Int(buf.frameLength) * Int(f.processingFormat.channelCount)))
    }

    @Test func chapterWriterKeepsTheAudioBitExact() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("a.m4a")
        let writer = try AACWriter(url: url, channels: 2)
        try writer.write(sine(frames: 100_000, channels: 2))
        try writer.closeAndVerify()
        let before = try pcm(url)
        try ChapterWriter.write([Chapter(startMillis: 0, title: "Start"), Chapter(startMillis: 1_000, title: "про деньги")], into: url)
        #expect(try AVAudioFile(forReading: url).length == 100_000)
        #expect(try pcm(url) == before)
        #expect(try await chapterList(url) == ["0.000 Start", "1.000 про деньги"])
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path) == ["a.m4a"])
    }

    private func audioBytes(_ url: URL) throws -> Data {
        let movie = AVMovie(url: url)
        let reader = try AVAssetReader(asset: movie)
        let output = AVAssetReaderTrackOutput(track: movie.tracks.first { $0.mediaType == .audio }!, outputSettings: nil)
        reader.add(output)
        #expect(reader.startReading())
        var bytes = Data()
        while let buffer = output.copyNextSampleBuffer() {
            guard let block = buffer.dataBuffer else { continue }
            var chunk = Data(count: CMBlockBufferGetDataLength(block))
            chunk.withUnsafeMutableBytes { _ = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: $0.count, destination: $0.baseAddress!) }
            bytes.append(chunk)
        }
        return bytes
    }

    private func titleTag(_ url: URL) async throws -> String? {
        let items = try await AVURLAsset(url: url).load(.commonMetadata)
        return try await AVMetadataItem.metadataItems(from: items, filteredByIdentifier: .commonIdentifierTitle).first?.load(.stringValue)
    }

    @Test func titleTagIsWrittenWithOrWithoutChapters() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tt-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("a.m4a")
        let both = dir.appendingPathComponent("b.m4a")
        let writer = try AACWriter(url: url, channels: 2)
        try writer.write(sine(frames: 100_000, channels: 2))
        try writer.closeAndVerify()
        try FileManager.default.copyItem(at: url, to: both)
        let before = try audioBytes(url)
        #expect(before.count > 1_000)
        try ChapterWriter.write([], title: "2026-09-24 14-00 Планёрка", into: url)
        #expect(try audioBytes(url) == before)
        #expect(try AVAudioFile(forReading: url).length == 100_000)
        #expect(try await titleTag(url) == "2026-09-24 14-00 Планёрка")
        #expect(try await chapterList(url).isEmpty)
        try ChapterWriter.write([Chapter(startMillis: 0, title: "Start")], title: "Созвон", into: both)
        #expect(try audioBytes(both) == before)
        #expect(try AVAudioFile(forReading: both).length == 100_000)
        #expect(try await titleTag(both) == "Созвон")
        #expect(try await chapterList(both) == ["0.000 Start"])
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted() == ["a.m4a", "b.m4a"])
    }

    @Test func marksBecomeChaptersInEveryFileAndMarksText() async throws {
        let dir = try makeSession()
        var m = try SessionManifest.load(from: dir)
        m.addMark(atNanos: m.sessionStartNanos + 2_500_000_000)
        m.addMark(atNanos: m.sessionStartNanos + 1_000_000_000)
        m.setMarkText(id: 2, "про деньги")
        try m.save(to: dir)
        try Finalizer.run(dir)
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()
        #expect(names == ["computer audio.m4a", "marks.txt", "mic - A.m4a", "mix.m4a", "session.json"])
        for n in ["computer audio.m4a", "mic - A.m4a", "mix.m4a"] {
            let url = dir.appendingPathComponent(n)
            #expect(try await chapterList(url) == ["0.000 Start", "1.000 про деньги", "2.500 Mark 1"], "\(n)")
            #expect(try AVAudioFile(forReading: url).length == 144_000, "\(n)")
        }
        let text = try String(contentsOf: dir.appendingPathComponent("marks.txt"), encoding: .utf8)
        #expect(text == "00:00:01  про деньги\n00:00:02  Mark 1\n")
    }

    @Test func recoveryKeepsTheMarks() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("rec-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let pending = root.appendingPathComponent("pending")
        try FileManager.default.moveItem(at: try makeSession(), to: pending)
        var m = try SessionManifest.load(from: pending)
        m.addMark(atNanos: m.sessionStartNanos + 2_000_000_000)
        try m.save(to: pending)
        let name = SessionNaming.sessionName(startedAt, title: "")
        let done = root.appendingPathComponent(name)
        #expect(Finalizer.recoverAll(dirs: Finalizer.sessionFolders(root: root)).map(\.path) == [done.path])
        #expect(try await chapterList(done.appendingPathComponent(name + ".m4a")) == ["0.000 Start", "2.000 Mark 1"])
        #expect(try SessionManifest.load(from: done).marks.count == 1)
    }

    @Test func sessionWithoutMarksGetsNoChapters() async throws {
        let dir = try makeSession()
        try Finalizer.run(dir)
        #expect(try await chapterList(dir.appendingPathComponent("mix.m4a")).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("marks.txt").path))
    }

    private func namedSession(_ title: String) throws -> (root: URL, dir: URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("nm-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let dir = root.appendingPathComponent("rec")
        try FileManager.default.moveItem(at: try makeSession(), to: dir)
        var m = try SessionManifest.load(from: dir)
        m.title = title
        try m.save(to: dir)
        return (root, dir)
    }

    @Test func finishNamesTheMixAndTheFolderAfterTheTitle() async throws {
        let (root, dir) = try namedSession("Планёрка: Q3/план")
        let name = SessionNaming.sessionName(startedAt, title: "Планёрка: Q3/план")
        let out = try Finalizer.finish(dir)
        #expect(out.path == root.appendingPathComponent(name).path)
        #expect(!FileManager.default.fileExists(atPath: dir.path))
        let names = Set(try FileManager.default.contentsOfDirectory(atPath: out.path))
        #expect(names == ["computer audio.m4a", "mic - A.m4a", name + ".m4a", "session.json"])
        #expect(try await titleTag(out.appendingPathComponent(name + ".m4a")) == name)
        #expect(try await chapterList(out.appendingPathComponent(name + ".m4a")).isEmpty)
        #expect(try await titleTag(out.appendingPathComponent("mic - A.m4a")) == nil)
    }

    @Test func takenNamesGetANumberAndASessionKeepsItsOwnNumber() throws {
        let (root, dir) = try namedSession("Sync")
        let name = SessionNaming.sessionName(startedAt, title: "Sync")
        try FileManager.default.createDirectory(at: root.appendingPathComponent(name), withIntermediateDirectories: false)
        #expect(try Finalizer.finish(dir).lastPathComponent == name + " 2")
        let (other, started) = try namedSession("Sync")
        try FileManager.default.createDirectory(at: other.appendingPathComponent(name), withIntermediateDirectories: false)
        let own = other.appendingPathComponent(name + " 2")
        try FileManager.default.moveItem(at: started, to: own)
        #expect(try Finalizer.finish(own).path == own.path)
        #expect(FileManager.default.fileExists(atPath: own.appendingPathComponent(name + ".m4a").path))
    }

    @Test func recoveryAppliesTheSavedTitle() async throws {
        let (root, _) = try namedSession("Созвон")
        let name = SessionNaming.sessionName(startedAt, title: "Созвон")
        let done = root.appendingPathComponent(name)
        #expect(Finalizer.recoverAll(dirs: Finalizer.sessionFolders(root: root)).map(\.path) == [done.path])
        #expect(try await titleTag(done.appendingPathComponent(name + ".m4a")) == name)
    }

    @Test func finishAndDeliverKeepsASessionLocalThenDeliversItWithTheNextOne() throws {
        let (work, dir) = try namedSession("Sync")
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("out-\(UUID().uuidString)")
        let name = SessionNaming.sessionName(startedAt, title: "Sync")
        let failed = #expect(throws: DeliveryFailed.self) { try Delivery.finishAndDeliver(dir, output: out) }
        #expect(failed?.dir.path == work.appendingPathComponent(name).path)
        #expect(failed?.reason == "folder not found: \(out.path)")
        #expect(FileManager.default.fileExists(atPath: work.appendingPathComponent(name).appendingPathComponent(name + ".m4a").path))
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: false)
        let next = work.appendingPathComponent("next")
        try FileManager.default.moveItem(at: try makeSession(), to: next)
        let dateName = SessionNaming.sessionName(startedAt, title: "")
        #expect(try Delivery.finishAndDeliver(next, output: out).path == out.appendingPathComponent(dateName).path)
        #expect(try FileManager.default.contentsOfDirectory(atPath: out.path).sorted() == [dateName, name])
        #expect(try FileManager.default.contentsOfDirectory(atPath: work.path).isEmpty)
    }

    @Test func launchRecoveryFinishesCrashedSessionsThenDeliversThem() throws {
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("work-\(UUID().uuidString)")
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("out-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: try makeSession(), to: work.appendingPathComponent("crashed"))
        let failure = Delivery.recover(Finalizer.sessionFolders(root: work), work: work, output: out, onError: { dir, error in
            Issue.record("\(dir.lastPathComponent): \(error)")
        })
        #expect(failure == nil)
        let name = SessionNaming.sessionName(startedAt, title: "")
        #expect(try FileManager.default.contentsOfDirectory(atPath: out.path) == [name])
        #expect(FileManager.default.fileExists(atPath: out.appendingPathComponent(name).appendingPathComponent(name + ".m4a").path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: work.path).isEmpty)
    }
}

extension FinalizerTests {
    private func slide(_ dir: URL, atSeconds s: Double, _ image: CGImage) throws -> Slide {
        let url = dir.appendingPathComponent("\(s).heic")
        try Frames.heic(image).write(to: url)
        return Slide(offsetNanos: UInt64(s * 1e9), url: url)
    }

    private func videoKeyFrames(_ url: URL) throws -> [Bool] {
        let movie = AVMovie(url: url)
        let reader = try AVAssetReader(asset: movie)
        let output = AVAssetReaderTrackOutput(track: movie.tracks.first { $0.mediaType == .video }!, outputSettings: nil)
        reader.add(output)
        #expect(reader.startReading())
        var keys: [Bool] = []
        while let buffer = output.copyNextSampleBuffer() {
            guard buffer.numSamples > 0 else { continue }
            let attachments = CMSampleBufferGetSampleAttachmentsArray(buffer, createIfNecessary: false) as? [[CFString: Any]]
            keys.append(!(attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool ?? false))
        }
        return keys
    }

    private func videoTimes(_ url: URL) throws -> [Double] {
        let movie = AVMovie(url: url)
        let reader = try AVAssetReader(asset: movie)
        let output = AVAssetReaderTrackOutput(track: movie.tracks.first { $0.mediaType == .video }!, outputSettings: nil)
        reader.add(output)
        #expect(reader.startReading())
        var times: [Double] = []
        while let buffer = output.copyNextSampleBuffer() {
            if buffer.numSamples > 0 { times.append((buffer.presentationTimeStamp.seconds * 1000).rounded() / 1000) }
        }
        return times
    }

    @Test func slideTimesStartWithTheFirstFrameDropLateFramesAndKeepTheLaterOfTwins() {
        let a = URL(fileURLWithPath: "/a"), b = URL(fileURLWithPath: "/b"), c = URL(fileURLWithPath: "/c")
        let times = SlideshowWriter.times(
            [Slide(offsetNanos: 2_000, url: b), Slide(offsetNanos: 1_000, url: a), Slide(offsetNanos: 2_000, url: c), Slide(offsetNanos: 9_000, url: a)],
            endNanos: 5_000)
        #expect(times.map(\.atNanos) == [0, 2_000])
        #expect(times.map(\.slide.url) == [a, c])
        #expect(SlideshowWriter.times([Slide(offsetNanos: 0, url: a)], endNanos: 5_000).map(\.atNanos) == [0])
        #expect(SlideshowWriter.times([], endNanos: 5_000).isEmpty)
    }

    @Test func slideshowIsHEVCWithTheSameAudioChaptersAndTitle() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sl-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let audio = dir.appendingPathComponent("mix.m4a")
        let writer = try AACWriter(url: audio, channels: 2)
        try writer.write(sine(frames: 144_000, channels: 2))
        try writer.closeAndVerify()
        let slides = [
            try slide(dir, atSeconds: 1, screen(rects: [CGRect(x: 100, y: 100, width: 300, height: 200)])),
            try slide(dir, atSeconds: 2, screen(width: 1440, height: 900, gray: 0)),
        ]
        let out = dir.appendingPathComponent("mix.mp4")
        try SlideshowWriter.write(
            audio: audio, slides: slides, chapters: [Chapter(startMillis: 0, title: "Start"), Chapter(startMillis: 1_500, title: "про деньги")],
            title: "Созвон", to: out)
        #expect(try videoTimes(out) == [0, 2])
        #expect(try videoKeyFrames(out) == [true, true])
        let asset = AVURLAsset(url: out)
        let track = try await asset.loadTracks(withMediaType: .video).first!
        let format = try await track.load(.formatDescriptions).first!
        #expect(format.mediaSubType == .hevc)
        #expect(format.dimensions.width == 1920 && format.dimensions.height == 1080)
        let range = try await track.load(.timeRange)
        #expect(abs(range.end.seconds - 3) < 0.01)
        #expect(try audioBytes(out) == audioBytes(audio))
        #expect(try await chapterList(out) == ["0.000 Start", "1.500 про деньги"])
        #expect(try await titleTag(out) == "Созвон")
        let bytes = try Data(contentsOf: out)
        #expect(bytes.range(of: Data("hvc1".utf8)) != nil)
        #expect(bytes.range(of: Data("hev1".utf8)) == nil)
    }

    @Test func slideshowWithoutUsableFramesFails() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sl-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let audio = dir.appendingPathComponent("mix.m4a")
        let writer = try AACWriter(url: audio, channels: 2)
        try writer.write(sine(frames: 48_000, channels: 2))
        try writer.closeAndVerify()
        let late = try slide(dir, atSeconds: 5, screen())
        #expect(throws: SlideshowError.self) {
            try SlideshowWriter.write(audio: audio, slides: [late], chapters: [], title: nil, to: dir.appendingPathComponent("mix.mp4"))
        }
        let missing = Slide(offsetNanos: 0, url: dir.appendingPathComponent("gone.heic"))
        #expect(throws: FrameError.self) {
            try SlideshowWriter.write(audio: audio, slides: [missing], chapters: [], title: nil, to: dir.appendingPathComponent("mix.mp4"))
        }
        let good = try slide(dir, atSeconds: 0, screen())
        let broken = dir.appendingPathComponent("broken.heic")
        try Data([1, 2, 3]).write(to: broken)
        let out = dir.appendingPathComponent("mix.mp4")
        #expect(throws: FrameError.self) {
            try SlideshowWriter.write(audio: audio, slides: [good, Slide(offsetNanos: 500_000_000, url: broken)], chapters: [], title: nil, to: out)
        }
        #expect(!FileManager.default.fileExists(atPath: out.path))
    }

    /// A folder with a 3 s stereo mix.m4a for the slideshow tests.
    private func mixFolder() throws -> (dir: URL, audio: URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sl-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let audio = dir.appendingPathComponent(Finalizer.mixFile)
        let writer = try AACWriter(url: audio, channels: 2)
        try writer.write(sine(frames: 144_000, channels: 2))
        try writer.closeAndVerify()
        return (dir, audio)
    }

    private func subtitleSamples(_ url: URL) async throws -> [String] {
        let asset = AVURLAsset(url: url)
        let track = try #require(try await asset.loadTracks(withMediaType: .subtitle).first)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        reader.add(output)
        reader.startReading()
        var out: [String] = []
        while let sample = output.copyNextSampleBuffer() {
            guard sample.numSamples > 0, let buffer = sample.dataBuffer else { continue }  // the reader also emits empty marker buffers
            let data = try buffer.dataBytes()
            let text = String(decoding: data.dropFirst(2), as: UTF8.self)
            out.append(String(format: "%.3f+%.3f ", sample.presentationTimeStamp.seconds, sample.duration.seconds) + text)
        }
        return out
    }

    @Test func slideshowCarriesRussianSubtitlesThatAreOffByDefault() async throws {
        let (dir, audio) = try mixFolder()
        let slides = [try slide(dir, atSeconds: 0, screen())]
        let out = dir.appendingPathComponent("mix.mp4")
        try SlideshowWriter.write(
            audio: audio, slides: slides, chapters: [Chapter(startMillis: 0, title: "Start"), Chapter(startMillis: 1_500, title: "Mark 1")],
            subtitles: [SubtitleCue(startMillis: 500, endMillis: 1_000, text: "Я: Привет"),
                        SubtitleCue(startMillis: 1_100, endMillis: 2_000, text: "Собеседники: Да")],
            title: nil, to: out)
        let asset = AVURLAsset(url: out)
        let group = try #require(try await asset.loadMediaSelectionGroup(for: .legible))
        #expect(group.options.contains { $0.extendedLanguageTag == "ru" })
        let track = try #require(try await asset.loadTracks(withMediaType: .subtitle).first)
        #expect(try await track.load(.isEnabled) == false)
        #expect(try await subtitleSamples(out) == [
            "0.000+0.500 ", "0.500+0.600 Я: Привет", "1.100+0.900 Собеседники: Да", "2.000+1.000 ",
        ])
        #expect(try await chapterList(out) == ["0.000 Start", "1.500 Mark 1"])
    }

    @Test func aCueInTheLastMomentOfTheAudioIsDropped() async throws {
        let (dir, audio) = try mixFolder()
        let out = dir.appendingPathComponent("mix.mp4")
        try SlideshowWriter.write(
            audio: audio, slides: [try slide(dir, atSeconds: 0, screen())], chapters: [],
            subtitles: [SubtitleCue(startMillis: 1_000, endMillis: 2_000, text: "Я: Раз"),
                        SubtitleCue(startMillis: 2_950, endMillis: 3_250, text: "Я: Да")],
            title: nil, to: out)
        #expect(try await subtitleSamples(out) == ["0.000+1.000 ", "1.000+1.000 Я: Раз", "2.000+1.000 "])
        try SlideshowWriter.write(
            audio: audio, slides: [try slide(dir, atSeconds: 0, screen())], chapters: [],
            subtitles: [SubtitleCue(startMillis: 2_950, endMillis: 3_250, text: "Я: Да")], title: nil, to: out)
        #expect(try await AVURLAsset(url: out).loadTracks(withMediaType: .subtitle).isEmpty)
    }
}

extension FinalizerTests {
    private func addFrames(_ dir: URL, _ items: [(seconds: Double, data: Data)]) throws {
        var m = try SessionManifest.load(from: dir)
        for item in items {
            let frame = m.addFrame(atNanos: m.sessionStartNanos + UInt64(item.seconds * 1e9))
            let url = dir.appendingPathComponent(frame.file)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try item.data.write(to: url)
        }
        try m.save(to: dir)
    }

    @Test func framesBecomeTheSlideshowAndAreDeletedAfterwards() async throws {
        let (_, dir) = try namedSession("Demo")
        try addFrames(dir, [(0.5, try Frames.heic(screen())), (1.5, try Frames.heic(screen(gray: 0)))])
        var m = try SessionManifest.load(from: dir)
        m.addMark(atNanos: m.sessionStartNanos + 1_000_000_000)
        try m.save(to: dir)
        let out = try Finalizer.finish(dir)
        let name = SessionNaming.sessionName(startedAt, title: "Demo")
        #expect(try SessionManifest.load(from: out).finalize?.slidesError == nil)
        let names = Set(try FileManager.default.contentsOfDirectory(atPath: out.path))
        #expect(names == ["computer audio.m4a", "marks.txt", "mic - A.m4a", name + ".m4a", name + ".mp4", "session.json"])
        let video = out.appendingPathComponent(name + ".mp4")
        #expect(try audioBytes(video) == audioBytes(out.appendingPathComponent(name + ".m4a")))
        #expect(try await chapterList(video) == ["0.000 Start", "1.000 Mark 1"])
        #expect(try await titleTag(video) == name)
        #expect(try videoTimes(video) == [0, 1.5])
    }

    @Test func aBrokenFrameKeepsTheAudioAndTheFramesAndReportsTheError() throws {
        let (_, dir) = try namedSession("Broken")
        try addFrames(dir, [(0.5, Data([1, 2, 3]))])
        let out = try Finalizer.finish(dir)
        let name = SessionNaming.sessionName(startedAt, title: "Broken")
        #expect(try SessionManifest.load(from: out).finalize?.slidesError == "500000000.heic: could not decode frame")
        let names = Set(try FileManager.default.contentsOfDirectory(atPath: out.path))
        #expect(names == ["computer audio.m4a", "frames", "mic - A.m4a", name + ".m4a", "session.json"])
        #expect(try AVAudioFile(forReading: out.appendingPathComponent(name + ".m4a")).length == 144_000)
    }

    @Test func framesOfASessionWithoutAudioAreKept() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("fin-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var m = SessionManifest(appVersion: "t", startedAt: Date(), sessionStartNanos: 10_000_000_000)
        m.sources = [
            SourceManifest(kind: .mic, uid: "ap", name: "AirPods", file: "mic - AirPods.m4a", channels: 1, segments: [], restarts: [], overruns: 0),
        ]
        try m.save(to: dir)
        try addFrames(dir, [(0.5, try Frames.heic(screen()))])
        #expect(try Finalizer.run(dir).totalFrames == 0)
        let names = Set(try FileManager.default.contentsOfDirectory(atPath: dir.path))
        #expect(names == ["frames", "mic - AirPods.m4a", "mix.m4a", "session.json"])
    }
}

extension FinalizerTests {
    private final class Asked: @unchecked Sendable {
        var names: [String] = []
    }

    @Test func finalizerTranscribesEachTrackWithItsSpeaker() throws {
        let dir = try makeSession()
        let asked = Asked()
        let report = try Finalizer.run(dir, speech: { url in
            asked.names.append(url.lastPathComponent)
            return url.lastPathComponent.hasPrefix("mic")
                ? [SpokenWord(startMillis: 1_000, endMillis: 1_400, text: "Привет")]
                : [SpokenWord(startMillis: 100, endMillis: 600, text: "Начнём")]
        })
        #expect(asked.names.sorted() == ["computer audio.m4a", "mic - A.m4a"])
        #expect(report.transcriptError == nil)
        let text = try String(contentsOf: dir.appendingPathComponent(Transcript.textFile), encoding: .utf8)
        #expect(text == "[00:00:00] Собеседники: Начнём\n[00:00:01] Я: Привет\n")
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent(Transcript.srtFile).path))
    }

    @Test func macAudioHeardByTheMicIsNotRepeatedAsMine() throws {
        let dir = try makeSession()
        try Finalizer.run(dir, speech: { url in
            url.lastPathComponent.hasPrefix("mic")
                ? [SpokenWord(startMillis: 100, endMillis: 300, text: "Great"), SpokenWord(startMillis: 350, endMillis: 600, text: "and"),
                   SpokenWord(startMillis: 650, endMillis: 900, text: "small."), SpokenWord(startMillis: 2_000, endMillis: 2_400, text: "Да")]
                : [SpokenWord(startMillis: 0, endMillis: 250, text: "great"), SpokenWord(startMillis: 300, endMillis: 550, text: "and"),
                   SpokenWord(startMillis: 600, endMillis: 850, text: "small,")]
        })
        let text = try String(contentsOf: dir.appendingPathComponent(Transcript.textFile), encoding: .utf8)
        #expect(text == "[00:00:00] Собеседники: great and small,\n[00:00:02] Я: Да\n")
    }

    @Test func aTranscriptionFailureKeepsTheRecordingAndIsReported() throws {
        struct Boom: Error, CustomStringConvertible { var description: String { "no model" } }
        let dir = try makeSession()
        let report = try Finalizer.run(dir, speech: { _ in throw Boom() })
        #expect(report.transcriptError == "no model")
        #expect(try AVAudioFile(forReading: dir.appendingPathComponent("mix.m4a")).length == 144_000)
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent(Transcript.textFile).path))
    }

    @Test func tracksFailingDifferentlyAreNamedAndTheTextIsCut() throws {
        struct Boom: Error, CustomStringConvertible { let description: String }
        let dir = try makeSession()
        let report = try Finalizer.run(dir, speech: { url in
            throw Boom(description: url.lastPathComponent.hasPrefix("mic") ? "mic broke" : "mac broke")
        })
        #expect(report.transcriptError == "mic - A: mic broke; computer audio: mac broke")
        let long = try makeSession()
        let cut = try Finalizer.run(long, speech: { url in
            throw Boom(description: url.lastPathComponent + String(repeating: "x", count: 250))
        })
        let parts = try #require(cut.transcriptError).components(separatedBy: "; ")
        try #require(parts.count == 2)
        #expect(parts[0].hasPrefix("mic - A: mic - A.m4axxx") && parts[0].count == "mic - A: ".count + 100)
        #expect(parts[1].hasPrefix("computer audio: computer audio.m4axxx") && parts[1].count == "computer audio: ".count + 100)
    }

    @Test func oneFailingTrackKeepsTheTextOfTheOthers() throws {
        struct Boom: Error, CustomStringConvertible { var description: String { "decoder failed" } }
        let dir = try makeSession()
        let report = try Finalizer.run(dir, speech: { url in
            guard url.lastPathComponent.hasPrefix("mic") else { throw Boom() }
            return [SpokenWord(startMillis: 1_000, endMillis: 1_400, text: "Привет")]
        })
        #expect(report.transcriptError == "computer audio: decoder failed")
        let text = try String(contentsOf: dir.appendingPathComponent(Transcript.textFile), encoding: .utf8)
        #expect(text == "[00:00:01] Я: Привет\n")
    }

    private func marker(_ dir: URL) -> URL { dir.appendingPathComponent(Finalizer.transcribingMarker) }

    @Test func oneUnfinishedTranscriptionIsTriedAgain() throws {
        let dir = try makeSession()
        try "1".write(to: marker(dir), atomically: true, encoding: .utf8)
        let seen = Asked()
        let report = try Finalizer.run(dir, speech: { url in
            seen.names.append(try String(contentsOf: url.deletingLastPathComponent().appendingPathComponent(Finalizer.transcribingMarker), encoding: .utf8))
            return []
        })
        #expect(seen.names == ["2", "2"])
        #expect(report.transcriptError == nil)
        #expect(!FileManager.default.fileExists(atPath: marker(dir).path))
    }

    @Test func twoUnfinishedTranscriptionsAreNotAttemptedAgain() throws {
        let dir = try makeSession()
        try "2".write(to: marker(dir), atomically: true, encoding: .utf8)
        let asked = Asked()
        let report = try Finalizer.run(dir, speech: { url in
            asked.names.append(url.lastPathComponent)
            return []
        })
        #expect(asked.names.isEmpty)
        #expect(report.transcriptError == "not attempted: transcription did not finish twice")
        #expect(!FileManager.default.fileExists(atPath: marker(dir).path))
        let quiet = try makeSession()
        try "2".write(to: marker(quiet), atomically: true, encoding: .utf8)
        #expect(try Finalizer.run(quiet).transcriptError == nil)
        #expect(!FileManager.default.fileExists(atPath: marker(quiet).path))
    }

    @Test func aNegativeMarkerCountsAsNoUnfinishedAttempt() throws {
        let dir = try makeSession()
        try "-5".write(to: marker(dir), atomically: true, encoding: .utf8)
        let seen = Asked()
        try Finalizer.run(dir, speech: { url in
            seen.names.append(try String(contentsOf: url.deletingLastPathComponent().appendingPathComponent(Finalizer.transcribingMarker), encoding: .utf8))
            return []
        })
        #expect(seen.names == ["1", "1"])
    }

    @Test func theTranscribingMarkerCountsTheAttemptAndIsGoneAfterSuccessAndFailure() throws {
        struct Boom: Error {}
        let outcomes: [SpeechToText] = [{ _ in [] }, { _ in throw Boom() }]
        for speech in outcomes {
            let dir = try makeSession()
            let seen = Asked()
            try Finalizer.run(dir, speech: { url in
                let marker = url.deletingLastPathComponent().appendingPathComponent(Finalizer.transcribingMarker)
                seen.names.append((try? String(contentsOf: marker, encoding: .utf8)) ?? "none")
                return try speech(url)
            })
            #expect(seen.names == ["1", "1"])
            #expect(!FileManager.default.fileExists(atPath: marker(dir).path))
        }
    }

    @Test func withoutSpeechNothingIsTranscribed() throws {
        let dir = try makeSession()
        let report = try Finalizer.run(dir)
        #expect(report.transcriptError == nil)
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent(Transcript.textFile).path))
    }

    @Test func aBrokenSubtitleTrackIsDroppedAndTheVideoKept() async throws {
        let dir = try mixFolder().dir
        let frame = try slide(dir, atSeconds: 0, screen())
        var manifest = SessionManifest(appVersion: "t", startedAt: startedAt, sessionStartNanos: 1)
        manifest.frames = [FrameRecord(offsetNanos: frame.offsetNanos, file: frame.url.lastPathComponent)]
        let result = Finalizer.slideshow(manifest, dir: dir, chapters: [], subtitles: [
            SubtitleCue(startMillis: 1_000, endMillis: 2_000, text: "Я: Раз"),
            SubtitleCue(startMillis: 1_000, endMillis: 1_500, text: "Я: Два"),
        ])
        #expect(result.slides == nil)
        #expect(result.subtitles == "writing video failed: An unknown error occurred (-16364)")
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent(Finalizer.videoFile).path))
        #expect(try await AVURLAsset(url: dir.appendingPathComponent(Finalizer.videoFile)).loadTracks(withMediaType: .subtitle).isEmpty)
    }

    @Test func finalizerPutsSubtitlesIntoTheSlidesVideo() async throws {
        let dir = try makeSession()
        let frame = try slide(dir, atSeconds: 0, screen())
        var manifest = try SessionManifest.load(from: dir)
        manifest.frames = [FrameRecord(offsetNanos: 0, file: frame.url.lastPathComponent)]
        try manifest.save(to: dir)
        let report = try Finalizer.run(dir, speech: { _ in [SpokenWord(startMillis: 500, endMillis: 1_500, text: "Привет")] })
        #expect(report.slidesError == nil)
        #expect(report.subtitlesError == nil)
        #expect(try await AVURLAsset(url: dir.appendingPathComponent(Finalizer.videoFile)).loadTracks(withMediaType: .subtitle).count == 1)
    }

    @Test func aRunThatCannotTranscribeRemovesTheTranscriptOfAnEarlierRun() throws {
        struct Boom: Error {}
        let dir = try makeSession()
        let cafs = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasSuffix(".caf") }
        let keep = FileManager.default.temporaryDirectory.appendingPathComponent("cafs-\(UUID().uuidString)")
        try FileManager.default.copyItem(at: dir, to: keep)
        try Finalizer.run(dir, speech: { _ in [SpokenWord(startMillis: 500, endMillis: 1_500, text: "Привет")] })
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent(Transcript.textFile).path))
        for name in cafs { try FileManager.default.copyItem(at: keep.appendingPathComponent(name), to: dir.appendingPathComponent(name)) }
        let report = try Finalizer.run(dir, speech: { _ in throw Boom() })
        #expect(report.totalFrames == 144_000)
        #expect(report.transcriptError != nil)
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent(Transcript.textFile).path))
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent(Transcript.srtFile).path))
    }

    @Test func whenTheVideoFailsWithoutSubtitlesTooOnlyTheSlidesErrorIsReported() throws {
        let dir = try mixFolder().dir
        try Data([1, 2, 3]).write(to: dir.appendingPathComponent("broken.heic"))
        var manifest = SessionManifest(appVersion: "t", startedAt: startedAt, sessionStartNanos: 1)
        manifest.frames = [FrameRecord(offsetNanos: 0, file: "broken.heic")]
        let result = Finalizer.slideshow(manifest, dir: dir, chapters: [], subtitles: [
            SubtitleCue(startMillis: 1_000, endMillis: 2_000, text: "Я: Раз"),
        ])
        #expect(result.slides == "broken.heic: could not decode frame")
        #expect(result.subtitles == nil)
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent(Finalizer.videoFile).path))
    }

    @Test func onlyAFailureThatPointsAtTheSubtitlesIsTriedAgainWithoutThem() throws {
        let (dir, audio) = try mixFolder()
        let good = try slide(dir, atSeconds: 0, screen())
        let out = dir.appendingPathComponent(Finalizer.videoFile)
        func failure(_ slides: [Slide], _ cues: [SubtitleCue]) throws -> any Error {
            do {
                try SlideshowWriter.write(audio: audio, slides: slides, chapters: [], subtitles: cues, title: nil, to: out)
            } catch { return error }
            Issue.record("the write did not fail")
            return SlideshowError.noFrames
        }
        let overlap = [SubtitleCue(startMillis: 1_000, endMillis: 2_000, text: "Я: Раз"),
                       SubtitleCue(startMillis: 1_000, endMillis: 1_500, text: "Я: Два")]
        #expect(Finalizer.subtitlesMayBeAtFault(try failure([good], overlap)))
        try Data([1, 2, 3]).write(to: dir.appendingPathComponent("broken.heic"))
        let broken = Slide(offsetNanos: 500_000_000, url: dir.appendingPathComponent("broken.heic"))
        #expect(!Finalizer.subtitlesMayBeAtFault(try failure([good, broken], overlap)))
        let other = NSError(domain: AVFoundationErrorDomain, code: -11800, userInfo: [
            NSUnderlyingErrorKey: NSError(domain: NSOSStatusErrorDomain, code: -12345),
        ])
        #expect(!Finalizer.subtitlesMayBeAtFault(SlideshowError.write(other)))
        #expect(!Finalizer.subtitlesMayBeAtFault(SlideshowError.write(nil)))
    }

    @Test func briefPrefersTheReadableDescriptionAndCutsItShort() {
        struct Described: LocalizedError { var errorDescription: String? { "described" } }
        struct Plain: Error, CustomStringConvertible { var description: String { "plain" } }
        struct Long: Error, CustomStringConvertible { var description: String { String(repeating: "x", count: 300) } }
        #expect(Finalizer.brief(Described()) == "described")
        #expect(Finalizer.brief(NSError(domain: "d", code: 1, userInfo: [NSLocalizedDescriptionKey: "from NSError"])) == "from NSError")
        #expect(Finalizer.brief(Plain()) == "plain")
        #expect(Finalizer.brief(Long()) == String(repeating: "x", count: 200))
    }

    @Test func writerErrorsReadAsTheReasonAndTheUnderlyingStatus() {
        struct Plain: Error, CustomStringConvertible { var description: String { "plain" } }
        let status = NSError(domain: NSOSStatusErrorDomain, code: -12345)
        let reason = NSError(domain: AVFoundationErrorDomain, code: -11800, userInfo: [
            NSLocalizedDescriptionKey: "The operation could not be completed",
            NSLocalizedFailureReasonErrorKey: "An unknown error occurred (-12345)", NSUnderlyingErrorKey: status,
        ])
        let bare = NSError(domain: AVFoundationErrorDomain, code: -11800, userInfo: [
            NSLocalizedDescriptionKey: "The operation could not be completed", NSUnderlyingErrorKey: status,
        ])
        #expect(WriterFailure.text(reason) == "An unknown error occurred (-12345)")
        #expect(WriterFailure.text(bare) == "The operation could not be completed (-12345)")
        #expect(WriterFailure.text(Plain()) == "plain")
        #expect(SlideshowError.write(bare).description == "writing video failed: The operation could not be completed (-12345)")
        #expect(SlideshowError.write(nil).description == "writing video failed: no reason given")
    }

    @Test func launchRecoveryTranscribesTheSessionsItRecovers() throws {
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("work-\(UUID().uuidString)")
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("out-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: try makeSession(), to: work.appendingPathComponent("crashed"))
        let failure = Delivery.recover(
            Finalizer.sessionFolders(root: work), work: work, output: out,
            speech: { _ in [SpokenWord(startMillis: 500, endMillis: 1_500, text: "Привет")] })
        #expect(failure == nil)
        let name = SessionNaming.sessionName(startedAt, title: "")
        #expect(FileManager.default.fileExists(atPath: out.appendingPathComponent(name).appendingPathComponent(Transcript.textFile).path))
    }

    @Test func aTrackThatNeverConnectedIsNotTranscribed() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("fin-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let s: UInt64 = 10_000_000_000
        var m = SessionManifest(appVersion: "t", startedAt: Date(), sessionStartNanos: s)
        m.sources = [
            SourceManifest(kind: .computer, uid: nil, name: "Computer audio", file: "computer audio.m4a", channels: 2, segments: [
                SegmentRecord(file: "computer audio.seg000.caf", startNanos: s, frames: 96_000, endNanos: s + 2_000_000_000, sourceRate: 48_000, sourceChannels: 2, reason: "start"),
            ], restarts: [], overruns: 0),
            SourceManifest(kind: .mic, uid: "ap", name: "AirPods", file: "mic - AirPods.m4a", channels: 1, segments: [], restarts: [], overruns: 0),
        ]
        try m.save(to: dir)
        try writeCAF(dir.appendingPathComponent("computer audio.seg000.caf"), samples: sine(frames: 96_000, channels: 2, amplitude: 0.25), channels: 2)
        let asked = Asked()
        try Finalizer.run(dir, speech: { url in
            asked.names.append(url.lastPathComponent)
            return []
        })
        #expect(asked.names == ["computer audio.m4a"])
    }
}

extension FinalizerTests {
    @Test func cleanMicsRemovesTheEchoOfMacAudioFromTheMicTrack() throws {
        let dir = try echoSession()
        let report = try Finalizer.run(dir, cleanMics: true)
        #expect(report.cleanedMics == ["mic - A"])
        #expect(report.micCleaner == "MicCleaner")
        #expect(report.echoDelayMillis?["mic - A"] == 10)
        #expect(try AVAudioFile(forReading: dir.appendingPathComponent("mic - A.m4a")).length == AVAudioFramePosition(5 * 48_000))
        // The echo was at about 0.087 RMS.
        #expect(try rms(dir.appendingPathComponent("mic - A.m4a"), from: 3 * 48_000, frames: 48_000) < 0.01)
        #expect(try rms(dir.appendingPathComponent("computer audio.m4a"), from: 3 * 48_000, frames: 48_000) > 0.1)
    }

    @Test func cleanMicsUsesTheModelWhenItIsReady() throws {
        let dir = try echoSession()
        let report = try Finalizer.run(dir, cleanMics: true, micModel: { SilentModel() })
        #expect(report.micCleaner == "LocalVQE")
        #expect(report.micCleanerError == nil)
        #expect(try AVAudioFile(forReading: dir.appendingPathComponent("mic - A.m4a")).length == AVAudioFramePosition(5 * 48_000))
        #expect(try rms(dir.appendingPathComponent("mic - A.m4a"), from: 3 * 48_000, frames: 48_000) < 0.001)
    }

    @Test func cleanMicsFallsBackToMicCleanerWhenTheModelIsNotReady() throws {
        let dir = try echoSession()
        let report = try Finalizer.run(dir, cleanMics: true, micModel: { throw NotReady() })
        #expect(report.micCleaner == "MicCleaner (LocalVQE: not ready)")
        #expect(try rms(dir.appendingPathComponent("mic - A.m4a"), from: 3 * 48_000, frames: 48_000) < 0.01)
    }

    /// Five seconds: the mic hears Mac audio 10 ms late at half the level, and nothing else.
    private func echoSession() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("fin-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let s: UInt64 = 10_000_000_000
        let frames = 5 * 48_000
        var m = SessionManifest(appVersion: "t", startedAt: startedAt, sessionStartNanos: s)
        m.sources = [
            SourceManifest(kind: .mic, uid: "u", name: "A", file: "mic - A.m4a", channels: 1, segments: [
                SegmentRecord(file: "mic - A.seg000.caf", startNanos: s, frames: frames, endNanos: s + 5_000_000_000, sourceRate: 48_000, sourceChannels: 1, reason: "start"),
            ], restarts: [], overruns: 0),
            SourceManifest(kind: .computer, uid: nil, name: "Computer audio", file: "computer audio.m4a", channels: 2, segments: [
                SegmentRecord(file: "computer audio.seg000.caf", startNanos: s, frames: frames, endNanos: s + 5_000_000_000, sourceRate: 48_000, sourceChannels: 2, reason: "start"),
            ], restarts: [], overruns: 0),
        ]
        try m.save(to: dir)
        var x: UInt64 = 1
        let mac = (0..<frames).map { _ -> Float in
            x = x &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Float(Double(x >> 40) / Double(1 << 24) * 2 - 1) * 0.3
        }
        let mic = (0..<frames).map { $0 >= 480 ? 0.5 * mac[$0 - 480] : 0 }
        try writeCAF(dir.appendingPathComponent("mic - A.seg000.caf"), samples: mic, channels: 1)
        try writeCAF(dir.appendingPathComponent("computer audio.seg000.caf"), samples: mac.flatMap { [$0, $0] }, channels: 2)
        return dir
    }
}

/// A model that removes everything.
private final class SilentModel: MicModelStream {
    let buffering = 0
    func enhance(mic: [Float], reference: [Float]) throws -> [Float] { [Float](repeating: 0, count: mic.count) }
}

private struct NotReady: Error, CustomStringConvertible {
    var description: String { "not ready" }
}
