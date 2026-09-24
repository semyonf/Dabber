import Foundation
import Testing
@testable import DabberCore

private func manifest() -> SessionManifest {
    SessionManifest(appVersion: "t", startedAt: Date(timeIntervalSince1970: 1_000), sessionStartNanos: 10_000_000_000)
}

@Test func marksAreTakenOnTheSessionTimeline() {
    var m = manifest()
    let first = m.addMark(atNanos: 12_500_000_000)
    let second = m.addMark(atNanos: 9_000_000_000)
    #expect(first == Mark(id: 1, offsetNanos: 2_500_000_000))
    #expect(second == Mark(id: 2, offsetNanos: 0))
    #expect(m.marks == [first, second])
}

@Test func markTextIsTrimmedAndMarksAreRemovable() {
    var m = manifest()
    m.addMark(atNanos: 11_000_000_000)
    m.addMark(atNanos: 12_000_000_000)
    m.setMarkText(id: 1, "  про деньги \n")
    m.setMarkText(id: 9, "nobody")
    m.removeMark(id: 2)
    #expect(m.marks == [Mark(id: 1, offsetNanos: 1_000_000_000, text: "про деньги")])
    #expect(m.addMark(atNanos: 13_000_000_000).id == 2)
}

@Test func manifestWithMarksRoundTripsAndOldManifestsHaveNone() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mk-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    var m = manifest()
    m.addMark(atNanos: 11_000_000_000)
    m.setMarkText(id: 1, "про деньги")
    try m.save(to: dir)
    #expect(try SessionManifest.load(from: dir) == m)
    let old = #"{"appVersion":"0.1","startedAt":"2026-09-23T10:00:00Z","sessionStartNanos":5,"sources":[]}"#
    try Data(old.utf8).write(to: dir.appendingPathComponent(SessionManifest.fileName))
    let loaded = try SessionManifest.load(from: dir)
    #expect(loaded.marks.isEmpty)
    #expect(loaded.finalize == nil)
}

@Test func chaptersStartWithStartThenMarksInTimeOrder() {
    let marks = [
        Mark(id: 1, offsetNanos: 20_000_000_000, text: "про деньги"),
        Mark(id: 2, offsetNanos: 10_000_000_000),
        Mark(id: 3, offsetNanos: 99_000_000_000),
    ]
    #expect(Chapters.make(marks, durationMillis: 30_000) == [
        Chapter(startMillis: 0, title: "Start"),
        Chapter(startMillis: 10_000, title: "Mark 2"),
        Chapter(startMillis: 20_000, title: "про деньги"),
        Chapter(startMillis: 29_999, title: "Mark 3"),
    ])
}

@Test func markAtZeroReplacesStartAndSameTimeKeepsTheLaterMark() {
    let marks = [Mark(id: 1, offsetNanos: 0, text: "go"), Mark(id: 2, offsetNanos: 5_000_000_000), Mark(id: 3, offsetNanos: 5_000_400_000)]
    #expect(Chapters.make(marks, durationMillis: 10_000) == [
        Chapter(startMillis: 0, title: "go"),
        Chapter(startMillis: 5_000, title: "Mark 3"),
    ])
}

@Test func marksTextListsEveryMarkWithHoursMinutesSeconds() {
    let marks = [Mark(id: 1, offsetNanos: 3_723_900_000_000, text: "про деньги"), Mark(id: 2, offsetNanos: 5_000_000_000)]
    #expect(Chapters.text(marks, durationMillis: 4_000_000) == "00:00:05  Mark 2\n01:02:03  про деньги\n")
}
