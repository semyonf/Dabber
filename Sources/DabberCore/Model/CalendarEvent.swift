import Foundation

public struct CalendarEvent: Equatable, Sendable {
    public static let lookahead: TimeInterval = 15 * 60

    public let title: String
    public let start: Date
    public let end: Date
    public let isAllDay: Bool

    public init(title: String, start: Date, end: Date, isAllDay: Bool = false) {
        self.title = title
        self.start = start
        self.end = end
        self.isAllDay = isAllDay
    }

    public static func pickTitle(_ events: [CalendarEvent], at now: Date) -> String {
        let candidates = events.filter {
            !$0.isAllDay && $0.end > now && $0.start <= now.addingTimeInterval(lookahead) && !$0.trimmedTitle.isEmpty
        }
        let closest = candidates.min { abs($0.start.timeIntervalSince(now)) < abs($1.start.timeIntervalSince(now)) }
        return closest?.trimmedTitle ?? ""
    }

    private var trimmedTitle: String { title.trimmingCharacters(in: .whitespacesAndNewlines) }
}

public protocol CalendarSource: Sendable {
    func events(from start: Date, to end: Date) async -> [CalendarEvent]
}

public struct NoCalendar: CalendarSource {
    public init() {}
    public func events(from start: Date, to end: Date) async -> [CalendarEvent] { [] }
}
