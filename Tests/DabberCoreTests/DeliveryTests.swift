import Foundation
import Testing
@testable import DabberCore

private let startedAt = Date(timeIntervalSince1970: 1_800_000_000)
private let name = SessionNaming.sessionName(startedAt, title: "Sync")
private let audio = Data(repeating: 7, count: 1_000)

private func temp(_ tag: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(tag)-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@discardableResult
private func session(in root: URL, folder: String, title: String = "Sync", finished: Bool = true) throws -> URL {
    let dir = root.appendingPathComponent(folder)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false)
    var m = SessionManifest(appVersion: "t", startedAt: startedAt, sessionStartNanos: 1)
    m.title = title
    if finished { m.finalize = FinalizeReport(totalFrames: 0, gaps: [], driftMillis: [:], resampled: []) }
    try m.save(to: dir)
    let file = finished ? SessionNaming.sessionName(startedAt, title: title) + ".m4a" : "computer audio.seg000.caf"
    try audio.write(to: dir.appendingPathComponent(file))
    return dir
}

private func names(_ dir: URL) throws -> [String] {
    try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()
}

@Test func finishedSessionMovesIntoTheOutputFolderUnderItsName() throws {
    let work = try temp("work"), out = try temp("out")
    let moved = try Delivery.deliver(try session(in: work, folder: name + " 2"), into: out)
    #expect(moved.path == out.appendingPathComponent(name).path)
    #expect(try names(moved) == [name + ".m4a", "session.json"])
    #expect(try names(work).isEmpty)
}

@Test func takenNamesInTheOutputFolderGetANumber() throws {
    let work = try temp("work"), out = try temp("out")
    try FileManager.default.createDirectory(at: out.appendingPathComponent(name), withIntermediateDirectories: false)
    try Data([1]).write(to: out.appendingPathComponent(name + " 2"))
    let moved = try Delivery.deliver(try session(in: work, folder: name), into: out)
    #expect(moved.lastPathComponent == name + " 3")
    #expect(try names(moved) == [name + ".m4a", "session.json"])
}

@Test func missingOutputFolderLeavesTheSessionInPlace() throws {
    let work = try temp("work")
    let out = work.deletingLastPathComponent().appendingPathComponent("gone-\(UUID().uuidString)")
    let dir = try session(in: work, folder: name)
    #expect(throws: DeliveryError.folderMissing(out.path)) { try Delivery.deliver(dir, into: out) }
    #expect(DeliveryError.folderMissing(out.path).localizedDescription == "folder not found: \(out.path)")
    #expect(try names(dir) == [name + ".m4a", "session.json"])
    #expect(!FileManager.default.fileExists(atPath: out.path))
}

@Test func unwritableOutputFolderLeavesTheSessionInPlace() throws {
    let work = try temp("work"), out = try temp("out")
    try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: out.path)
    defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: out.path) }
    let dir = try session(in: work, folder: name)
    #expect(throws: CocoaError.self) { try Delivery.deliver(dir, into: out) }
    #expect(try names(dir) == [name + ".m4a", "session.json"])
    #expect(try names(out).isEmpty)
}

private let otherVolume = Mover(move: { _, _ in throw DeliveryError.otherVolume }, copy: Mover.live.copy)

@Test func acrossVolumesTheSessionIsCopiedCheckedThenRemoved() throws {
    let work = try temp("work"), out = try temp("out")
    try FileManager.default.createDirectory(at: out.appendingPathComponent(name), withIntermediateDirectories: false)
    let moved = try Delivery.deliver(try session(in: work, folder: name), into: out, mover: otherVolume)
    #expect(moved.lastPathComponent == name + " 2")
    #expect(try names(moved) == [name + ".m4a", "session.json"])
    #expect(try Data(contentsOf: moved.appendingPathComponent(name + ".m4a")) == audio)
    #expect(try names(out) == [name, name + " 2"])
    #expect(try names(work).isEmpty)
}

@Test func aCopyThatDoesNotMatchKeepsTheWorkFilesAndLeavesNothingBehind() throws {
    let work = try temp("work"), out = try temp("out")
    let dir = try session(in: work, folder: name)
    let short = Mover(move: otherVolume.move) { from, to in
        try FileManager.default.copyItem(at: from, to: to)
        try Data([7]).write(to: to.appendingPathComponent(name + ".m4a"))
    }
    let partial = Mover(move: otherVolume.move) { from, to in
        try FileManager.default.copyItem(at: from, to: to)
        try FileManager.default.removeItem(at: to.appendingPathComponent("session.json"))
    }
    for mover in [short, partial] {
        #expect(throws: DeliveryError.copyMismatch(name)) { try Delivery.deliver(dir, into: out, mover: mover) }
        #expect(try names(dir) == [name + ".m4a", "session.json"])
        #expect(try Data(contentsOf: dir.appendingPathComponent(name + ".m4a")) == audio)
        #expect(try names(out).isEmpty)
    }
}

@Test func acrossVolumesFilesInSubfoldersAreCheckedToo() throws {
    let work = try temp("work"), out = try temp("out")
    let dir = try session(in: work, folder: name)
    try FileManager.default.createDirectory(at: dir.appendingPathComponent("frames"), withIntermediateDirectories: false)
    try audio.write(to: dir.appendingPathComponent("frames/1.heic"))
    let moved = try Delivery.deliver(dir, into: out, mover: otherVolume)
    #expect(try Data(contentsOf: moved.appendingPathComponent("frames/1.heic")) == audio)
    let dir2 = try session(in: work, folder: name)
    try FileManager.default.createDirectory(at: dir2.appendingPathComponent("frames"), withIntermediateDirectories: false)
    try audio.write(to: dir2.appendingPathComponent("frames/1.heic"))
    let short = Mover(move: otherVolume.move) { from, to in
        try FileManager.default.copyItem(at: from, to: to)
        try Data([7]).write(to: to.appendingPathComponent("frames/1.heic"))
    }
    #expect(throws: DeliveryError.copyMismatch(name)) { try Delivery.deliver(dir2, into: out, mover: short) }
    #expect(try Data(contentsOf: dir2.appendingPathComponent("frames/1.heic")) == audio)
}

@Test func aCopyLeftByAnInterruptedDeliveryIsReplaced() throws {
    let work = try temp("work"), out = try temp("out")
    let stale = out.appendingPathComponent("." + name + Delivery.partialSuffix)
    try FileManager.default.createDirectory(at: stale, withIntermediateDirectories: false)
    try Data([1]).write(to: stale.appendingPathComponent("junk"))
    let moved = try Delivery.deliver(try session(in: work, folder: name), into: out, mover: otherVolume)
    #expect(try names(out) == [name])
    #expect(try names(moved) == [name + ".m4a", "session.json"])
}

@Test func unwritableOutputFolderOnAnotherVolumeLeavesTheSessionInPlace() throws {
    let work = try temp("work"), out = try temp("out")
    try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: out.path)
    defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: out.path) }
    let dir = try session(in: work, folder: name)
    #expect(throws: CocoaError.self) { try Delivery.deliver(dir, into: out, mover: otherVolume) }
    #expect(try names(dir) == [name + ".m4a", "session.json"])
    #expect(try names(out).isEmpty)
}

@Test func pendingDeliveryMovesFinishedSessionsAndLeavesUnfinishedOnes() throws {
    let work = try temp("work")
    let out = work.deletingLastPathComponent().appendingPathComponent("later-\(UUID().uuidString)")
    try session(in: work, folder: "a", title: "A")
    try session(in: work, folder: "b", title: "B")
    try session(in: work, folder: "live", finished: false)
    #expect(Delivery.deliverPending(from: work, to: out) == "folder not found: \(out.path)")
    #expect(try names(work) == ["a", "b", "live"])
    try FileManager.default.createDirectory(at: out, withIntermediateDirectories: false)
    #expect(Delivery.deliverPending(from: work, to: out) == nil)
    #expect(try names(work) == ["live"])
    #expect(try names(out) == ["A", "B"].map { SessionNaming.sessionName(startedAt, title: $0) })
}

@Test func legacyUnfinishedSessionsAreAdoptedAndFinishedOnesStay() throws {
    let legacy = try temp("legacy"), work = try temp("work")
    try session(in: legacy, folder: "2026-09-20 10-00-00", finished: false)
    try session(in: legacy, folder: "2026-09-21 10-00 Done", title: "Done")
    try session(in: work, folder: "2026-09-20 10-00-00", finished: false)
    let adopted = try Delivery.adoptUnfinished(from: legacy, into: work)
    #expect(adopted.map(\.path) == [work.appendingPathComponent("2026-09-20 10-00-00 2").path])
    #expect(try names(adopted[0]) == ["computer audio.seg000.caf", "session.json"])
    #expect(try names(legacy) == ["2026-09-21 10-00 Done"])
}

@Test func missingLegacyFolderAdoptsNothing() throws {
    let base = try temp("none")
    let work = base.appendingPathComponent("work")
    #expect(try Delivery.adoptUnfinished(from: base.appendingPathComponent("legacy"), into: work).isEmpty)
    #expect(!FileManager.default.fileExists(atPath: work.path))
}
