import Foundation
import Testing
@testable import DabberCore

private let now = Date(timeIntervalSince1970: 1_800_000_000)

private func event(_ title: String, _ startMinutes: Double, _ endMinutes: Double, allDay: Bool = false) -> CalendarEvent {
    CalendarEvent(
        title: title, start: now.addingTimeInterval(startMinutes * 60), end: now.addingTimeInterval(endMinutes * 60),
        isAllDay: allDay)
}

private func pick(_ events: [CalendarEvent]) -> String { CalendarEvent.pickTitle(events, at: now) }

@Test func runningEventNamesTheSessionAndNoEventNamesNothing() {
    #expect(pick([event("Standup", -5, 10)]) == "Standup")
    #expect(pick([]) == "")
}

@Test func onlyEventsStartingWithinFifteenMinutesOrStillRunningCount() {
    #expect(pick([event("Soon", 15, 45)]) == "Soon")
    #expect(pick([event("Later", 15.1, 45)]) == "")
    #expect(pick([event("Over", -30, 0)]) == "")
}

@Test func allDayEventsAreIgnored() {
    #expect(pick([event("Holiday", -600, 800, allDay: true)]) == "")
    #expect(pick([event("Holiday", -600, 800, allDay: true), event("Call", 2, 30)]) == "Call")
}

@Test func closestStartWinsAmongOverlappingEvents() {
    #expect(pick([event("Long", -50, 60), event("Next", 5, 35), event("Other", -8, 20)]) == "Next")
    #expect(pick([event("Started", -2, 30), event("Next", 10, 40)]) == "Started")
}

@Test func emptyTitlesAreSkippedAndTitlesAreTrimmed() {
    #expect(pick([event("  ", -1, 30), event(" Sync  ", 10, 40)]) == "Sync")
    #expect(pick([event("", -1, 30)]) == "")
}
