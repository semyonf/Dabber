import Foundation

public struct Mark: Codable, Equatable, Sendable, Identifiable {
    public let id: Int
    public let offsetNanos: UInt64
    public var text: String

    public init(id: Int, offsetNanos: UInt64, text: String = "") {
        self.id = id
        self.offsetNanos = offsetNanos
        self.text = text
    }

    public var seconds: Double { Double(offsetNanos) / 1e9 }

    public func title(number: Int) -> String { text.isEmpty ? "Mark \(number)" : text }
}

public struct Chapter: Equatable, Sendable {
    public let startMillis: Int
    public let title: String

    public init(startMillis: Int, title: String) {
        self.startMillis = startMillis
        self.title = title
    }
}

public enum Chapters {
    public static let startTitle = "Start"
    public static let textFile = "marks.txt"

    public static func marks(_ marks: [Mark], durationMillis: Int) -> [Chapter] {
        let last = max(0, durationMillis - 1)
        return marks.enumerated()
            .map { i, m in (i, Chapter(startMillis: min(Int(m.offsetNanos / 1_000_000), last), title: m.title(number: i + 1))) }
            .sorted { ($0.1.startMillis, $0.0) < ($1.1.startMillis, $1.0) }
            .map(\.1)
    }

    public static func make(_ marks: [Mark], durationMillis: Int) -> [Chapter] {
        let all = [Chapter(startMillis: 0, title: startTitle)] + Self.marks(marks, durationMillis: durationMillis)
        return all.indices.filter { $0 + 1 == all.count || all[$0 + 1].startMillis != all[$0].startMillis }.map { all[$0] }
    }

    public static func text(_ marks: [Mark], durationMillis: Int) -> String {
        Self.marks(marks, durationMillis: durationMillis).map { c in
            let s = c.startMillis / 1000
            return String(format: "%02d:%02d:%02d  ", s / 3600, s % 3600 / 60, s % 60) + c.title + "\n"
        }.joined()
    }
}
