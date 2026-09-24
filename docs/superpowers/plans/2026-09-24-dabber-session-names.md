# Dabber Session Names from the Calendar Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** On Record, Dabber looks up the calendar event that is on now (or starts within 15 minutes) and names the session `yyyy-MM-dd HH-mm <event title>` (`yyyy-MM-dd HH-mm` without an event). While recording, a **Name** field in the menu shows the title; edits go to `session.json` at once. At finalize the mix becomes `<name>.m4a` with the name in its m4a title tag, and the folder is renamed to `<name>` (" 2", " 3" on collisions). Crash recovery applies the saved title the same way. Headless `--title` makes the path checkable with ffprobe. Extra item (Task 10): stereo AAC at 256 kbps.

**Architecture:**
- `SessionNaming.sessionName(date, title:)` builds the name; `SessionNaming.sanitize` makes a title safe for a file name. Both pure and unit-tested.
- `CalendarEvent.pickTitle(events, at:)` picks the event (pure, unit-tested). `CalendarSource` is the protocol the model asks for events; `EventKitCalendar` (app target) is the only EventKit code; tests use a fake.
- `SessionManifest.title` holds the raw title as typed; `SessionManifest.name` derives the session name. `SessionRecorder.start(specs:title:at:)` names the folder; `setTitle` saves `session.json` under the lock, only while `.recording` (same path as marks).
- `RecorderModel.start()` asks the calendar before starting the engine, keeps `title` for the menu, and `setTitle` forwards every edit to the engine. `finalize` now returns the final folder URL, which becomes `lastSessionDir`.
- `Finalizer.run` renders as today (mix still written as `mix.m4a`) and writes the title tag on the mix. `Finalizer.rename` then renames the mix to `<name>.m4a` and the folder to the first free `<name>`, `<name> 2`, ... `Finalizer.finish` = run + rename; `recoverAll` and the model use it.
- `ChapterWriter.write(_:title:into:)` gains an optional title and accepts an empty chapter list (then no text track), so the same passthrough rewrite writes the tag.

**Tech Stack:** Swift 6.4 with SwiftPM and Swift Testing, EventKit, AVFoundation (`AVAssetWriter.metadata`), SwiftUI `MenuBarExtra`, ffprobe.

Spec: `docs/superpowers/specs/2026-09-24-dabber-session-names-design.md`. Format model: `docs/superpowers/plans/2026-09-24-dabber-marks.md`.

## Ground rules for implementers

- Repo root: the repository root. Branch `marks`. No remote. Never push, never switch branches.
- Commit messages: one line, `type: description`, no body, no trailers. `git add` by explicit path only; read `git diff --cached --stat` before every commit.
- Shell is zsh. Tests: `scripts/test.sh` only. Success means exit code 0: `scripts/test.sh > /tmp/dabber-test.log 2>&1; echo "exit=$?"`, then `tail -3 /tmp/dabber-test.log` for the count. Never judge by grepping text. No Xcode, no `xcodebuild`. Never use `@State`, `@Bindable` or `@FocusState`; bind with `Binding(get:set:)` onto the model.
- In zsh, `log` is a shell builtin. Always call `/usr/bin/log`.
- Swift warnings stay at 0: `sed 's/\x1b\[[0-9;]*m//g' /tmp/dabber-test.log | grep -cE '\.swift:[0-9]+:[0-9]+: warning:'` prints `0` (the log carries ANSI colour codes, so strip them first). The `ld: warning: search path ... not found` lines are from the CLT toolchain and were there before this plan.
- Hardware check: `scripts/build-app.sh`, then `scripts/run-headless.sh <log> <args>` with `--record --computer-audio` only. Never launch or quit `/Applications/Dabber.app`, never run `install-app.sh`, never touch the virtual mic.
- Code: English, no comments. KISS. Swift 6 language mode.
- Tasks marked **HUMAN** need the user. Stop there, tell the user exactly what to do in at most five short lines, and wait.
- Test counts assume the baseline of `5846762`: **204 tests**. If `scripts/test.sh` reports a different baseline before Task 1, shift every expected count by the difference.

## Facts checked for this plan (2026-09-24, macOS 26.6.2, CLT SDK `/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk`)

- EventKit headers: `+[EKEventStore authorizationStatusForEntityType:]` (Swift `EKEventStore.authorizationStatus(for: .event)`), `EKAuthorizationStatusNotDetermined` / `FullAccess` (macOS 14+), `-requestFullAccessToEventsWithCompletion:` with `(BOOL granted, NSError *error)` (Swift `requestFullAccessToEvents() async throws -> Bool`), `-predicateForEventsWithStartDate:endDate:calendars:` (nullable calendars = all), `-eventsMatchingPredicate:`, `EKEvent.allDay` with getter `isAllDay`, `title`/`startDate`/`endDate` are `null_unspecified` (IUO in Swift).
- Info.plist key for macOS 14+ full access: `NSCalendarsFullAccessUsageDescription` (per Apple docs; not checked against a header, TCC reads it at runtime; the HUMAN step verifies the prompt text).
- Spike (`/tmp/dabber-spike`): an `AVAssetWriter` passthrough rewrite of an `AACWriter`-style m4a with `writer.metadata = [AVMutableMetadataItem(identifier: .commonIdentifierTitle, value: "2026-09-24 14-00 Планёрка: Q3/план")]` completed, kept 96,000 frames, and ffprobe printed `TAG:title=2026-09-24 14-00 Планёрка: Q3/план`.
- `FileManager.moveItem` onto an existing file and onto an existing (empty) directory both throw `CocoaError.fileWriteFileExists` (516). A case-only folder rename (`x standup` -> `x Standup`) on the case-insensitive system volume succeeds.
- APFS name limit measured: 255 CJK characters (765 bytes) ok, 256 fail; 100 emoji ok; 80 four-person family emoji fail. The limit counts characters/code points, not bytes, so `17 + 80 + 4` characters fit for ordinary titles.
- Not checked: the real EventKit path (no calendar grant possible for an agent; the HUMAN step covers it), the menu on screen, QuickTime showing the title.

## Decisions

- The calendar is asked **before** the engine starts, so the folder is created with the event name right away. On the very first Record the permission prompt holds the start until it is answered (once per install); Record stays disabled meanwhile.
- The manifest keeps the raw title as typed (trailing space while typing is not eaten); `sanitize` runs whenever a file name is built.
- Sanitizing: control characters (Unicode `Cc`, includes newline, tab, DEL) removed; `Cf` like ZWJ kept, so emoji sequences survive; `/` and `:` become `-` (as `trackBase` does); leading dots and whitespace dropped; cut to 80 characters; trailing whitespace trimmed. An empty result means a date-only name.
- Event choice: not all-day, `end > now`, `start <= now + 15 min`, non-empty trimmed title; smallest `|start - now|` wins; ties keep the calendar's order.
- Folder names drop the seconds (`HH-mm`, per spec). Two sessions in one minute get " 2" as today.
- `Finalizer.run` still writes `mix.m4a`; `rename` moves it to `<name>.m4a` and then the folder. The mix name never carries the folder's " 2" suffix (names only collide between folders).
- Folder rename walks `<name>`, `<name> 2`, ...; the session's own current name counts as free, so a folder created as `X 2` because `X` was taken stays `X 2`.
- The title tag is the session name (date + sanitized title), the string the Finder shows, written on the mix only. Per-source tracks keep their names and get no tag. A zero-length session gets no tag (the chapter rewrite needs audio, as before).
- If the app dies between `run` and `rename`, the session stays finalized with `mix.m4a` in the old folder; recovery does not redo it. Accepted: the window is a few milliseconds and nothing is lost.
- Already finalized old sessions are never renamed. Old unfinished ones are recovered with the new naming.
- The Name field saves on every keystroke (spec: "saved at once"); `session.json` is a small atomic write.
- Task 10: stereo 256 kbps, mono stays 96 kbps, no setting. The disk estimate reads `AACWriter.bitRate`, so it follows; the low-disk test's minutes change from 19 to 18.

## File structure

```
Sources/DabberCore/Model/SessionNaming.swift     (modify) sessionName, sanitize (folderName removed)
Sources/DabberCore/Model/CalendarEvent.swift     CalendarEvent, pickTitle, CalendarSource, NoCalendar
Sources/DabberCore/Model/SessionManifest.swift   (modify) title, name
Sources/DabberCore/Engine/SessionRecorder.swift  (modify) start(specs:title:at:), setTitle
Sources/DabberCore/Finalize/ChapterWriter.swift  (modify) optional title tag, chapters may be empty
Sources/DabberCore/Finalize/Finalizer.swift      (modify) tag on the mix, rename, finish, recovery renames
Sources/DabberCore/Finalize/AACWriter.swift      (modify) stereo 256 kbps
Sources/DabberCore/App/RecorderModel.swift       (modify) calendar lookup, title, setTitle, finalize returns URL
Sources/Dabber/EventKitCalendar.swift            EventKit CalendarSource
Sources/Dabber/AppDelegate.swift                 (modify) pass EventKitCalendar
Sources/Dabber/MenuApp.swift                     (modify) Name field
Sources/Dabber/Headless.swift                    (modify) --title, NAMED line
Resources/Info.plist                             (modify) NSCalendarsFullAccessUsageDescription
Tests/DabberCoreTests/ManifestTests.swift        (modify)
Tests/DabberCoreTests/CalendarEventTests.swift
Tests/DabberCoreTests/SessionRecorderTests.swift (modify)
Tests/DabberCoreTests/FinalizerTests.swift       (modify)
Tests/DabberCoreTests/RecorderModelTests.swift   (modify)
docs/spikes/2026-09-24-session-names-check.md
```

---

### Task 1: Session name and title sanitizing (pure, TDD)

**Files:**
- Modify: `Sources/DabberCore/Model/SessionNaming.swift`, `Sources/DabberCore/Engine/SessionRecorder.swift`, `Tests/DabberCoreTests/ManifestTests.swift`, `Tests/DabberCoreTests/SessionRecorderTests.swift`

- [ ] **Step 1: Write the failing tests**

In `Tests/DabberCoreTests/ManifestTests.swift` replace
```swift
@Test func folderNameIsSortableLocalTime() {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: "Europe/Moscow")!
    let date = cal.date(from: DateComponents(year: 2026, month: 9, day: 23, hour: 5, minute: 53, second: 11))!
    #expect(SessionNaming.folderName(date, timeZone: cal.timeZone) == "2026-09-23 05-53-11")
}
```
with
```swift
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
```
In `Tests/DabberCoreTests/SessionRecorderTests.swift` replace both occurrences of `SessionNaming.folderName(date)` with `SessionNaming.sessionName(date, title: "")`:
```zsh
sed -i '' 's/SessionNaming\.folderName(date)/SessionNaming.sessionName(date, title: "")/g' Tests/DabberCoreTests/SessionRecorderTests.swift
```

- [ ] **Step 2: Run, expect compile failure**

Run: `scripts/test.sh > /tmp/dabber-test.log 2>&1; echo "exit=$?"`
Expected: `type 'SessionNaming' has no member 'sessionName'` in the log, non-zero exit.

- [ ] **Step 3: Implement**

In `Sources/DabberCore/Model/SessionNaming.swift` replace
```swift
    public static func folderName(_ date: Date, timeZone: TimeZone = .current) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = timeZone
        f.dateFormat = "yyyy-MM-dd HH-mm-ss"
        return f.string(from: date)
    }
```
with
```swift
    public static let titleLimit = 80

    public static func sessionName(_ date: Date, title: String, timeZone: TimeZone = .current) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = timeZone
        f.dateFormat = "yyyy-MM-dd HH-mm"
        let clean = sanitize(title)
        return clean.isEmpty ? f.string(from: date) : f.string(from: date) + " " + clean
    }

    public static func sanitize(_ title: String) -> String {
        let scalars = title.unicodeScalars.filter { $0.properties.generalCategory != .control }
        let flat = String(String.UnicodeScalarView(scalars))
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        let head = flat.drop { $0 == "." || $0.isWhitespace }
        return String(head.prefix(titleLimit)).trimmingCharacters(in: .whitespaces)
    }
```
In `Sources/DabberCore/Engine/SessionRecorder.swift` replace
```swift
        let dir = try Self.createSessionDir(in: root, name: SessionNaming.folderName(date))
```
with
```swift
        let dir = try Self.createSessionDir(in: root, name: SessionNaming.sessionName(date, title: ""))
```

- [ ] **Step 4: Run tests**

Run: `scripts/test.sh > /tmp/dabber-test.log 2>&1; echo "exit=$?"; tail -1 /tmp/dabber-test.log`
Expected: `Test run with 205 tests ... passed`, `exit=0`.

- [ ] **Step 5: Commit**

```zsh
git add Sources/DabberCore/Model/SessionNaming.swift Sources/DabberCore/Engine/SessionRecorder.swift Tests/DabberCoreTests/ManifestTests.swift Tests/DabberCoreTests/SessionRecorderTests.swift
git diff --cached --stat
git commit -m "feat: name sessions by date and minute plus a sanitized title"
```

---

### Task 2: Pick the calendar event (pure, TDD)

**Files:**
- Create: `Sources/DabberCore/Model/CalendarEvent.swift`, `Tests/DabberCoreTests/CalendarEventTests.swift`

- [ ] **Step 1: Write the failing tests `Tests/DabberCoreTests/CalendarEventTests.swift`**

```swift
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
```

- [ ] **Step 2: Run, expect compile failure**

Run: `scripts/test.sh > /tmp/dabber-test.log 2>&1; echo "exit=$?"`
Expected: `cannot find 'CalendarEvent' in scope`, non-zero exit.

- [ ] **Step 3: Implement `Sources/DabberCore/Model/CalendarEvent.swift`**

```swift
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
```

- [ ] **Step 4: Run tests**

Run: `scripts/test.sh > /tmp/dabber-test.log 2>&1; echo "exit=$?"; tail -1 /tmp/dabber-test.log`
Expected: `Test run with 210 tests ... passed`, `exit=0`.

- [ ] **Step 5: Commit**

```zsh
git add Sources/DabberCore/Model/CalendarEvent.swift Tests/DabberCoreTests/CalendarEventTests.swift
git diff --cached --stat
git commit -m "feat: pick the calendar event that names a session"
```

---

### Task 3: Title in `session.json`, folder named at start (TDD)

**Files:**
- Modify: `Sources/DabberCore/Model/SessionManifest.swift`, `Sources/DabberCore/Engine/SessionRecorder.swift`, `Tests/DabberCoreTests/ManifestTests.swift`, `Tests/DabberCoreTests/SessionRecorderTests.swift`

The title edit goes through the recorder's manifest copy under its lock, like marks, and is saved at once. After `stop()` edits are ignored.

- [ ] **Step 1: Write the failing tests**

Append to `Tests/DabberCoreTests/ManifestTests.swift`:
```swift
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
```
In `Tests/DabberCoreTests/SessionRecorderTests.swift` replace
```swift
    @Test func stopWithoutStartReturnsNil() throws {
```
with
```swift
    @Test func titleNamesTheFolderAndEditsAreSavedAtOnce() throws {
        let (r, root) = try recorder()
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let dir = try r.start(specs: specs, title: "Standup: team", at: date)
        #expect(dir.lastPathComponent == SessionNaming.sessionName(date, title: "Standup: team"))
        #expect(dir.deletingLastPathComponent().path == root.path)
        #expect(try SessionManifest.load(from: dir).title == "Standup: team")
        r.setTitle("Планёрка ")
        #expect(try SessionManifest.load(from: dir).title == "Планёрка ")
        _ = r.stop()
        r.setTitle("late")
        #expect(try SessionManifest.load(from: dir).title == "Планёрка ")
    }

    @Test func stopWithoutStartReturnsNil() throws {
```

- [ ] **Step 2: Run, expect compile failure**

Run: `scripts/test.sh > /tmp/dabber-test.log 2>&1; echo "exit=$?"`
Expected: `value of type 'SessionManifest' has no member 'title'` (and `extra argument 'title' in call`), non-zero exit.

- [ ] **Step 3: Implement the manifest**

In `Sources/DabberCore/Model/SessionManifest.swift` replace
```swift
    public var marks: [Mark] = []
    public var finalize: FinalizeReport?
```
with
```swift
    public var marks: [Mark] = []
    public var title = ""
    public var finalize: FinalizeReport?
```
replace
```swift
    private enum CodingKeys: String, CodingKey { case appVersion, startedAt, sessionStartNanos, sources, marks, finalize }
```
with
```swift
    private enum CodingKeys: String, CodingKey { case appVersion, startedAt, sessionStartNanos, sources, marks, title, finalize }

    public var name: String { SessionNaming.sessionName(startedAt, title: title) }
```
and replace
```swift
        marks = try c.decodeIfPresent([Mark].self, forKey: .marks) ?? []
```
with
```swift
        marks = try c.decodeIfPresent([Mark].self, forKey: .marks) ?? []
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
```

- [ ] **Step 4: Implement the recorder**

In `Sources/DabberCore/Engine/SessionRecorder.swift` replace
```swift
    public func start(specs: [SourceSpec], at date: Date = Date()) throws -> URL {
```
with
```swift
    public func start(specs: [SourceSpec], title: String = "", at date: Date = Date()) throws -> URL {
```
replace
```swift
        let dir = try Self.createSessionDir(in: root, name: SessionNaming.sessionName(date, title: ""))
        var manifest = SessionManifest(appVersion: appVersion, startedAt: date, sessionStartNanos: HostClock.nowNanos())
```
with
```swift
        let dir = try Self.createSessionDir(in: root, name: SessionNaming.sessionName(date, title: title))
        var manifest = SessionManifest(appVersion: appVersion, startedAt: date, sessionStartNanos: HostClock.nowNanos())
        manifest.title = title
```
and replace
```swift
    @discardableResult
    public func addMark(atNanos: UInt64) -> [Mark] { editMarks { $0.addMark(atNanos: atNanos) } }

    @discardableResult
    public func setMarkText(id: Int, _ text: String) -> [Mark] { editMarks { $0.setMarkText(id: id, text) } }

    @discardableResult
    public func removeMark(id: Int) -> [Mark] { editMarks { $0.removeMark(id: id) } }

    private func editMarks(_ edit: (inout SessionManifest) -> Void) -> [Mark] {
        lock.lock(); defer { lock.unlock() }
        guard state.phase == .recording, var manifest, let dir else { return [] }
        edit(&manifest)
        self.manifest = manifest
        try? manifest.save(to: dir)
        return manifest.marks
    }
```
with
```swift
    @discardableResult
    public func addMark(atNanos: UInt64) -> [Mark] { edit { $0.addMark(atNanos: atNanos) }?.marks ?? [] }

    @discardableResult
    public func setMarkText(id: Int, _ text: String) -> [Mark] { edit { $0.setMarkText(id: id, text) }?.marks ?? [] }

    @discardableResult
    public func removeMark(id: Int) -> [Mark] { edit { $0.removeMark(id: id) }?.marks ?? [] }

    public func setTitle(_ title: String) { _ = edit { $0.title = title } }

    private func edit(_ change: (inout SessionManifest) -> Void) -> SessionManifest? {
        lock.lock(); defer { lock.unlock() }
        guard state.phase == .recording, var manifest, let dir else { return nil }
        change(&manifest)
        self.manifest = manifest
        try? manifest.save(to: dir)
        return manifest
    }
```

- [ ] **Step 5: Run tests**

Run: `scripts/test.sh > /tmp/dabber-test.log 2>&1; echo "exit=$?"; tail -1 /tmp/dabber-test.log`
Expected: `Test run with 212 tests ... passed`, `exit=0`.

- [ ] **Step 6: Commit**

```zsh
git add Sources/DabberCore/Model/SessionManifest.swift Sources/DabberCore/Engine/SessionRecorder.swift Tests/DabberCoreTests/ManifestTests.swift Tests/DabberCoreTests/SessionRecorderTests.swift
git diff --cached --stat
git commit -m "feat: keep the session title in session.json and name the folder after it"
```

---

### Task 4: Title tag in the passthrough rewrite (TDD)

**Files:**
- Modify: `Sources/DabberCore/Finalize/ChapterWriter.swift`, `Tests/DabberCoreTests/FinalizerTests.swift`

With an empty chapter list the rewrite adds no text track; with a title it sets `writer.metadata` to one `.commonIdentifierTitle` item (ffprobe shows it as `title`).

The test compares the raw audio packet bytes, not decoded PCM: implementing this task showed that decoded PCM of a rewritten file can differ by float rounding (about 1e-8 from sample 768) depending on what was decoded just before in the process, while the packets are byte-identical (ffmpeg packet MD5 equal). Each case rewrites its own copy of the source, as production rewrites every file once.

- [ ] **Step 1: Write the failing test**

In `Tests/DabberCoreTests/FinalizerTests.swift` replace
```swift
@Test func marksBecomeChaptersInEveryFileAndMarksText() async throws {
```
with
```swift
private func audioBytes(_ url: URL) throws -> Data {
    let movie = AVMovie(url: url)
    let reader = try AVAssetReader(asset: movie)
    let output = AVAssetReaderTrackOutput(track: movie.tracks.first { $0.mediaType == .audio }!, outputSettings: nil)
    reader.add(output)
    #expect(reader.startReading())
    var bytes = Data()
    while let buffer = output.copyNextSampleBuffer() {
        guard let block = buffer.dataBuffer else { continue }
        var chunk = Data(count: CMBlockBufferGetDataLength(block))
        chunk.withUnsafeMutableBytes { _ = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: $0.count, destination: $0.baseAddress!) }
        bytes.append(chunk)
    }
    return bytes
}

private func titleTag(_ url: URL) async throws -> String? {
    let items = try await AVURLAsset(url: url).load(.commonMetadata)
    return try await AVMetadataItem.metadataItems(from: items, filteredByIdentifier: .commonIdentifierTitle).first?.load(.stringValue)
}

@Test func titleTagIsWrittenWithOrWithoutChapters() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tt-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let url = dir.appendingPathComponent("a.m4a")
    let both = dir.appendingPathComponent("b.m4a")
    let writer = try AACWriter(url: url, channels: 2)
    try writer.write(sine(frames: 100_000, channels: 2))
    try writer.closeAndVerify()
    try FileManager.default.copyItem(at: url, to: both)
    let before = try audioBytes(url)
    #expect(before.count > 1_000)
    try ChapterWriter.write([], title: "2026-09-24 14-00 Планёрка", into: url)
    #expect(try audioBytes(url) == before)
    #expect(try AVAudioFile(forReading: url).length == 100_000)
    #expect(try await titleTag(url) == "2026-09-24 14-00 Планёрка")
    #expect(try await chapterList(url).isEmpty)
    try ChapterWriter.write([Chapter(startMillis: 0, title: "Start")], title: "Созвон", into: both)
    #expect(try audioBytes(both) == before)
    #expect(try AVAudioFile(forReading: both).length == 100_000)
    #expect(try await titleTag(both) == "Созвон")
    #expect(try await chapterList(both) == ["0.000 Start"])
    #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted() == ["a.m4a", "b.m4a"])
}

@Test func marksBecomeChaptersInEveryFileAndMarksText() async throws {
```

- [ ] **Step 2: Run, expect compile failure**

Run: `scripts/test.sh > /tmp/dabber-test.log 2>&1; echo "exit=$?"`
Expected: `extra argument 'title' in call`, non-zero exit.

- [ ] **Step 3: Implement**

In `Sources/DabberCore/Finalize/ChapterWriter.swift` replace
```swift
    public static func write(_ chapters: [Chapter], into url: URL) throws {
```
with
```swift
    public static func write(_ chapters: [Chapter], title: String? = nil, into url: URL) throws {
```
replace
```swift
        let writer = try AVAssetWriter(outputURL: out, fileType: .m4a)
        let audio = AVAssetWriterInput(mediaType: .audio, outputSettings: nil, sourceFormatHint: audioFormat)
        let textFormat = try Self.textFormat()
        let text = AVAssetWriterInput(mediaType: .text, outputSettings: nil, sourceFormatHint: textFormat)
        text.marksOutputTrackAsEnabled = false
        writer.add(audio)
        writer.add(text)
        audio.addTrackAssociation(withTrackOf: text, type: AVAssetTrack.AssociationType.chapterList.rawValue)
        let end = CMTime(value: frames, timescale: CMTimeScale(Timeline.rate))
        let samples = try chapters.indices.map { i in
            let start = CMTime(value: CMTimeValue(chapters[i].startMillis), timescale: 1000)
            let next = i + 1 < chapters.count ? CMTime(value: CMTimeValue(chapters[i + 1].startMillis), timescale: 1000) : end
            return try Self.sample(chapters[i].title, start: start, duration: next - start, format: textFormat)
        }
```
with
```swift
        let writer = try AVAssetWriter(outputURL: out, fileType: .m4a)
        if let title {
            let item = AVMutableMetadataItem()
            item.identifier = .commonIdentifierTitle
            item.value = title as NSString
            writer.metadata = [item]
        }
        let audio = AVAssetWriterInput(mediaType: .audio, outputSettings: nil, sourceFormatHint: audioFormat)
        writer.add(audio)
        let end = CMTime(value: frames, timescale: CMTimeScale(Timeline.rate))
        var text: AVAssetWriterInput?
        var samples: [CMSampleBuffer] = []
        if !chapters.isEmpty {
            let textFormat = try Self.textFormat()
            let input = AVAssetWriterInput(mediaType: .text, outputSettings: nil, sourceFormatHint: textFormat)
            input.marksOutputTrackAsEnabled = false
            writer.add(input)
            audio.addTrackAssociation(withTrackOf: input, type: AVAssetTrack.AssociationType.chapterList.rawValue)
            samples = try chapters.indices.map { i in
                let start = CMTime(value: CMTimeValue(chapters[i].startMillis), timescale: 1000)
                let next = i + 1 < chapters.count ? CMTime(value: CMTimeValue(chapters[i + 1].startMillis), timescale: 1000) : end
                return try Self.sample(chapters[i].title, start: start, duration: next - start, format: textFormat)
            }
            text = input
        }
```
In the `Feed` class replace
```swift
        let text: AVAssetWriterInput
```
with
```swift
        let text: AVAssetWriterInput?
```
replace
```swift
        init(audio: AVAssetWriterInput, text: AVAssetWriterInput, output: AVAssetReaderTrackOutput,
```
with
```swift
        init(audio: AVAssetWriterInput, text: AVAssetWriterInput?, output: AVAssetReaderTrackOutput,
```
replace
```swift
        func run() -> Bool {
            group.enter()
            group.enter()
            text.requestMediaDataWhenReady(on: DispatchQueue(label: "dabber.chapters.text")) { self.feedText() }
            audio.requestMediaDataWhenReady(on: DispatchQueue(label: "dabber.chapters.audio")) { self.feedAudio() }
            return group.wait(timeout: .now() + 600) == .success
        }

        private func feedText() {
            while text.isReadyForMoreMediaData {
```
with
```swift
        func run() -> Bool {
            if let text {
                group.enter()
                text.requestMediaDataWhenReady(on: DispatchQueue(label: "dabber.chapters.text")) { self.feedText() }
            }
            group.enter()
            audio.requestMediaDataWhenReady(on: DispatchQueue(label: "dabber.chapters.audio")) { self.feedAudio() }
            return group.wait(timeout: .now() + 600) == .success
        }

        private func feedText() {
            guard let text else { return }
            while text.isReadyForMoreMediaData {
```

- [ ] **Step 4: Run tests**

Run: `scripts/test.sh > /tmp/dabber-test.log 2>&1; echo "exit=$?"; tail -1 /tmp/dabber-test.log`
Expected: `Test run with 213 tests ... passed`, `exit=0`.

- [ ] **Step 5: Commit**

```zsh
git add Sources/DabberCore/Finalize/ChapterWriter.swift Tests/DabberCoreTests/FinalizerTests.swift
git diff --cached --stat
git commit -m "feat: write an m4a title tag in the passthrough rewrite"
```

---

### Task 5: Name the mix and rename the folder at finalize, also in recovery (TDD)

**Files:**
- Modify: `Sources/DabberCore/Finalize/Finalizer.swift`, `Tests/DabberCoreTests/FinalizerTests.swift`

`run` tags the mix with `manifest.name` (with or without marks). `rename` moves `mix.m4a` to `<name>.m4a`, then the folder to the first free `<name>`, `<name> 2`, ... (its own current name counts as free). `finish` = `run` + `rename`; `recoverAll` uses `finish` and returns the final folders. Tests that call `rename` work inside their own temp root, never in the shared temp directory.

- [ ] **Step 1: Pin the test session's start date**

In `Tests/DabberCoreTests/FinalizerTests.swift` replace
```swift
private func makeSession() throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("fin-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let s: UInt64 = 10_000_000_000
    var m = SessionManifest(appVersion: "t", startedAt: Date(), sessionStartNanos: s)
```
with
```swift
private let startedAt = Date(timeIntervalSince1970: 1_800_000_000)

private func makeSession() throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("fin-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let s: UInt64 = 10_000_000_000
    var m = SessionManifest(appVersion: "t", startedAt: startedAt, sessionStartNanos: s)
```

- [ ] **Step 2: Recovery now renames: update the three recovery tests**

Replace
```swift
    #expect(Finalizer.recoverAll(dirs: Finalizer.sessionFolders(root: root)).map(\.path) == [pending.path])
    #expect(FileManager.default.fileExists(atPath: pending.appendingPathComponent("mix.m4a").path))
```
with
```swift
    let name = SessionNaming.sessionName(startedAt, title: "")
    #expect(Finalizer.recoverAll(dirs: Finalizer.sessionFolders(root: root)).map(\.path) == [root.appendingPathComponent(name).path])
    #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent(name).appendingPathComponent(name + ".m4a").path))
```
replace
```swift
    #expect(recovered.map(\.path) == [old.path])
```
with
```swift
    #expect(recovered.map(\.path) == [root.appendingPathComponent(SessionNaming.sessionName(startedAt, title: "")).path])
```
and replace
```swift
    #expect(Finalizer.recoverAll(dirs: Finalizer.sessionFolders(root: root)).map(\.path) == [pending.path])
    #expect(try await chapterList(pending.appendingPathComponent("mix.m4a")) == ["0.000 Start", "2.000 Mark 1"])
    #expect(try SessionManifest.load(from: pending).marks.count == 1)
```
with
```swift
    let name = SessionNaming.sessionName(startedAt, title: "")
    let done = root.appendingPathComponent(name)
    #expect(Finalizer.recoverAll(dirs: Finalizer.sessionFolders(root: root)).map(\.path) == [done.path])
    #expect(try await chapterList(done.appendingPathComponent(name + ".m4a")) == ["0.000 Start", "2.000 Mark 1"])
    #expect(try SessionManifest.load(from: done).marks.count == 1)
```

- [ ] **Step 3: Append the failing tests to `Tests/DabberCoreTests/FinalizerTests.swift`**

```swift
private func namedSession(_ title: String) throws -> (root: URL, dir: URL) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("nm-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let dir = root.appendingPathComponent("rec")
    try FileManager.default.moveItem(at: try makeSession(), to: dir)
    var m = try SessionManifest.load(from: dir)
    m.title = title
    try m.save(to: dir)
    return (root, dir)
}

@Test func finishNamesTheMixAndTheFolderAfterTheTitle() async throws {
    let (root, dir) = try namedSession("Планёрка: Q3/план")
    let name = SessionNaming.sessionName(startedAt, title: "Планёрка: Q3/план")
    let out = try Finalizer.finish(dir)
    #expect(out.path == root.appendingPathComponent(name).path)
    #expect(!FileManager.default.fileExists(atPath: dir.path))
    let names = Set(try FileManager.default.contentsOfDirectory(atPath: out.path))
    #expect(names == ["computer audio.m4a", "mic - A.m4a", name + ".m4a", "session.json"])
    #expect(try await titleTag(out.appendingPathComponent(name + ".m4a")) == name)
    #expect(try await chapterList(out.appendingPathComponent(name + ".m4a")).isEmpty)
    #expect(try await titleTag(out.appendingPathComponent("mic - A.m4a")) == nil)
}

@Test func takenNamesGetANumberAndASessionKeepsItsOwnNumber() throws {
    let (root, dir) = try namedSession("Sync")
    let name = SessionNaming.sessionName(startedAt, title: "Sync")
    try FileManager.default.createDirectory(at: root.appendingPathComponent(name), withIntermediateDirectories: false)
    #expect(try Finalizer.finish(dir).lastPathComponent == name + " 2")
    let (other, started) = try namedSession("Sync")
    try FileManager.default.createDirectory(at: other.appendingPathComponent(name), withIntermediateDirectories: false)
    let own = other.appendingPathComponent(name + " 2")
    try FileManager.default.moveItem(at: started, to: own)
    #expect(try Finalizer.finish(own).path == own.path)
    #expect(FileManager.default.fileExists(atPath: own.appendingPathComponent(name + ".m4a").path))
}

@Test func recoveryAppliesTheSavedTitle() async throws {
    let (root, _) = try namedSession("Созвон")
    let name = SessionNaming.sessionName(startedAt, title: "Созвон")
    let done = root.appendingPathComponent(name)
    #expect(Finalizer.recoverAll(dirs: Finalizer.sessionFolders(root: root)).map(\.path) == [done.path])
    #expect(try await titleTag(done.appendingPathComponent(name + ".m4a")) == name)
}
```

- [ ] **Step 4: Run, expect compile failure**

Run: `scripts/test.sh > /tmp/dabber-test.log 2>&1; echo "exit=$?"`
Expected: `type 'Finalizer' has no member 'finish'`, non-zero exit.

- [ ] **Step 4a: Serialize the Finalizer tests**

Found while implementing: with the title tag every finalize runs the passthrough rewrite, and about 15 Finalizer tests running in parallel block all cooperative threads (10 on this Mac) inside `AVAssetReaderTrackOutput.copyNextSampleBuffer`, which needs a free cooperative thread to make progress; the run hangs (`sample` showed exactly 10 blocked cooperative threads and no other worker). `--no-parallel` passes. Production runs at most two finalizes at once (stop and launch recovery). Put every `@Test` of `FinalizerTests.swift` into one serialized suite, like `SessionRecorderTests`: insert `@Suite(.serialized) struct FinalizerTests {}` and `extension FinalizerTests {` before the first `@Test` (after `makeSession`), indent the rest of the file by 4 spaces, and close the extension at the end of the file. Helpers defined after the first test become private members of the extension.

- [ ] **Step 5: Implement**

In `Sources/DabberCore/Finalize/Finalizer.swift` replace
```swift
        if !manifest.marks.isEmpty, total > 0 {
            let millis = total * 1000 / Timeline.rate
            try Chapters.text(manifest.marks, durationMillis: millis)
                .write(to: dir.appendingPathComponent(Chapters.textFile), atomically: true, encoding: .utf8)
            let chapters = Chapters.make(manifest.marks, durationMillis: millis)
            for writer in writers + [mix] { try ChapterWriter.write(chapters, into: writer.url) }
        }
```
with
```swift
        if total > 0 {
            let millis = total * 1000 / Timeline.rate
            var chapters: [Chapter] = []
            if !manifest.marks.isEmpty {
                try Chapters.text(manifest.marks, durationMillis: millis)
                    .write(to: dir.appendingPathComponent(Chapters.textFile), atomically: true, encoding: .utf8)
                chapters = Chapters.make(manifest.marks, durationMillis: millis)
                for writer in writers { try ChapterWriter.write(chapters, into: writer.url) }
            }
            try ChapterWriter.write(chapters, title: manifest.name, into: mix.url)
        }
```
replace
```swift
    private static func encodeConcurrently(_ writers: [AACWriter], _ chunks: [[Float]]) throws {
```
with
```swift
    public static func finish(_ dir: URL) throws -> URL {
        try run(dir)
        return try rename(dir)
    }

    public static func rename(_ dir: URL) throws -> URL {
        let name = try SessionManifest.load(from: dir).name
        try FileManager.default.moveItem(at: dir.appendingPathComponent(mixFile), to: dir.appendingPathComponent(name + ".m4a"))
        let parent = dir.deletingLastPathComponent()
        var n = 1
        while true {
            let candidate = n == 1 ? name : "\(name) \(n)"
            if candidate == dir.lastPathComponent { return dir }
            let target = parent.appendingPathComponent(candidate)
            do {
                try FileManager.default.moveItem(at: dir, to: target)
                return target
            } catch CocoaError.fileWriteFileExists {
                n += 1
            }
        }
    }

    private static func encodeConcurrently(_ writers: [AACWriter], _ chunks: [[Float]]) throws {
```
and replace
```swift
            do {
                try run(dir)
                done.append(dir)
            } catch {
```
with
```swift
            do {
                done.append(try finish(dir))
            } catch {
```

- [ ] **Step 6: Run tests**

Run: `scripts/test.sh > /tmp/dabber-test.log 2>&1; echo "exit=$?"; tail -1 /tmp/dabber-test.log`
Expected: `Test run with 216 tests ... passed`, `exit=0`.

- [ ] **Step 7: Commit**

```zsh
git add Sources/DabberCore/Finalize/Finalizer.swift Tests/DabberCoreTests/FinalizerTests.swift
git diff --cached --stat
git commit -m "feat: name the mix and rename the folder after the title at finalize"
```

---

### Task 6: Calendar title, edits and the renamed folder in `RecorderModel` (TDD)

**Files:**
- Modify: `Sources/DabberCore/App/RecorderModel.swift`, `Tests/DabberCoreTests/RecorderModelTests.swift`

`start()` sets `starting` (Record disabled), asks the calendar for `[now, now + 15 min]`, picks the title and starts the engine with it. `setTitle` stores the text and forwards it to the engine on every edit. When the engine reports `.idle`, `tick()` clears the title. `finalize` returns the final folder, which becomes `lastSessionDir`.

- [ ] **Step 1: Give the fake engine a title and adapt the finalize closures**

In `Tests/DabberCoreTests/RecorderModelTests.swift` replace
```swift
    func start(specs: [SourceSpec]) throws -> URL {
```
with
```swift
    func start(specs: [SourceSpec], title: String) throws -> URL {
```
replace
```swift
        started.append(specs)
```
with
```swift
        started.append(specs)
        manifest.title = title
```
replace
```swift
    func removeMark(id: Int) -> [Mark] { editMarks { $0.removeMark(id: id) } }
```
with
```swift
    func removeMark(id: Int) -> [Mark] { editMarks { $0.removeMark(id: id) } }
    func setTitle(_ title: String) { _ = editMarks { $0.title = title } }
```
replace
```swift
    let m = RecorderModel(engine: engine, catalog: FakeCatalog(devices: [airpods, usb]), enabledIDs: enabled, persist: { _ in }, finalize: finalized)
```
with
```swift
    let m = RecorderModel(
        engine: engine, catalog: FakeCatalog(devices: [airpods, usb]), enabledIDs: enabled, persist: { _ in },
        finalize: { finalized($0); return $0 })
```
and make the other finalize closures return their input:
```zsh
sed -i '' 's/finalize: { _ in }/finalize: { $0 }/g' Tests/DabberCoreTests/RecorderModelTests.swift
grep -c 'finalize: { \$0 }' Tests/DabberCoreTests/RecorderModelTests.swift
```
Expected: `5`.

- [ ] **Step 2: Append the failing tests to `Tests/DabberCoreTests/RecorderModelTests.swift`**

```swift
private final class FakeCalendar: CalendarSource, @unchecked Sendable {
    let make: @Sendable (Date) -> [CalendarEvent]
    var windows: [TimeInterval] = []

    init(_ make: @escaping @Sendable (Date) -> [CalendarEvent]) { self.make = make }

    func events(from start: Date, to end: Date) async -> [CalendarEvent] {
        windows.append(end.timeIntervalSince(start))
        return make(start)
    }
}

@MainActor @Test func recordingTakesTheCurrentEventTitleAndSavesEdits() async {
    let e = FakeEngine()
    let calendar = FakeCalendar { now in
        [
            CalendarEvent(title: "Holiday", start: now.addingTimeInterval(-3_600), end: now.addingTimeInterval(3_600), isAllDay: true),
            CalendarEvent(title: "Планёрка", start: now.addingTimeInterval(-120), end: now.addingTimeInterval(1_800)),
        ]
    }
    let renamed = URL(fileURLWithPath: "/tmp/renamed-session")
    let m = RecorderModel(
        engine: e, catalog: FakeCatalog(devices: [airpods]), enabledIDs: ["computer"], persist: { _ in },
        finalize: { _ in renamed }, calendar: calendar)
    m.refreshDevices()
    await m.startStop()
    #expect(calendar.windows == [900])
    #expect(m.title == "Планёрка")
    #expect(e.manifest.title == "Планёрка")
    m.setTitle("Планёрка: итоги")
    #expect(m.title == "Планёрка: итоги")
    #expect(e.manifest.title == "Планёрка: итоги")
    await m.startStop()
    #expect(m.title == "")
    #expect(m.lastSessionDir == renamed)
}

@MainActor @Test func withoutAnEventTheTitleIsEmpty() async {
    let e = FakeEngine()
    let m = model(e)
    await m.startStop()
    #expect(e.started.count == 1)
    #expect(m.title == "")
    #expect(e.manifest.title == "")
}
```

- [ ] **Step 3: Run, expect compile failure**

Run: `scripts/test.sh > /tmp/dabber-test.log 2>&1; echo "exit=$?"`
Expected: `extra argument 'calendar' in call` or `value of type 'RecorderModel' has no member 'title'`, non-zero exit.

- [ ] **Step 4: Implement**

In `Sources/DabberCore/App/RecorderModel.swift` replace
```swift
public protocol RecordingEngine: Sendable {
    func start(specs: [SourceSpec]) throws -> URL
```
with
```swift
public protocol RecordingEngine: Sendable {
    func start(specs: [SourceSpec], title: String) throws -> URL
    func setTitle(_ title: String)
```
replace
```swift
    public func start(specs: [SourceSpec]) throws -> URL { try start(specs: specs, at: Date()) }
```
with
```swift
    public func start(specs: [SourceSpec], title: String) throws -> URL { try start(specs: specs, title: title, at: Date()) }
```
replace
```swift
    public var draft = ""
```
with
```swift
    public var draft = ""
    public private(set) var title = ""
```
replace
```swift
    private let finalize: @Sendable (URL) throws -> Void
    private let clock: @Sendable () -> UInt64
```
with
```swift
    private let finalize: @Sendable (URL) throws -> URL
    private let clock: @Sendable () -> UInt64
    private let calendar: any CalendarSource
```
replace
```swift
        finalize: @escaping @Sendable (URL) throws -> Void = { try Finalizer.run($0) },
        clock: @escaping @Sendable () -> UInt64 = HostClock.nowNanos
    ) {
```
with
```swift
        finalize: @escaping @Sendable (URL) throws -> URL = { try Finalizer.finish($0) },
        clock: @escaping @Sendable () -> UInt64 = HostClock.nowNanos,
        calendar: any CalendarSource = NoCalendar()
    ) {
```
replace
```swift
        self.clock = clock
        lastSessionDir = engine.lastSessionDir
```
with
```swift
        self.clock = clock
        self.calendar = calendar
        lastSessionDir = engine.lastSessionDir
```
replace
```swift
    public func refreshDevices() {
```
with
```swift
    public func setTitle(_ text: String) {
        title = text
        engine.setTitle(text)
    }

    public func refreshDevices() {
```
replace
```swift
        if status.phase == .idle, !sessionMics.isEmpty {
```
with
```swift
        if status.phase == .idle, !title.isEmpty { title = "" }
        if status.phase == .idle, !sessionMics.isEmpty {
```
replace
```swift
            do {
                try await Task.detached { try finalize(dir) }.value
                errorText = nil
            } catch {
                errorText = "finalize failed: \(error)"
            }
            finalizing = false
            finalizeTask = nil
            lastSessionDir = dir
            tick()
```
with
```swift
            do {
                lastSessionDir = try await Task.detached { try finalize(dir) }.value
                errorText = nil
            } catch {
                lastSessionDir = dir
                errorText = "finalize failed: \(error)"
            }
            finalizing = false
            finalizeTask = nil
            tick()
```
and replace
```swift
        starting = true
        do {
            _ = try await Task.detached { try engine.start(specs: startSpecs) }.value
```
with
```swift
        starting = true
        let now = Date()
        let events = await calendar.events(from: now, to: now.addingTimeInterval(CalendarEvent.lookahead))
        let title = CalendarEvent.pickTitle(events, at: now)
        do {
            _ = try await Task.detached { try engine.start(specs: startSpecs, title: title) }.value
            self.title = title
```

- [ ] **Step 5: Run tests**

Run: `scripts/test.sh > /tmp/dabber-test.log 2>&1; echo "exit=$?"; tail -1 /tmp/dabber-test.log`
Expected: `Test run with 218 tests ... passed`, `exit=0`.

- [ ] **Step 6: Commit**

```zsh
git add Sources/DabberCore/App/RecorderModel.swift Tests/DabberCoreTests/RecorderModelTests.swift
git diff --cached --stat
git commit -m "feat: prefill the session title from the calendar and save edits"
```

---

### Task 7: EventKit calendar source and the usage string

**Files:**
- Create: `Sources/Dabber/EventKitCalendar.swift`
- Modify: `Sources/Dabber/AppDelegate.swift`, `Resources/Info.plist`

Only this file touches EventKit; it is checked by the HUMAN step (an agent cannot grant calendar access). Access is requested only while the status is `.notDetermined`, which macOS reports once; after that the answer is remembered. Denied, restricted or write-only access gives no events, so the name is date-only and nothing is shown as an error. A fresh `EKEventStore` is made per lookup (one per Record press).

- [ ] **Step 1: Create `Sources/Dabber/EventKitCalendar.swift`**

```swift
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
```

- [ ] **Step 2: Wire it and add the usage string**

In `Sources/Dabber/AppDelegate.swift` replace
```swift
        persistNames: { UserDefaults.standard.set($0, forKey: namesKey) })
```
with
```swift
        persistNames: { UserDefaults.standard.set($0, forKey: namesKey) },
        calendar: EventKitCalendar())
```
In `Resources/Info.plist` replace
```xml
  <key>NSAudioCaptureUsageDescription</key><string>Dabber records audio played by other apps.</string>
```
with
```xml
  <key>NSAudioCaptureUsageDescription</key><string>Dabber records audio played by other apps.</string>
  <key>NSCalendarsFullAccessUsageDescription</key><string>Dabber names each recording after the calendar event that is on.</string>
```

- [ ] **Step 3: Tests and build**

Run:
```zsh
plutil -lint Resources/Info.plist
scripts/test.sh > /tmp/dabber-test.log 2>&1; echo "exit=$?"; tail -1 /tmp/dabber-test.log
grep -c '\.swift:[0-9]*:[0-9]*: warning:' /tmp/dabber-test.log
scripts/build-app.sh > /tmp/dabber-build.log 2>&1; echo "exit=$?"
/usr/libexec/PlistBuddy -c "Print :NSCalendarsFullAccessUsageDescription" build/Dabber.app/Contents/Info.plist
```
Expected: `Resources/Info.plist: OK`; `Test run with 218 tests ... passed`, `exit=0`; `0` warnings; build `exit=0`; the usage string printed.

- [ ] **Step 4: Commit**

```zsh
git add Sources/Dabber/EventKitCalendar.swift Sources/Dabber/AppDelegate.swift Resources/Info.plist
git diff --cached --stat
git commit -m "feat: read the current event from EventKit"
```

---

### Task 8: Name field in the menu

**Files:**
- Modify: `Sources/Dabber/MenuApp.swift`

A thin view over `RecorderModel`, shown only while recording, bound with `Binding(get:set:)`. The date prefix is not part of the field; it is always added.

- [ ] **Step 1: Add the field**

In `Sources/Dabber/MenuApp.swift` replace
```swift
            if model.isRecording { MarksView(model: model) }
```
with
```swift
            if model.isRecording {
                HStack {
                    Text("Name").font(.caption).foregroundStyle(.secondary)
                    TextField("Title (optional)", text: Binding(get: { model.title }, set: { model.setTitle($0) }))
                }
                MarksView(model: model)
            }
```

- [ ] **Step 2: Tests and build**

Run: `scripts/test.sh > /tmp/dabber-test.log 2>&1; echo "exit=$?"`, then `scripts/build-app.sh > /tmp/dabber-build.log 2>&1; echo "exit=$?"`.
Expected: `Test run with 218 tests ... passed`, `exit=0`; build `exit=0`.

- [ ] **Step 3: Commit**

```zsh
git add Sources/Dabber/MenuApp.swift
git diff --cached --stat
git commit -m "feat: add the Name field to the menu while recording"
```

---

### Task 9: Headless `--title` and the end-to-end check (automated)

**Files:**
- Modify: `Sources/Dabber/Headless.swift`

`--title <text>` sets the title right after the start, like an edit in the menu, so the folder is created date-only and renamed at finalize: the same path as a user rename and as recovery. After finalize the log prints `NAMED <final folder>`.

- [ ] **Step 1: Parse the option**

In `Sources/Dabber/Headless.swift`, in the `--record` case, replace
```swift
            var marks: [(at: Double, text: String)] = []
```
with
```swift
            var marks: [(at: Double, text: String)] = []
            var title: String?
```
and replace
```swift
                    marks.append((at, parts.count > 1 ? String(parts[1]) : ""))
                default:
```
with
```swift
                    marks.append((at, parts.count > 1 ? String(parts[1]) : ""))
                case "--title":
                    i += 1
                    guard i < args.count else { return 64 }
                    title = args[i]
                default:
```

- [ ] **Step 2: Set the title and log the final folder**

Replace
```swift
            log.line("SESSION \(dir.path)")
```
with
```swift
            log.line("SESSION \(dir.path)")
            if let title {
                recorder.setTitle(title)
                log.line("TITLE \(title)")
            }
```
and replace
```swift
            log.line("FINALIZED total=\(report.totalFrames) gaps=\(report.gaps.count) resampled=\(report.resampled.count)")
            return 0
```
with
```swift
            log.line("FINALIZED total=\(report.totalFrames) gaps=\(report.gaps.count) resampled=\(report.resampled.count)")
            log.line("NAMED \(try Finalizer.rename(stopped).path)")
            return 0
```

- [ ] **Step 3: Tests and build**

Run: `scripts/test.sh > /tmp/dabber-test.log 2>&1; echo "exit=$?"`, then `scripts/build-app.sh > /tmp/dabber-build.log 2>&1; echo "exit=$?"`.
Expected: `Test run with 218 tests ... passed`, `exit=0`; build `exit=0`.

- [ ] **Step 4: Record 10 s of computer audio with a title and a mark**

Run:
```zsh
rm -rf build/names-e2e
scripts/run-headless.sh "$PWD/build/names-e2e.log" --record --computer-audio --seconds 10 --mark-at "3:точка" --title "Планёрка: Q3/план" --out "$PWD/build/names-e2e" > /tmp/names-e2e.out 2>&1; echo "exit=$?"
grep -E "SESSION|TITLE|MARK|FINALIZED|NAMED|EXIT" build/names-e2e.log
```
Expected: `exit=0`; `SESSION .../build/names-e2e/2026-09-24 HH-mm`, `TITLE Планёрка: Q3/план`, `MARK 1 at=30xx ms точка`, `FINALIZED total=... resampled=0`, `NAMED .../build/names-e2e/2026-09-24 HH-mm Планёрка- Q3-план`, `EXIT 0`.

- [ ] **Step 5: Check names, tag and chapters**

Run:
```zsh
S=$(sed -n 's/^[0-9.]* NAMED //p' build/names-e2e.log)
N=${S:t}
ls build/names-e2e
ls "$S"
ffprobe -v error -show_entries format_tags=title -of default=nw=1 "$S/$N.m4a"
ffprobe -v error -show_entries chapter=start:chapter_tags=title -of csv=p=0 "$S/$N.m4a"
ffprobe -v error -show_entries format_tags=title -of default=nw=1 "$S/computer audio.m4a"
```
Expected: one folder, `2026-09-24 HH-mm Планёрка- Q3-план`; in it `2026-09-24 HH-mm Планёрка- Q3-план.m4a`, `computer audio.m4a`, `marks.txt`, `session.json` (no `mix.m4a`, no `.caf`); `TAG:title=2026-09-24 HH-mm Планёрка- Q3-план`; chapters `0,Start` and `30xx,точка`; nothing for `computer audio.m4a`'s title. Any other result is a bug: stop and report it with the output.

- [ ] **Step 6: Commit**

```zsh
git add Sources/Dabber/Headless.swift
git diff --cached --stat
git commit -m "feat: add --title to headless recording"
```

---

### Task 10: Stereo AAC at 256 kbps (TDD)

**Files:**
- Modify: `Sources/DabberCore/Finalize/AACWriter.swift`, `Tests/DabberCoreTests/ManifestTests.swift`, `Tests/DabberCoreTests/SessionRecorderTests.swift`

All recordings, no setting. Mono stays 96 kbps. `DiskCheck.secondsLeft` uses `AACWriter.bitRate`, so the estimate follows; the new test pins it: channels `[2, 1]` plus the stereo mix need `576,000 B/s` CAF + `(256k + 96k + 256k) / 8 = 76,000 B/s` m4a, so `652,000,000` free bytes last exactly 1,000 s. The low-disk recorder test (720 MB free at 61 s) now computes 1,097 s, so its warning reads 18 min instead of 19.

- [ ] **Step 1: Write the failing test**

Append to `Tests/DabberCoreTests/ManifestTests.swift`:
```swift
@Test func stereoIsEncodedAt256kAndTheDiskEstimateUsesIt() {
    #expect(AACWriter.bitRate(channels: 1) == 96_000)
    #expect(AACWriter.bitRate(channels: 2) == 256_000)
    #expect(DiskCheck.secondsLeft(freeBytes: 652_000_000, channels: [2, 1], elapsedSeconds: 0) == 1_000)
}
```

- [ ] **Step 2: Run, expect the failure**

Run: `scripts/test.sh > /tmp/dabber-test.log 2>&1; echo "exit=$?"; grep -E "stereoIsEncodedAt256k|failed" /tmp/dabber-test.log | head`
Expected: `stereoIsEncodedAt256kAndTheDiskEstimateUsesIt()` fails on `160000 == 256000` and on the estimate, non-zero exit.

- [ ] **Step 3: Implement and update the minutes**

In `Sources/DabberCore/Finalize/AACWriter.swift` replace
```swift
    public static func bitRate(channels: Int) -> Int { channels == 1 ? 96_000 : 160_000 }
```
with
```swift
    public static func bitRate(channels: Int) -> Int { channels == 1 ? 96_000 : 256_000 }
```
In `Tests/DabberCoreTests/SessionRecorderTests.swift` replace
```swift
        #expect(warned.diskWarning == "disk space low: about 19 min of recording left")
```
with
```swift
        #expect(warned.diskWarning == "disk space low: about 18 min of recording left")
```

- [ ] **Step 4: Run tests and build**

Run: `scripts/test.sh > /tmp/dabber-test.log 2>&1; echo "exit=$?"; tail -1 /tmp/dabber-test.log`, then `scripts/build-app.sh > /tmp/dabber-build.log 2>&1; echo "exit=$?"`.
Expected: `Test run with 219 tests ... passed`, `exit=0`; build `exit=0`.

- [ ] **Step 5: Check the bitrate on a real signal**

AAC on silence reads far below the target, so play quiet pink noise while recording computer audio:
```zsh
ffmpeg -v error -y -f lavfi -i "anoisesrc=color=pink:amplitude=0.3:duration=14" -ac 2 -ar 48000 /tmp/dabber-noise.wav
rm -rf build/rate-e2e
(sleep 1; afplay -v 0.2 /tmp/dabber-noise.wav) & scripts/run-headless.sh "$PWD/build/rate-e2e.log" --record --computer-audio --seconds 10 --out "$PWD/build/rate-e2e" > /tmp/rate-e2e.out 2>&1; echo "exit=$?"; wait
S=$(sed -n 's/^[0-9.]* NAMED //p' build/rate-e2e.log)
for f in "$S"/*.m4a; do echo "${f:t}: $(ffprobe -v error -select_streams a:0 -show_entries stream=channels,bit_rate -of csv=p=0 "$f")"; done
```
Expected: `exit=0`; both files `2,` followed by a bit rate near 256000 (within about 10 %).

- [ ] **Step 6: Commit**

```zsh
git add Sources/DabberCore/Finalize/AACWriter.swift Tests/DabberCoreTests/ManifestTests.swift Tests/DabberCoreTests/SessionRecorderTests.swift
git diff --cached --stat
git commit -m "feat: encode stereo tracks at 256 kbps"
```

---

### Task 11: Real recording during a calendar event (HUMAN)

**Files:**
- Create: `docs/spikes/2026-09-24-session-names-check.md`

- [ ] **Step 1: Record (HUMAN)**

Tell the user:
> In Calendar create an event "Планёрка: Q3/план" starting now (or in 5 min). Quit any running Dabber, run `open build/Dabber.app`.
> Press Record with something playing: allow calendar access in the prompt (recording starts after you answer). Is the Name field "Планёрка: Q3/план"?
> Mid-recording change the name to "Планёрка итоги", press Mark once, stop after about 30 s.
> Show last recording: folder and mix should be `2026-09-24 HH-mm Планёрка итоги` / `...Планёрка итоги.m4a`; open the mix in QuickTime (Window > Show Movie Inspector): title?
> Then record 10 s with no event running: date-only name, no error?

- [ ] **Step 2: Record the result and commit**

Write `docs/spikes/2026-09-24-session-names-check.md`: macOS version; prompt shown with the usage text yes/no; Name prefilled yes/no; folder and mix names as seen; QuickTime title; date-only session name; ffprobe `format_tags=title` of the mix. Every "no" is a finding to report to the user before anything else.
```zsh
git add docs/spikes/2026-09-24-session-names-check.md
git diff --cached --stat
git commit -m "docs: record session names check"
```

## After this plan

- If the Name field is empty although access was granted and an event is on: the lookup ran with a store created before the grant is visible, or the event is all-day / starts later than 15 min. Check `EKEventStore.authorizationStatus(for: .event)` first.
- If the first-Record delay under the permission prompt is a problem, the alternative is to start at once and apply the calendar title afterwards via `setTitle` (the rename at finalize already handles a changed title).
- Out of scope, from the spec: choosing among several events in the UI, renaming after the recording has finished, per-track file renaming.
