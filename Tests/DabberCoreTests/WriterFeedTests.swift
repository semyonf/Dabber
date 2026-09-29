import AVFoundation
import Foundation
import Synchronization
import Testing
@testable import DabberCore

private func feedQoS(from priority: TaskPriority) async throws -> Set<UInt32> {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("feed-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let audio = dir.appendingPathComponent("a.m4a")
    let aac = try AACWriter(url: audio, channels: 1)
    try aac.write([Float](repeating: 0.1, count: 48_000))
    try aac.closeAndVerify()
    let seen = Mutex<Set<UInt32>>([])
    try await Task.detached(priority: priority) {
        let source = try AudioPassthrough(audio)
        let writer = try AVAssetWriter(outputURL: dir.appendingPathComponent("b.m4a"), fileType: .m4a)
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: nil, sourceFormatHint: source.format)
        writer.add(input)
        let lane = source.lane(input)
        #expect(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        try WriterFeed([(input, {
            seen.withLock { _ = $0.insert(qos_class_self().rawValue) }
            return try lane.next()
        })]).run(writer)
        writer.cancelWriting()
    }.value
    return seen.withLock { $0 }
}

@Test func writerFeedLanesRunAtUtilityQoS() async throws {
    #expect(try await feedQoS(from: .utility) == [QOS_CLASS_UTILITY.rawValue])
    #expect(try await feedQoS(from: .userInitiated) == [QOS_CLASS_UTILITY.rawValue])
}
