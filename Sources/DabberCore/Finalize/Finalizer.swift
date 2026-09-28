import Foundation
import Synchronization

public enum Finalizer {
    public static let chunkFrames = 48_000
    public static let mixFile = "mix.m4a"
    public static let videoFile = "mix.mp4"

    private struct Track {
        let base: String
        let channels: Int
        let reader: TimelineReader
        let plans: [FinalizePlan]
    }

    @discardableResult
    public static func run(_ dir: URL) throws -> FinalizeReport {
        var manifest = try SessionManifest.load(from: dir)
        var tracks: [Track] = []
        var rendered: [String] = []
        for source in manifest.sources {
            var present: [SegmentRecord] = []
            var files: [CAFSegment] = []
            for record in source.segments {
                let url = dir.appendingPathComponent(record.file)
                guard FileManager.default.fileExists(atPath: url.path) else { continue }
                present.append(record)
                files.append(try CAFSegment(url: url))
            }
            let plans = FinalizePlan.make(present, fileFrames: files.map(\.frames))
            let planned = Set(plans.map(\.file))
            rendered += plans.map(\.file)
            let sources: [any SegmentSource] = zip(present, files).compactMap { record, caf in
                guard planned.contains(record.file) else { return nil }
                let plan = plans.first { $0.file == record.file }!
                return plan.resample ? DriftResampler(caf, targetFrames: plan.segment.frames) : caf
            }
            let placements = Timeline.place(plans.map(\.segment), sessionStartNanos: manifest.sessionStartNanos)
            tracks.append(Track(
                base: source.trackBase, channels: source.channels,
                reader: TimelineReader(placements: placements, sources: sources, channels: source.channels),
                plans: plans))
        }
        let total = tracks.map(\.reader.totalFrames).max() ?? 0
        var slidesError: String?
        let writers = try tracks.map { try AACWriter(url: dir.appendingPathComponent($0.base + ".m4a"), channels: $0.channels) }
        let mix = try AACWriter(url: dir.appendingPathComponent(mixFile), channels: 2)
        var start = 0
        while start < total {
            let range = start..<min(start + chunkFrames, total)
            let pcms = try tracks.map { try $0.reader.read(range) }
            let contributing = zip(tracks, pcms).filter { !$0.0.reader.placements.isEmpty }
            let mono = contributing.filter { $0.0.channels == 1 }.map(\.1)
            let stereo = contributing.filter { $0.0.channels != 1 }.map(\.1)
            try encodeConcurrently(writers + [mix], pcms + [Mixer.mixToStereo(mono: mono, stereo: stereo)])
            start = range.upperBound
        }
        for writer in writers { try writer.closeAndVerify() }
        try mix.closeAndVerify()
        if total > 0 {
            let millis = total * 1000 / Timeline.rate
            var chapters: [Chapter] = []
            if !manifest.marks.isEmpty {
                try Chapters.text(manifest.marks, durationMillis: millis)
                    .write(to: dir.appendingPathComponent(Chapters.textFile), atomically: true, encoding: .utf8)
                chapters = Chapters.make(manifest.marks, durationMillis: millis)
                for writer in writers { try ChapterWriter.write(chapters, into: writer.url) }
            }
            try ChapterWriter.write(chapters, title: manifest.name, into: mix.url)
            slidesError = slideshow(manifest, dir: dir, chapters: chapters)
        }
        var gaps: [GapRecord] = []
        var drift: [String: Double] = [:]
        var resampled: [String] = []
        for track in tracks {
            gaps += Timeline.gaps(track.reader.placements).map { GapRecord(track: track.base, atFrame: $0.atFrame, frames: $0.frames) }
            for plan in track.plans {
                drift[plan.file] = plan.driftMillis
                if plan.resample { resampled.append(plan.file) }
            }
        }
        let report = FinalizeReport(
            totalFrames: total, gaps: gaps, driftMillis: drift, resampled: resampled, slidesError: slidesError)
        manifest.finalize = report
        try manifest.save(to: dir)
        for name in rendered {
            try FileManager.default.removeItem(at: dir.appendingPathComponent(name))
        }
        if slidesError == nil {
            try? FileManager.default.removeItem(at: dir.appendingPathComponent(SessionManifest.framesDir))
        }
        return report
    }

    private static func slideshow(_ manifest: SessionManifest, dir: URL, chapters: [Chapter]) -> String? {
        let slides = manifest.frames
            .map { Slide(offsetNanos: $0.offsetNanos, url: dir.appendingPathComponent($0.file)) }
            .filter { FileManager.default.fileExists(atPath: $0.url.path) }
        guard !slides.isEmpty else { return nil }
        let out = dir.appendingPathComponent(videoFile)
        do {
            try SlideshowWriter.write(
                audio: dir.appendingPathComponent(mixFile), slides: slides, chapters: chapters, title: manifest.name, to: out)
            return nil
        } catch {
            try? FileManager.default.removeItem(at: out)
            return "\(error)"
        }
    }

    public static func finish(_ dir: URL) throws -> URL {
        try run(dir)
        return try rename(dir)
    }

    public static func rename(_ dir: URL) throws -> URL {
        let name = try SessionManifest.load(from: dir).name
        try FileManager.default.moveItem(at: dir.appendingPathComponent(mixFile), to: dir.appendingPathComponent(name + ".m4a"))
        let video = dir.appendingPathComponent(videoFile)
        if FileManager.default.fileExists(atPath: video.path) {
            try FileManager.default.moveItem(at: video, to: dir.appendingPathComponent(name + ".mp4"))
        }
        let parent = dir.deletingLastPathComponent()
        var n = 1
        while true {
            let candidate = n == 1 ? name : "\(name) \(n)"
            if candidate == dir.lastPathComponent { return dir }
            let target = parent.appendingPathComponent(candidate)
            do {
                try FileManager.default.moveItem(at: dir, to: target)
                return target
            } catch CocoaError.fileWriteFileExists {
                n += 1
            }
        }
    }

    private static func encodeConcurrently(_ writers: [AACWriter], _ chunks: [[Float]]) throws {
        let errors = Mutex<[any Error]>([])
        DispatchQueue.concurrentPerform(iterations: writers.count) { i in
            do {
                try writers[i].write(chunks[i])
            } catch {
                errors.withLock { $0.append(error) }
            }
        }
        if let error = errors.withLock({ $0.first }) { throw error }
    }

    public static func needsRecovery(_ dir: URL) -> Bool {
        let fm = FileManager.default
        guard let manifest = try? SessionManifest.load(from: dir), manifest.finalize == nil,
              let names = try? fm.contentsOfDirectory(atPath: dir.path)
        else { return false }
        return names.contains { $0.hasSuffix(".caf") }
    }

    public static func sessionFolders(root: URL) -> [URL] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        return names.sorted().map { root.appendingPathComponent($0) }
    }

    @discardableResult
    public static func recoverAll(dirs: [URL], onError: (URL, Error) -> Void = { _, _ in }) -> [URL] {
        var done: [URL] = []
        for dir in dirs where needsRecovery(dir) {
            do {
                done.append(try finish(dir))
            } catch {
                onError(dir, error)
            }
        }
        return done
    }
}
