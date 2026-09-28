import Foundation
import Testing
@testable import DabberCore

@Test func manifestRoundTripsThroughJSON() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("m-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    var m = SessionManifest(appVersion: "0.1.0", startedAt: Date(timeIntervalSince1970: 1_000), sessionStartNanos: 42)
    m.sources = [
        SourceManifest(
            kind: .mic, uid: "u", name: "AirPods", file: "mic - AirPods.m4a", channels: 1,
            segments: [SegmentRecord(file: "mic - AirPods.seg000.caf", startNanos: 50, frames: 480, endNanos: 60,
                                     sourceRate: 24_000, sourceChannels: 1, reason: "start")],
            restarts: [RestartEvent(atNanos: 55, reason: "nsrt")], overruns: 2),
    ]
    try m.save(to: dir)
    let text = try String(contentsOf: dir.appendingPathComponent("session.json"), encoding: .utf8)
    #expect(text.contains("\"reason\" : \"nsrt\""))
    #expect(try SessionManifest.load(from: dir) == m)
}

@Test func sessionNameIsSortableLocalTimeThenTitle() {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: "Europe/Moscow")!
    let date = cal.date(from: DateComponents(year: 2026, month: 9, day: 23, hour: 5, minute: 53, second: 11))!
    #expect(SessionNaming.sessionName(date, title: "", timeZone: cal.timeZone) == "2026-09-23 05-53")
    #expect(SessionNaming.sessionName(date, title: " Планёрка: Q3/план ", timeZone: cal.timeZone) == "2026-09-23 05-53 Планёрка- Q3-план")
    #expect(SessionNaming.sessionName(date, title: " .. ", timeZone: cal.timeZone) == "2026-09-23 05-53")
}

@Test func titlesAreSanitizedForFileNames() {
    #expect(SessionNaming.sanitize("a/b:c") == "a-b-c")
    #expect(SessionNaming.sanitize("..hidden") == "hidden")
    #expect(SessionNaming.sanitize(" . .x.") == "x.")
    #expect(SessionNaming.sanitize("a\u{0}b\tc\nd\u{7F}") == "abcd")
    #expect(SessionNaming.sanitize("  Созвон с командой \n") == "Созвон с командой")
    #expect(SessionNaming.sanitize("👨‍👩‍👧 sync") == "👨‍👩‍👧 sync")
    #expect(SessionNaming.sanitize(String(repeating: "я", count: 100)) == String(repeating: "я", count: 80))
    #expect(SessionNaming.sanitize(String(repeating: "a", count: 79) + " b") == String(repeating: "a", count: 79))
}

@Test func trackNamesFollowTheSpec() {
    #expect(SessionNaming.trackBase(kind: .computer, name: "x", taken: []) == "computer audio")
    #expect(SessionNaming.trackBase(kind: .mic, name: "Alex’s AirPods", taken: []) == "mic - Alex’s AirPods")
    #expect(SessionNaming.trackBase(kind: .mic, name: "USB: In/Out", taken: []) == "mic - USB- In-Out")
    #expect(SessionNaming.trackBase(kind: .mic, name: "A", taken: ["mic - A"]) == "mic - A 2")
    #expect(SessionNaming.segmentFile(base: "mic - A", index: 7) == "mic - A.seg007.caf")
}

@Test func diskCheckNeedsTwoGigabytes() throws {
    #expect(DiskCheck.hasRoom(freeBytes: 2_000_000_000))
    #expect(!DiskCheck.hasRoom(freeBytes: 1_999_999_999))
    #expect(try DiskCheck.freeBytes(at: URL(fileURLWithPath: NSHomeDirectory())) > 0)
}

@Test func manifestKeepsTheRawTitleAndOldManifestsHaveNone() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("m-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    var m = SessionManifest(appVersion: "t", startedAt: Date(timeIntervalSince1970: 1_800_000_000), sessionStartNanos: 1)
    m.title = " Планёрка: Q3 "
    try m.save(to: dir)
    #expect(try SessionManifest.load(from: dir) == m)
    #expect(m.name == SessionNaming.sessionName(m.startedAt, title: " Планёрка: Q3 "))
    #expect(m.name.hasSuffix(" Планёрка- Q3"))
    let old = #"{"appVersion":"0.1","startedAt":"2026-09-23T10:00:00Z","sessionStartNanos":5,"sources":[]}"#
    try Data(old.utf8).write(to: dir.appendingPathComponent(SessionManifest.fileName))
    #expect(try SessionManifest.load(from: dir).title == "")
}

@Test func stereoIsEncodedAt256kAndTheDiskEstimateUsesIt() {
    #expect(AACWriter.bitRate(channels: 1) == 96_000)
    #expect(AACWriter.bitRate(channels: 2) == 256_000)
    #expect(DiskCheck.secondsLeft(freeBytes: 652_000_000, channels: [2, 1], elapsedSeconds: 0) == 1_000)
    #expect(DiskCheck.secondsLeft(freeBytes: 784_000_000, channels: [2, 1], elapsedSeconds: 0, slides: true) == 1_000)
}

@Test func framesAreNamedByOffsetAndOldManifestsHaveNone() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("m-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    var m = SessionManifest(appVersion: "t", startedAt: Date(timeIntervalSince1970: 1_800_000_000), sessionStartNanos: 5_000)
    #expect(m.addFrame(atNanos: 2_000_005_000) == FrameRecord(offsetNanos: 2_000_000_000, file: "frames/2000000000.heic"))
    #expect(m.addFrame(atNanos: 10) == FrameRecord(offsetNanos: 0, file: "frames/0.heic"))
    m.finalize = FinalizeReport(totalFrames: 1, gaps: [], driftMillis: [:], resampled: [], slidesError: "boom")
    try m.save(to: dir)
    #expect(try SessionManifest.load(from: dir) == m)
    let old = #"{"appVersion":"t","startedAt":"2027-01-15T08:00:00Z","sessionStartNanos":1,"sources":[],"finalize":{"totalFrames":1,"gaps":[],"driftMillis":{},"resampled":[]}}"#
    try Data(old.utf8).write(to: dir.appendingPathComponent("session.json"))
    let loaded = try SessionManifest.load(from: dir)
    #expect(loaded.frames.isEmpty)
    #expect(loaded.finalize?.slidesError == nil)
}
