import DabberCore
import EventKit

struct EventKitCalendar: CalendarSource {
    func events(from start: Date, to end: Date) async -> [CalendarEvent] {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess:
            break
        case .notDetermined:
            guard (try? await EKEventStore().requestFullAccessToEvents()) == true else { return [] }
        default:
            return []
        }
        let store = EKEventStore()
        return store.events(matching: store.predicateForEvents(withStart: start, end: end, calendars: nil)).map {
            CalendarEvent(title: $0.title ?? "", start: $0.startDate, end: $0.endDate, isAllDay: $0.isAllDay)
        }
    }
}
