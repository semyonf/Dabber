import Foundation
import Testing
@testable import DabberCore

private final class FakeSource: CaptureSource, @unchecked Sendable {
    nonisolated(unsafe) static var started: [String] = []
    nonisolated(unsafe) static var stopped: [String] = []
    nonisolated(unsafe) static var failStart = false

    override func start() throws {
        if Self.failStart { throw SourceError.deviceMissing(spec.uid ?? "") }
        Self.started.append(writer.baseName)
    }

    override func stop() {
        Self.stopped.append(writer.baseName)
        writer.stop()
    }
}

private func recorder(free: Int64 = 3_000_000_000) throws -> (SessionRecorder, URL) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("sr-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    FakeSource.started = []
    FakeSource.stopped = []
    FakeSource.failStart = false
    let r = SessionRecorder(
        root: root, appVersion: "t",
        makeSource: { spec, dir, base in FakeSource(spec: spec, dir: dir, baseName: base, channels: spec.kind == .mic ? 1 : 2) },
        freeBytes: { _ in free })
    return (r, root)
}

private final class FreeBytes: @unchecked Sendable {
    var value: Int64
    init(_ value: Int64) { self.value = value }
}

private let specs = [
    SourceSpec(kind: .computer, uid: nil, name: "Computer audio"),
    SourceSpec(kind: .mic, uid: "u1", name: "AirPods"),
]

@Suite(.serialized) struct SessionRecorderTests {
    @Test func startCreatesFolderAndManifestThenStopFinalizesManifest() throws {
        let (r, root) = try recorder()
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let dir = try r.start(specs: specs, at: date)
        #expect(dir.lastPathComponent == SessionNaming.sessionName(date, title: ""))
        #expect(dir.deletingLastPathComponent().path == root.path)
        #expect(FakeSource.started == ["computer audio", "mic - AirPods"])
        let m = try SessionManifest.load(from: dir)
        #expect(m.sources.map(\.file) == ["computer audio.m4a", "mic - AirPods.m4a"])
        #expect(m.sources.map(\.channels) == [2, 1])
        #expect(r.status(at: date.addingTimeInterval(5)).phase == .recording)
        #expect(r.status(at: date.addingTimeInterval(5)).elapsedSeconds == 5)
        #expect(r.stop() == dir)
        #expect(FakeSource.stopped == ["computer audio", "mic - AirPods"])
        #expect(r.status(at: date).phase == .idle)
        #expect(r.lastSessionDir == dir)
    }

    @Test func startIsRefusedWhileRecordingAndWhenDiskIsLow() throws {
        let (r, _) = try recorder()
        _ = try r.start(specs: specs)
        #expect(throws: RecorderError.self) { try r.start(specs: specs) }
        _ = r.stop()
        let (low, _) = try recorder(free: 1)
        #expect(throws: RecorderError.self) { try low.start(specs: specs) }
    }

    @Test func failingSourceStartRollsBack() throws {
        let (r, root) = try recorder()
        FakeSource.failStart = true
        #expect(throws: SourceError.self) { try r.start(specs: specs) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
        #expect(r.status(at: Date()).phase == .idle)
    }

    @Test func startsInTheSameSecondNeverTouchTheEarlierSession() throws {
        let (r, root) = try recorder()
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let first = try r.start(specs: specs, at: date)
        _ = r.stop()
        let marker = first.appendingPathComponent("mix.m4a")
        try Data("done".utf8).write(to: marker)
        let firstManifest = try Data(contentsOf: first.appendingPathComponent("session.json"))
        let second = try r.start(specs: [specs[0]], at: date.addingTimeInterval(0.5))
        _ = r.stop()
        #expect(second.lastPathComponent == SessionNaming.sessionName(date, title: "") + " 2")
        #expect(try Data(contentsOf: first.appendingPathComponent("session.json")) == firstManifest)
        FakeSource.failStart = true
        #expect(throws: SourceError.self) { try r.start(specs: specs, at: date) }
        #expect(FileManager.default.fileExists(atPath: marker.path))
        #expect(try Data(contentsOf: first.appendingPathComponent("session.json")) == firstManifest)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).sorted() == [first.lastPathComponent, second.lastPathComponent])
    }

    @Test func lowDiskDuringRecordingWarnsThenStopsCleanly() throws {
        let (r, _) = try recorder()
        let free = FreeBytes(3_000_000_000)
        let low = SessionRecorder(
            root: r.root, appVersion: "t",
            makeSource: { spec, dir, base in FakeSource(spec: spec, dir: dir, baseName: base, channels: spec.kind == .mic ? 1 : 2) },
            freeBytes: { _ in free.value })
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let dir = try low.start(specs: specs, at: date)
        #expect(low.status(at: date.addingTimeInterval(1)).diskWarning == nil)
        free.value = 720_000_000
        #expect(low.status(at: date.addingTimeInterval(20)).diskWarning == nil)
        let warned = low.status(at: date.addingTimeInterval(61))
        #expect(warned.phase == .recording)
        #expect(warned.diskWarning == "disk space low: about 18 min of recording left")
        #expect(low.status(at: date.addingTimeInterval(62)).diskWarning == warned.diskWarning)
        free.value = 70_000_000
        _ = low.status(at: date.addingTimeInterval(91))
        let deadline = Date().addingTimeInterval(5)
        while low.status(at: date.addingTimeInterval(92)).phase != .idle, Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
        let stopped = low.status(at: date.addingTimeInterval(93))
        #expect(stopped.phase == .idle)
        #expect(stopped.lastError == "disk almost full (70 MB free)")
        #expect(low.lastSessionDir == dir)
        #expect(FakeSource.stopped == ["computer audio", "mic - AirPods"])
        #expect(try SessionManifest.load(from: dir).sources.count == 2)
    }

    @Test func marksAreSavedToTheManifestAtOnce() throws {
        let (r, _) = try recorder()
        let dir = try r.start(specs: specs)
        let start = try SessionManifest.load(from: dir).sessionStartNanos
        #expect(r.addMark(atNanos: start + 2_000_000_000) == [Mark(id: 1, offsetNanos: 2_000_000_000)])
        #expect(try SessionManifest.load(from: dir).marks == [Mark(id: 1, offsetNanos: 2_000_000_000)])
        r.addMark(atNanos: start + 3_000_000_000)
        r.setMarkText(id: 1, "про деньги")
        #expect(r.removeMark(id: 2) == [Mark(id: 1, offsetNanos: 2_000_000_000, text: "про деньги")])
        #expect(try SessionManifest.load(from: dir).marks == [Mark(id: 1, offsetNanos: 2_000_000_000, text: "про деньги")])
        _ = r.stop()
        #expect(try SessionManifest.load(from: dir).marks == [Mark(id: 1, offsetNanos: 2_000_000_000, text: "про деньги")])
        #expect(r.addMark(atNanos: start + 4_000_000_000).isEmpty)
        #expect(try SessionManifest.load(from: dir).marks.count == 1)
    }

    @Test func titleNamesTheFolderAndEditsAreSavedAtOnce() throws {
        let (r, root) = try recorder()
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let dir = try r.start(specs: specs, title: "Standup: team", at: date)
        #expect(dir.lastPathComponent == SessionNaming.sessionName(date, title: "Standup: team"))
        #expect(dir.deletingLastPathComponent().path == root.path)
        #expect(try SessionManifest.load(from: dir).title == "Standup: team")
        r.setTitle("Планёрка ")
        #expect(try SessionManifest.load(from: dir).title == "Планёрка ")
        _ = r.stop()
        r.setTitle("late")
        #expect(try SessionManifest.load(from: dir).title == "Планёрка ")
    }

    @Test func framesAreWrittenAndSavedToTheManifestAtOnce() throws {
        let (r, _) = try recorder()
        let dir = try r.start(specs: specs, slides: true)
        let start = try SessionManifest.load(from: dir).sessionStartNanos
        #expect(try r.addFrame(atNanos: start + 2_000_000_000, data: Data([1, 2, 3])))
        #expect(try SessionManifest.load(from: dir).frames == [FrameRecord(offsetNanos: 2_000_000_000, file: "frames/2000000000.heic")])
        #expect(try Data(contentsOf: dir.appendingPathComponent("frames/2000000000.heic")) == Data([1, 2, 3]))
        _ = r.stop()
        #expect(try !r.addFrame(atNanos: start + 4_000_000_000, data: Data([4])))
        #expect(try SessionManifest.load(from: dir).frames.count == 1)
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("frames/4000000000.heic").path))
    }

    @Test func stopWithoutStartReturnsNil() throws {
        let (r, _) = try recorder()
        #expect(r.stop() == nil)
    }
}
