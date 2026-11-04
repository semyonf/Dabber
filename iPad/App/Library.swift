import DabberCore
import DabberSpeech
import EventKit
import Foundation
import Observation
import UIKit

/// Finishes the recordings the broadcast extension left in the App Group and keeps the list of finished ones,
/// which live in Documents/Recordings (visible in the Files app under On My iPad > Dabber).
@MainActor @Observable
final class Library {
    static let transcribeKey = "transcribe"
    static let cleanMicsKey = "cleanMics"
    static let calendarKey = "calendarNames"

    private(set) var recordings: [URL] = []
    private(set) var recordingNow = false
    private(set) var finishing: String?
    private(set) var notes: [String] = []
    private var running = false
    /// Folders already tried in this run: one that failed stays in the shared folder and is tried again next launch.
    private var attempted: Set<String> = []

    var slidesOn: Bool {
        get { Group.defaults.object(forKey: Group.slidesKey) as? Bool ?? true }
        set { Group.defaults.set(newValue, forKey: Group.slidesKey) }
    }

    static var output: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Recordings", isDirectory: true)
    }

    nonisolated static var transcribeOn: Bool { UserDefaults.standard.object(forKey: transcribeKey) as? Bool ?? true }
    nonisolated static var cleanMicsOn: Bool { UserDefaults.standard.object(forKey: cleanMicsKey) as? Bool ?? true }
    nonisolated static var calendarOn: Bool { UserDefaults.standard.object(forKey: calendarKey) as? Bool ?? true }

    func launched() {
        try? FileManager.default.createDirectory(at: Self.output, withIntermediateDirectories: true)
        if let sessions = Group.sessions {
            try? FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        }
        if Self.transcribeOn { ParakeetSpeech.shared.prepare() }
        if Self.cleanMicsOn { LocalVqeModel.shared.prepare() }
        refresh()
    }

    /// Looks at the shared folder: a recording still being written shows as "Recording"; any other is finished.
    func refresh() {
        recordings = ((try? FileManager.default.contentsOfDirectory(
            at: Self.output, includingPropertiesForKeys: [.creationDateKey])) ?? [])
            .filter(\.hasDirectoryPath)
            .sorted { Self.created($0) > Self.created($1) }
        guard let sessions = Group.sessions else {
            notes = ["Dabber cannot reach its shared folder (App Group \(Group.id))."]
            return
        }
        let dirs = Finalizer.sessionFolders(root: sessions).filter(\.hasDirectoryPath)
        recordingNow = dirs.contains { Group.isLive($0) }
        let done = dirs.filter { !Group.isLive($0) && !attempted.contains($0.lastPathComponent) }
        guard !done.isEmpty, !running else { return }
        attempted.formUnion(done.map(\.lastPathComponent))
        finish(done, sessions: sessions)
    }

    func delete(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
        refresh()
    }

    private func finish(_ dirs: [URL], sessions: URL) {
        running = true
        notes = []
        UIApplication.shared.isIdleTimerDisabled = true
        let background = UIApplication.shared.beginBackgroundTask(withName: "Finish recordings")
        let output = Self.output
        Task.detached(priority: .userInitiated) {
            let speech: SpeechToText? = Self.transcribeOn ? ParakeetSpeech.shared.transcribe : nil
            if speech != nil { await ParakeetSpeech.shared.waitIfCached(seconds: 60) }
            if Self.cleanMicsOn { await LocalVqeModel.shared.waitUntilLoaded(seconds: 30) }
            var notes: [String] = []
            for dir in dirs {
                guard Finalizer.needsRecovery(dir) else {
                    // Nothing arrived at all (no audio files), or a folder finished earlier but not delivered.
                    if (try? SessionManifest.load(from: dir))?.finalize == nil {
                        notes.append("\(dir.lastPathComponent): nothing was recorded. Was Dabber chosen in the broadcast sheet?")
                        try? FileManager.default.removeItem(at: dir)
                    }
                    continue
                }
                await MainActor.run { self.finishing = dir.lastPathComponent }
                if Self.calendarOn { await Self.nameFromCalendar(dir) }
                notes += Self.problems(dir)
                do {
                    _ = try Delivery.finishAndDeliver(
                        dir, output: output, speech: speech, cleanMics: Self.cleanMicsOn,
                        micModel: Self.cleanMicsOn ? LocalVqeModel.shared.model : nil)
                } catch {
                    notes.append("\(dir.lastPathComponent): \(error.localizedDescription)")
                }
            }
            if let failure = Delivery.deliverPending(from: sessions, to: output) { notes.append(failure) }
            await MainActor.run {
                self.finishing = nil
                self.running = false
                self.notes = notes
                UIApplication.shared.isIdleTimerDisabled = false
                UIApplication.shared.endBackgroundTask(background)
                self.refresh()
            }
        }
    }

    /// What the extension could not get: the sound of the call or the microphone.
    nonisolated private static func problems(_ dir: URL) -> [String] {
        guard let manifest = try? SessionManifest.load(from: dir) else { return [] }
        var notes: [String] = []
        for source in manifest.sources where source.segments.isEmpty {
            notes.append(source.kind == .computer
                ? "\(dir.lastPathComponent): no sound of other apps arrived. The call app may keep its sound out of screen broadcasts."
                : "\(dir.lastPathComponent): no microphone. Turn on Microphone at the bottom of the broadcast sheet.")
        }
        return notes
    }

    /// Names the recording after the calendar event that was on when it started, as the Mac does at Record.
    nonisolated private static func nameFromCalendar(_ dir: URL) async {
        guard var manifest = try? SessionManifest.load(from: dir), manifest.title.isEmpty,
              EKEventStore.authorizationStatus(for: .event) == .fullAccess
        else { return }
        let store = EKEventStore()
        let start = manifest.startedAt
        let events = store.events(matching: store.predicateForEvents(
            withStart: start.addingTimeInterval(-12 * 3_600), end: start.addingTimeInterval(CalendarEvent.lookahead),
            calendars: nil))
            .map { CalendarEvent(title: $0.title ?? "", start: $0.startDate, end: $0.endDate, isAllDay: $0.isAllDay) }
        manifest.title = CalendarEvent.pickTitle(events, at: start)
        if !manifest.title.isEmpty { try? manifest.save(to: dir) }
    }

    func askForCalendar() {
        guard EKEventStore.authorizationStatus(for: .event) == .notDetermined else { return }
        Task { _ = try? await EKEventStore().requestFullAccessToEvents() }
    }

    private static func created(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
    }
}
