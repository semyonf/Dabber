import Foundation

public enum SourceKind: String, Codable, Sendable { case mic, computer }

public struct SegmentRecord: Codable, Equatable, Sendable {
    public var file: String
    public var startNanos: UInt64
    public var frames: Int
    public var endNanos: UInt64?
    public var sourceRate: Double
    public var sourceChannels: Int
    public var reason: String

    public init(file: String, startNanos: UInt64, frames: Int, endNanos: UInt64?, sourceRate: Double,
                sourceChannels: Int, reason: String) {
        self.file = file
        self.startNanos = startNanos
        self.frames = frames
        self.endNanos = endNanos
        self.sourceRate = sourceRate
        self.sourceChannels = sourceChannels
        self.reason = reason
    }
}

public struct RestartEvent: Codable, Equatable, Sendable {
    public var atNanos: UInt64
    public var reason: String
    public init(atNanos: UInt64, reason: String) {
        self.atNanos = atNanos
        self.reason = reason
    }
}

public struct SourceManifest: Codable, Equatable, Sendable {
    public var kind: SourceKind
    public var uid: String?
    public var name: String
    public var file: String
    public var channels: Int
    public var segments: [SegmentRecord]
    public var restarts: [RestartEvent]
    public var overruns: Int

    public init(kind: SourceKind, uid: String?, name: String, file: String, channels: Int,
                segments: [SegmentRecord], restarts: [RestartEvent], overruns: Int) {
        self.kind = kind
        self.uid = uid
        self.name = name
        self.file = file
        self.channels = channels
        self.segments = segments
        self.restarts = restarts
        self.overruns = overruns
    }

    public var trackBase: String { String(file.dropLast(4)) }
}

public struct GapRecord: Codable, Equatable, Sendable {
    public var track: String
    public var atFrame: Int
    public var frames: Int
    public init(track: String, atFrame: Int, frames: Int) {
        self.track = track
        self.atFrame = atFrame
        self.frames = frames
    }
}

public struct FinalizeReport: Codable, Equatable, Sendable {
    public var totalFrames: Int
    public var gaps: [GapRecord]
    public var driftMillis: [String: Double]
    public var resampled: [String]
    public var slidesError: String?
    public var unreadable: [String]?
    public init(
        totalFrames: Int, gaps: [GapRecord], driftMillis: [String: Double], resampled: [String], slidesError: String? = nil,
        unreadable: [String]? = nil
    ) {
        self.totalFrames = totalFrames
        self.gaps = gaps
        self.driftMillis = driftMillis
        self.resampled = resampled
        self.slidesError = slidesError
        self.unreadable = unreadable
    }
}

public struct FrameRecord: Codable, Equatable, Sendable {
    public let offsetNanos: UInt64
    public let file: String

    public init(offsetNanos: UInt64, file: String) {
        self.offsetNanos = offsetNanos
        self.file = file
    }
}

public struct SessionManifest: Codable, Equatable, Sendable {
    public static let fileName = "session.json"

    public var appVersion: String
    public var startedAt: Date
    public var sessionStartNanos: UInt64
    public var sources: [SourceManifest] = []
    public var marks: [Mark] = []
    public var frames: [FrameRecord] = []
    public var title = ""
    public var finalize: FinalizeReport?

    public init(appVersion: String, startedAt: Date, sessionStartNanos: UInt64) {
        self.appVersion = appVersion
        self.startedAt = startedAt
        self.sessionStartNanos = sessionStartNanos
    }

    private enum CodingKeys: String, CodingKey { case appVersion, startedAt, sessionStartNanos, sources, marks, frames, title, finalize }

    public var name: String { SessionNaming.sessionName(startedAt, title: title) }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        appVersion = try c.decode(String.self, forKey: .appVersion)
        startedAt = try c.decode(Date.self, forKey: .startedAt)
        sessionStartNanos = try c.decode(UInt64.self, forKey: .sessionStartNanos)
        sources = try c.decode([SourceManifest].self, forKey: .sources)
        marks = try c.decodeIfPresent([Mark].self, forKey: .marks) ?? []
        frames = try c.decodeIfPresent([FrameRecord].self, forKey: .frames) ?? []
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        finalize = try c.decodeIfPresent(FinalizeReport.self, forKey: .finalize)
    }

    @discardableResult
    public mutating func addMark(atNanos: UInt64) -> Mark {
        let mark = Mark(
            id: (marks.map(\.id).max() ?? 0) + 1,
            offsetNanos: atNanos > sessionStartNanos ? atNanos - sessionStartNanos : 0)
        marks.append(mark)
        return mark
    }

    public mutating func setMarkText(id: Int, _ text: String) {
        guard let i = marks.firstIndex(where: { $0.id == id }) else { return }
        marks[i].text = text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public mutating func removeMark(id: Int) {
        marks.removeAll { $0.id == id }
    }

    public static let framesDir = "frames"

    @discardableResult
    public mutating func addFrame(atNanos: UInt64) -> FrameRecord {
        let offset = atNanos > sessionStartNanos ? atNanos - sessionStartNanos : 0
        let frame = FrameRecord(offsetNanos: offset, file: "\(Self.framesDir)/\(offset).heic")
        frames.append(frame)
        return frame
    }

    public func save(to dir: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(self).write(to: dir.appendingPathComponent(Self.fileName), options: .atomic)
    }

    public static func load(from dir: URL) throws -> SessionManifest {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(SessionManifest.self, from: Data(contentsOf: dir.appendingPathComponent(fileName)))
    }
}
