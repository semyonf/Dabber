# Dabber Marks and Chapters Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** While recording, a **Mark** button in the menu stores the exact moment it was pressed, with an optional comment typed afterwards. Marks are saved into `session.json` at once, so they survive a crash and reach crash recovery. On finalize they become chapters in every `.m4a` of the session (first chapter "Start" at 0:00, empty marks titled "Mark N"), plus a `marks.txt` next to the files. Headless `--mark-at` makes the whole path checkable with ffprobe.

**Architecture:**
- `Mark` (id, offset from the session start in nanoseconds, text) lives in `SessionManifest.marks`. The manifest owns add/set text/remove, so the rules are pure and unit-tested.
- `SessionRecorder` applies mark edits to its manifest under its lock and saves `session.json` after each one. It accepts marks only while `.recording`.
- `RecorderModel` reads the host clock first thing in `mark()` (injectable `clock`), then asks the engine to add the mark. It holds the comment draft and saves it on Enter, on the next Mark, on menu close and on Stop. The menu view only binds to it.
- `Chapters` turns marks into chapter entries (sort, clamp to the file, "Start" first, "Mark N") and into `marks.txt` lines.
- `ChapterWriter` rewrites a finished `.m4a` with Apple frameworks only: audio packets copied as they are (`AVAssetReader` passthrough into `AVAssetWriter`, no re-encode), plus a disabled `tx3g` text track linked from the audio track as its chapter list (`tref/chap`). `Finalizer` calls it for every track and the mix after they are verified, before the report is saved.

**Tech Stack:** Swift 6.4 with SwiftPM and Swift Testing, AVFoundation (`AVAssetReader`, `AVAssetWriter`, `AVMovie`), CoreMedia text format descriptions, SwiftUI `MenuBarExtra`, ffprobe.

Spec: `docs/superpowers/specs/2026-09-24-dabber-marks-design.md`. Format model: `docs/superpowers/plans/2026-09-23-dabber-3b-feed-and-menu.md`.

## Ground rules for implementers

- Repo root: the repository root. Branch `marks`. No remote. Never push.
- Commit messages: one line, `type: description`, no body, no trailers. `git add` by explicit path only; read `git diff --cached --stat` before every commit.
- Shell is zsh. Tests: `scripts/test.sh` only (bare `swift test` cannot find the Swift Testing macro plugin). Success means exit code 0 (`scripts/test.sh; echo "exit=$?"`), never grep for text. No Xcode, no `xcodebuild`. Never use `@State` or `@Bindable` (the SwiftUI macro plugin is not in the CLT toolchain; see Plan 1b); bind with `Binding(get:set:)` onto the model. This plan does not use `@FocusState` either (untested with the CLT toolchain).
- In zsh, `log` is a shell builtin. Always call `/usr/bin/log`.
- Hardware check: `scripts/build-app.sh`, then `scripts/run-headless.sh <log> <args>`. The log's last line must end in ` EXIT 0`. Task 6 records computer audio only: no mic, no beep.
- Code: English, no comments. KISS. Swift 6 language mode.
- Tasks marked **HUMAN** need the user. Stop there, tell the user exactly what to do in at most five short lines, and wait.
- Test counts below assume the baseline of `8b0530b`: **188 tests**. If `scripts/test.sh` reports a different baseline before Task 1, shift every expected count by the difference.

## Chapter format: spike result (2026-09-24)

Checked on this machine (macOS 26.6.2, Swift 6.4 CLT, ffmpeg 9.0.1) on a 30 s AAC 48 kHz stereo file written by `AVAudioFile` like `AACWriter` does, with chapters at 0:00 "Start", 0:10 "Mark 1", 0:20 "про деньги":

| | Apple frameworks (`AVAssetWriter`, chosen) | ffmpeg `-map_metadata 1 -codec copy` |
|---|---|---|
| ffprobe `-show_chapters` | 3 chapters, times and UTF-8 titles exact | same |
| `AVAsset` chapter groups | 3, locale `und` | 3, locale `und` |
| Chapter atoms | `tref/chap` on audio, disabled `tx3g` text track (`Core Media Text`) | `tref/chap` on audio, disabled QuickTime `text` track, **plus** Nero `udta/chpl` |
| Audio packets | identical (ffmpeg packet MD5 equal) | identical |
| Decoded frames (`AVAudioFile.length`) | 1,440,000, PCM equal to the source | 1,440,000, PCM equal to the source |
| Priming info | keeps `iTunSMPB`, no `elst` (as the source) | replaces `iTunSMPB` with `elst` + `sgpd roll` |

- A QuickTime `text` sample description is rejected by `AVAssetWriter` for `.m4a` (`finishWriting` fails with -12715); `tx3g` works.
- The text track's `mdhd` language is `und`. `loadChapterMetadataGroups(bestMatchingPreferredLanguages: ["en-US", "ru-RU"])` returns **no** chapters for both files; `["und"]` returns all three. Setting the text input's `languageCode = "en"` makes the preferred-language lookup find them. Whether QuickTime Player or iOS apply this lookup is what the human check answers; the test file `chapters-apple-en.m4a` covers that case.
- Rewriting a 2 h, 145 MB AAC file this way took 0.17 s (page cache warm).
- ffmpeg is not bundled with Dabber, and its extra `chpl` atom is what Nero-style players read. If the human check shows IINA or VLC need `chpl`, Task 4 needs a follow-up; the spike does not show that.

**Gate before Task 4:** The user checks the spike files in the spike's scratch folder (`chapters-apple.m4a`, `chapters-ffmpeg.m4a` as the reference, `chapters-apple-en.m4a`, `source.m4a` without chapters) in QuickTime Player, IINA or VLC, and iPhone Files. Tones change every chapter: 220, 440, 660 Hz. Task 4 starts only if `chapters-apple.m4a` shows its chapters wherever `chapters-ffmpeg.m4a` does. If the check has not happened yet, do Tasks 1-3 and stop.

## Facts checked for this plan

The complete code of this plan was applied task by task to a clone of `marks` at `8b0530b` outside the repo, one commit per task:
- `scripts/test.sh` exit 0 after every task, with 194, 195, 200, 201, 204, 204, 204 tests.
- `scripts/build-app.sh` built and signed it. The Task 6 command recorded 12 s of computer audio with `--mark-at 3 --mark-at "7:про деньги"`: log `MARK 1 at=3033 ms`, `MARK 2 at=7038 ms про деньги`, `FINALIZED ... EXIT 0`; ffprobe on `computer audio.m4a` and `mix.m4a` printed `0,Start`, `3033,Mark 1`, `7038,про деньги`; `marks.txt` was `00:00:03  Mark 1` / `00:00:07  про деньги`.
- Not checked: the menu on screen (Task 7 and Task 8), players other than ffprobe and AVFoundation (Task 8), a session with a mic track in the end-to-end run (unit tests cover a mic track).

## Decisions

- Mark time is the host clock at the press, stored as `offsetNanos` from `sessionStartNanos`. Frame 0 of every output file is `sessionStartNanos` (`Timeline.place`), so the offset is the position in the file. A press before the session start clamps to 0.
- "Mark N" numbers marks in the order they were made (the list order in the menu). Deleting a mark renumbers the ones after it.
- Chapters: "Start" at 0, then marks sorted by time, each clamped to `[0, duration - 1 ms]`. When two entries share a millisecond, the later one wins (so a mark at 0:00 replaces "Start").
- No marks means no chapter track and no `marks.txt`.
- `marks.txt` is written before the chapters, so it exists even when chapter writing fails. A chapter failure fails the finalize like any other finalize error: the file whose rewrite failed stays as it was, the CAFs stay, and recovery renders everything again on the next launch.
- Old `session.json` files without `marks` still load (an old unfinished session must still be recovered).

## File structure

```
Sources/DabberCore/Model/Mark.swift              Mark, Chapter, Chapters (chapter list, marks.txt text)
Sources/DabberCore/Model/SessionManifest.swift   (modify) marks, decoding without marks, add/set text/remove
Sources/DabberCore/Engine/SessionRecorder.swift  (modify) addMark/setMarkText/removeMark, saved at once
Sources/DabberCore/App/RecorderModel.swift       (modify) engine protocol, mark(), comment draft, list rows
Sources/DabberCore/Finalize/ChapterWriter.swift  passthrough rewrite with a tx3g chapter track
Sources/DabberCore/Finalize/Finalizer.swift      (modify) marks.txt and chapters for every m4a
Sources/Dabber/Headless.swift                    (modify) --record ... --mark-at <seconds>[:text]
Sources/Dabber/MenuApp.swift                     (modify) MarksView in the RECORDING section
Tests/DabberCoreTests/MarkTests.swift
Tests/DabberCoreTests/SessionRecorderTests.swift (modify)
Tests/DabberCoreTests/RecorderModelTests.swift   (modify)
Tests/DabberCoreTests/FinalizerTests.swift       (modify)
docs/spikes/2026-09-24-chapters-players.md
```

---

### Task 1: Mark model and manifest (pure, TDD)

**Files:**
- Create: `Sources/DabberCore/Model/Mark.swift`, `Tests/DabberCoreTests/MarkTests.swift`
- Modify: `Sources/DabberCore/Model/SessionManifest.swift`

- [ ] **Step 1: Write the failing tests `Tests/DabberCoreTests/MarkTests.swift`**

```swift
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
```

- [ ] **Step 2: Run, expect compile failure**

Run: `scripts/test.sh; echo "exit=$?"`
Expected: `cannot find 'Mark' in scope` (and `Chapter`, `Chapters`), non-zero exit.

- [ ] **Step 3: Write `Sources/DabberCore/Model/Mark.swift`**

```swift
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
```

- [ ] **Step 4: Add marks to `SessionManifest`**

In `Sources/DabberCore/Model/SessionManifest.swift` replace
```swift
    public var sources: [SourceManifest] = []
    public var finalize: FinalizeReport?

    public init(appVersion: String, startedAt: Date, sessionStartNanos: UInt64) {
        self.appVersion = appVersion
        self.startedAt = startedAt
        self.sessionStartNanos = sessionStartNanos
    }
```
with
```swift
    public var sources: [SourceManifest] = []
    public var marks: [Mark] = []
    public var finalize: FinalizeReport?

    public init(appVersion: String, startedAt: Date, sessionStartNanos: UInt64) {
        self.appVersion = appVersion
        self.startedAt = startedAt
        self.sessionStartNanos = sessionStartNanos
    }

    private enum CodingKeys: String, CodingKey { case appVersion, startedAt, sessionStartNanos, sources, marks, finalize }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        appVersion = try c.decode(String.self, forKey: .appVersion)
        startedAt = try c.decode(Date.self, forKey: .startedAt)
        sessionStartNanos = try c.decode(UInt64.self, forKey: .sessionStartNanos)
        sources = try c.decode([SourceManifest].self, forKey: .sources)
        marks = try c.decodeIfPresent([Mark].self, forKey: .marks) ?? []
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
```

- [ ] **Step 5: Run tests**

Run: `scripts/test.sh; echo "exit=$?"`
Expected: `Test run with 194 tests ... passed`, `exit=0`.

- [ ] **Step 6: Commit**

```zsh
git add Sources/DabberCore/Model/Mark.swift Sources/DabberCore/Model/SessionManifest.swift Tests/DabberCoreTests/MarkTests.swift
git diff --cached --stat
git commit -m "feat: add marks to the session manifest"
```

---

### Task 2: Marks saved to `session.json` while recording (TDD)

**Files:**
- Modify: `Sources/DabberCore/Engine/SessionRecorder.swift`, `Tests/DabberCoreTests/SessionRecorderTests.swift`

Every edit goes through the recorder's own manifest copy under its lock. `segmentsChanged` and `stop()` save that same copy, so they keep the marks. After `stop()` sets the phase to `.stopping`, edits return `[]` and change nothing.

- [ ] **Step 1: Write the failing test**

In `Tests/DabberCoreTests/SessionRecorderTests.swift` replace
```swift
    @Test func stopWithoutStartReturnsNil() throws {
```
with
```swift
    @Test func marksAreSavedToTheManifestAtOnce() throws {
        let (r, _) = try recorder()
        let dir = try r.start(specs: specs)
        let start = try SessionManifest.load(from: dir).sessionStartNanos
        #expect(r.addMark(atNanos: start + 2_000_000_000) == [Mark(id: 1, offsetNanos: 2_000_000_000)])
        #expect(try SessionManifest.load(from: dir).marks == [Mark(id: 1, offsetNanos: 2_000_000_000)])
        r.addMark(atNanos: start + 3_000_000_000)
        r.setMarkText(id: 1, "про деньги")
        #expect(r.removeMark(id: 2) == [Mark(id: 1, offsetNanos: 2_000_000_000, text: "про деньги")])
        #expect(try SessionManifest.load(from: dir).marks == [Mark(id: 1, offsetNanos: 2_000_000_000, text: "про деньги")])
        _ = r.stop()
        #expect(try SessionManifest.load(from: dir).marks == [Mark(id: 1, offsetNanos: 2_000_000_000, text: "про деньги")])
        #expect(r.addMark(atNanos: start + 4_000_000_000).isEmpty)
        #expect(try SessionManifest.load(from: dir).marks.count == 1)
    }

    @Test func stopWithoutStartReturnsNil() throws {
```

- [ ] **Step 2: Run, expect compile failure**

Run: `scripts/test.sh; echo "exit=$?"`
Expected: `value of type 'SessionRecorder' has no member 'addMark'`, non-zero exit.

- [ ] **Step 3: Implement**

In `Sources/DabberCore/Engine/SessionRecorder.swift` replace
```swift
    public func status(at now: Date = Date()) -> RecorderStatus {
```
with
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

    public func status(at now: Date = Date()) -> RecorderStatus {
```

- [ ] **Step 4: Run tests**

Run: `scripts/test.sh; echo "exit=$?"`
Expected: `Test run with 195 tests ... passed`, `exit=0`.

- [ ] **Step 5: Commit**

```zsh
git add Sources/DabberCore/Engine/SessionRecorder.swift Tests/DabberCoreTests/SessionRecorderTests.swift
git diff --cached --stat
git commit -m "feat: save marks to session.json while recording"
```

---

### Task 3: Mark, comment and remove in `RecorderModel` (TDD)

**Files:**
- Modify: `Sources/DabberCore/App/RecorderModel.swift`, `Tests/DabberCoreTests/RecorderModelTests.swift`

`mark()` reads the clock before anything else, so typing the comment later cannot move the mark. The draft is saved on Enter (`saveComment()`), on the next Mark, on menu close and before Stop. When the engine reports `.idle`, `tick()` clears the list.

- [ ] **Step 1: Give the fake engine marks**

In `Tests/DabberCoreTests/RecorderModelTests.swift` replace
```swift
    func status(at now: Date) -> RecorderStatus {
```
with
```swift
    var manifest = SessionManifest(appVersion: "t", startedAt: Date(), sessionStartNanos: 1_000_000_000)

    func addMark(atNanos: UInt64) -> [Mark] { editMarks { $0.addMark(atNanos: atNanos) } }
    func setMarkText(id: Int, _ text: String) -> [Mark] { editMarks { $0.setMarkText(id: id, text) } }
    func removeMark(id: Int) -> [Mark] { editMarks { $0.removeMark(id: id) } }

    private func editMarks(_ edit: (inout SessionManifest) -> Void) -> [Mark] {
        guard phase == .recording else { return [] }
        edit(&manifest)
        return manifest.marks
    }

    func status(at now: Date) -> RecorderStatus {
```

- [ ] **Step 2: Append the failing tests to `Tests/DabberCoreTests/RecorderModelTests.swift`**

```swift
private final class FakeHostClock: @unchecked Sendable {
    var now: UInt64 = 1_000_000_000
}

@MainActor
private func markModel(_ engine: FakeEngine, _ clock: FakeHostClock) async -> RecorderModel {
    let m = RecorderModel(
        engine: engine, catalog: FakeCatalog(devices: [airpods]), enabledIDs: ["computer"], persist: { _ in },
        finalize: { _ in }, clock: { clock.now })
    m.refreshDevices()
    await m.startStop()
    return m
}

@MainActor @Test func markTakesThePressTimeAndTheCommentDoesNotMoveIt() async {
    let e = FakeEngine()
    let clock = FakeHostClock()
    let m = await markModel(e, clock)
    #expect(m.canMark)
    clock.now = 6_000_000_000
    m.mark()
    #expect(m.marks == [Mark(id: 1, offsetNanos: 5_000_000_000)])
    #expect(m.editingMarkID == 1)
    #expect(m.markRows == [RecorderModel.MarkRow(id: 1, time: "0:05", title: "Mark 1")])
    clock.now = 9_000_000_000
    m.draft = "про деньги"
    m.saveComment()
    #expect(m.marks == [Mark(id: 1, offsetNanos: 5_000_000_000, text: "про деньги")])
    #expect(m.editingMarkID == nil)
    #expect(m.draft == "")
    #expect(e.manifest.marks == m.marks)
}

@MainActor @Test func nextMarkSavesTheOpenCommentFirst() async {
    let e = FakeEngine()
    let clock = FakeHostClock()
    let m = await markModel(e, clock)
    clock.now = 2_000_000_000
    m.mark()
    m.draft = "first"
    clock.now = 3_000_000_000
    m.mark()
    #expect(m.markRows.map(\.title) == ["first", "Mark 2"])
    #expect(m.editingMarkID == 2)
}

@MainActor @Test func removingAMarkDropsItsOpenComment() async {
    let e = FakeEngine()
    let m = await markModel(e, FakeHostClock())
    m.mark()
    m.draft = "gone"
    m.removeMark(1)
    #expect(m.marks.isEmpty)
    #expect(m.editingMarkID == nil)
    #expect(m.draft == "")
    #expect(e.manifest.marks.isEmpty)
}

@MainActor @Test func closingTheMenuSavesTheOpenComment() async {
    let e = FakeEngine()
    let m = await markModel(e, FakeHostClock())
    m.mark()
    m.draft = "typed"
    m.menuClosed()
    #expect(e.manifest.marks.map(\.text) == ["typed"])
}

@MainActor @Test func stopSavesTheOpenCommentAndClearsTheList() async {
    let e = FakeEngine()
    let m = await markModel(e, FakeHostClock())
    m.mark()
    m.draft = "last words"
    await m.startStop()
    #expect(e.manifest.marks.map(\.text) == ["last words"])
    #expect(m.marks.isEmpty)
    #expect(m.editingMarkID == nil)
    #expect(!m.canMark)
    m.mark()
    #expect(e.manifest.marks.count == 1)
}
```

- [ ] **Step 3: Run, expect compile failure**

Run: `scripts/test.sh; echo "exit=$?"`
Expected: `extra argument 'clock' in call` and `value of type 'RecorderModel' has no member 'draft'`, non-zero exit.

- [ ] **Step 4: Implement in `Sources/DabberCore/App/RecorderModel.swift`**

Make these replacements, in order.

1. Replace
```swift
    var lastSessionDir: URL? { get }
}
```
with
```swift
    var lastSessionDir: URL? { get }
    func addMark(atNanos: UInt64) -> [Mark]
    func setMarkText(id: Int, _ text: String) -> [Mark]
    func removeMark(id: Int) -> [Mark]
}
```
`SessionRecorder` already has these three methods (Task 2), so its conformance needs no change.

2. Replace
```swift
    nonisolated public static let computerID = "computer"
```
with
```swift
    public struct MarkRow: Identifiable, Equatable, Sendable {
        public let id: Int
        public let time: String
        public let title: String
    }

    nonisolated public static let computerID = "computer"
```

3. Replace
```swift
    public private(set) var finalizing = false
```
with
```swift
    public private(set) var finalizing = false
    public private(set) var marks: [Mark] = []
    public private(set) var editingMarkID: Int?
    public var draft = ""
```

4. Replace
```swift
    private let finalize: @Sendable (URL) throws -> Void
```
with
```swift
    private let finalize: @Sendable (URL) throws -> Void
    private let clock: @Sendable () -> UInt64
```

5. Replace
```swift
        finalize: @escaping @Sendable (URL) throws -> Void = { try Finalizer.run($0) }
    ) {
```
with
```swift
        finalize: @escaping @Sendable (URL) throws -> Void = { try Finalizer.run($0) },
        clock: @escaping @Sendable () -> UInt64 = HostClock.nowNanos
    ) {
```

6. Replace
```swift
        self.finalize = finalize
        lastSessionDir = engine.lastSessionDir
```
with
```swift
        self.finalize = finalize
        self.clock = clock
        lastSessionDir = engine.lastSessionDir
```

7. Replace
```swift
    public var canStartStop: Bool { !finalizing && !starting && (isRecording || rows.contains(where: \.enabled)) }
```
with
```swift
    public var canStartStop: Bool { !finalizing && !starting && (isRecording || rows.contains(where: \.enabled)) }
    public var canMark: Bool { phase == .recording && !finalizing }
    public var markRows: [MarkRow] {
        marks.enumerated().map { i, m in MarkRow(id: m.id, time: Self.format(seconds: m.seconds), title: m.title(number: i + 1)) }
    }

    public func mark() {
        let now = clock()
        guard canMark else { return }
        saveComment()
        marks = engine.addMark(atNanos: now)
        editingMarkID = marks.last?.id
    }

    public func saveComment() {
        guard let id = editingMarkID else { return }
        marks = engine.setMarkText(id: id, draft)
        editingMarkID = nil
        draft = ""
    }

    public func removeMark(_ id: Int) {
        if editingMarkID == id {
            editingMarkID = nil
            draft = ""
        }
        marks = engine.removeMark(id: id)
    }
```

8. Replace
```swift
    public func stopAndFinalize() async {
        finalizing = true
```
with
```swift
    public func stopAndFinalize() async {
        saveComment()
        finalizing = true
```

9. Replace
```swift
    public func menuClosed() {
        guard warning != nil else { return }
```
with
```swift
    public func menuClosed() {
        saveComment()
        guard warning != nil else { return }
```

10. Replace
```swift
        if status.phase == .idle, !sessionMics.isEmpty {
```
with
```swift
        if status.phase == .idle, !marks.isEmpty || editingMarkID != nil {
            marks = []
            editingMarkID = nil
            draft = ""
        }
        if status.phase == .idle, !sessionMics.isEmpty {
```

- [ ] **Step 5: Run tests**

Run: `scripts/test.sh; echo "exit=$?"`
Expected: `Test run with 200 tests ... passed`, `exit=0`.

- [ ] **Step 6: Commit**

```zsh
git add Sources/DabberCore/App/RecorderModel.swift Tests/DabberCoreTests/RecorderModelTests.swift
git diff --cached --stat
git commit -m "feat: mark, comment and remove marks in the recorder model"
```

---

### Task 4: Chapter writer without re-encoding (TDD)

Check the gate in "Chapter format: spike result" first.

**Files:**
- Create: `Sources/DabberCore/Finalize/ChapterWriter.swift`
- Modify: `Tests/DabberCoreTests/FinalizerTests.swift`

How it works, all verified in the spike and the scratch run:
- `AVMovie(url:).tracks` is a synchronous, non-deprecated way to get the audio track, so `Finalizer.run` stays synchronous.
- The reader output has `outputSettings: nil` (compressed packets as they are). The first packet's format description is the writer's `sourceFormatHint`.
- The chapter input is `.text` with a `tx3g` format description (`kCMTextFormatType_3GText`); each sample is a 2-byte big-endian length plus UTF-8 text. `kCMTextFormatType_QTText` makes `finishWriting` fail with -12715 in `.m4a`.
- Both inputs are fed through `requestMediaDataWhenReady`. Appending all chapter samples first and then the audio on one thread hangs: the writer interleaves and stops taking text until audio catches up.
- The new file is written into an `itemReplacementDirectory` on the same volume, its `AVAudioFile.length` must equal the original's, then `replaceItemAt` swaps it in. On any failure the original file stays untouched.

- [ ] **Step 1: Append the failing test to `Tests/DabberCoreTests/FinalizerTests.swift`**

```swift
private func chapterList(_ url: URL) async throws -> [String] {
    let groups = try await AVURLAsset(url: url).loadChapterMetadataGroups(bestMatchingPreferredLanguages: ["und"])
    var result: [String] = []
    for g in groups {
        let title = try await g.items.first?.load(.stringValue) ?? ""
        result.append(String(format: "%.3f ", g.timeRange.start.seconds) + title)
    }
    return result
}

private func pcm(_ url: URL) throws -> [Float] {
    let f = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: true)
    let buf = AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: AVAudioFrameCount(f.length))!
    try f.read(into: buf)
    return Array(UnsafeBufferPointer(start: buf.floatChannelData![0], count: Int(buf.frameLength) * Int(f.processingFormat.channelCount)))
}

@Test func chapterWriterKeepsTheAudioBitExact() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ch-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let url = dir.appendingPathComponent("a.m4a")
    let writer = try AACWriter(url: url, channels: 2)
    try writer.write(sine(frames: 100_000, channels: 2))
    try writer.closeAndVerify()
    let before = try pcm(url)
    try ChapterWriter.write([Chapter(startMillis: 0, title: "Start"), Chapter(startMillis: 1_000, title: "про деньги")], into: url)
    #expect(try AVAudioFile(forReading: url).length == 100_000)
    #expect(try pcm(url) == before)
    #expect(try await chapterList(url) == ["0.000 Start", "1.000 про деньги"])
    #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path) == ["a.m4a"])
}

```

- [ ] **Step 2: Run, expect compile failure**

Run: `scripts/test.sh; echo "exit=$?"`
Expected: `cannot find 'ChapterWriter' in scope`, non-zero exit.

- [ ] **Step 3: Write `Sources/DabberCore/Finalize/ChapterWriter.swift`**

```swift
import AVFoundation
import CoreMedia

public enum ChapterError: Error, CustomStringConvertible {
    case noAudio(String)
    case format(OSStatus)
    case write(String, String)

    public var description: String {
        switch self {
        case .noAudio(let file): return "\(file): no audio to add chapters to"
        case .format(let status): return "chapter format: \(status)"
        case .write(let file, let why): return "\(file): writing chapters failed: \(why)"
        }
    }
}

public enum ChapterWriter {
    public static func write(_ chapters: [Chapter], into url: URL) throws {
        let name = url.lastPathComponent
        let frames = try AVAudioFile(forReading: url).length
        let movie = AVMovie(url: url)
        guard let track = movie.tracks.first(where: { $0.mediaType == .audio }) else { throw ChapterError.noAudio(name) }
        let reader = try AVAssetReader(asset: movie)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        reader.add(output)
        guard reader.startReading(), let first = output.copyNextSampleBuffer(), let audioFormat = first.formatDescription else {
            throw ChapterError.noAudio(name)
        }
        let temp = try FileManager.default.url(
            for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: url, create: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        let out = temp.appendingPathComponent(name)
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
        guard writer.startWriting() else { throw ChapterError.write(name, "\(writer.error.map { "\($0)" } ?? "start")") }
        writer.startSession(atSourceTime: .zero)
        let feed = Feed(audio: audio, text: text, output: output, first: first, samples: samples)
        guard feed.run() else {
            writer.cancelWriting()
            throw ChapterError.write(name, "timed out")
        }
        writer.endSession(atSourceTime: end)
        let done = DispatchSemaphore(value: 0)
        writer.finishWriting { done.signal() }
        done.wait()
        guard writer.status == .completed, reader.status == .completed else {
            throw ChapterError.write(name, "\(writer.error ?? reader.error.map { $0 as any Error } ?? ChapterError.noAudio(name))")
        }
        let written = try AVAudioFile(forReading: out).length
        guard written == frames else {
            throw FinalizeError.lengthMismatch(file: name, expected: Int(frames), actual: Int(written))
        }
        _ = try FileManager.default.replaceItemAt(url, withItemAt: out)
    }

    private final class Feed: @unchecked Sendable {
        let audio: AVAssetWriterInput
        let text: AVAssetWriterInput
        let output: AVAssetReaderTrackOutput
        var first: CMSampleBuffer?
        var samples: [CMSampleBuffer]
        let group = DispatchGroup()

        init(audio: AVAssetWriterInput, text: AVAssetWriterInput, output: AVAssetReaderTrackOutput,
             first: CMSampleBuffer, samples: [CMSampleBuffer]) {
            self.audio = audio
            self.text = text
            self.output = output
            self.first = first
            self.samples = samples
        }

        func run() -> Bool {
            group.enter()
            group.enter()
            text.requestMediaDataWhenReady(on: DispatchQueue(label: "dabber.chapters.text")) { self.feedText() }
            audio.requestMediaDataWhenReady(on: DispatchQueue(label: "dabber.chapters.audio")) { self.feedAudio() }
            return group.wait(timeout: .now() + 600) == .success
        }

        private func feedText() {
            while text.isReadyForMoreMediaData {
                guard !samples.isEmpty, text.append(samples.removeFirst()) else { return finish(text) }
            }
        }

        private func feedAudio() {
            while audio.isReadyForMoreMediaData {
                let next = first ?? output.copyNextSampleBuffer()
                first = nil
                guard let next, audio.append(next) else { return finish(audio) }
            }
        }

        private func finish(_ input: AVAssetWriterInput) {
            input.markAsFinished()
            group.leave()
        }
    }

    private static func sample(_ title: String, start: CMTime, duration: CMTime, format: CMFormatDescription) throws -> CMSampleBuffer {
        let bytes = Array(title.utf8)
        let data = [UInt8(bytes.count >> 8 & 0xff), UInt8(bytes.count & 0xff)] + bytes
        var block: CMBlockBuffer?
        var status = CMBlockBufferCreateWithMemoryBlock(
            allocator: nil, memoryBlock: nil, blockLength: data.count, blockAllocator: nil, customBlockSource: nil,
            offsetToData: 0, dataLength: data.count, flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block)
        guard status == noErr, let block else { throw ChapterError.format(status) }
        status = data.withUnsafeBytes {
            CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: data.count)
        }
        guard status == noErr else { throw ChapterError.format(status) }
        var timing = CMSampleTimingInfo(duration: duration, presentationTimeStamp: start, decodeTimeStamp: .invalid)
        var size = data.count
        var sample: CMSampleBuffer?
        status = CMSampleBufferCreateReady(
            allocator: nil, dataBuffer: block, formatDescription: format, sampleCount: 1, sampleTimingEntryCount: 1,
            sampleTimingArray: &timing, sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sample)
        guard status == noErr, let sample else { throw ChapterError.format(status) }
        return sample
    }

    private static func textFormat() throws -> CMFormatDescription {
        let white: [CFString: Any] = [
            kCMTextFormatDescriptionColor_Red: 255, kCMTextFormatDescriptionColor_Green: 255,
            kCMTextFormatDescriptionColor_Blue: 255, kCMTextFormatDescriptionColor_Alpha: 255,
        ]
        let clear: [CFString: Any] = [
            kCMTextFormatDescriptionColor_Red: 0, kCMTextFormatDescriptionColor_Green: 0,
            kCMTextFormatDescriptionColor_Blue: 0, kCMTextFormatDescriptionColor_Alpha: 0,
        ]
        let extensions: [CFString: Any] = [
            kCMTextFormatDescriptionExtension_DisplayFlags: 0,
            kCMTextFormatDescriptionExtension_HorizontalJustification: 1,
            kCMTextFormatDescriptionExtension_VerticalJustification: -1,
            kCMTextFormatDescriptionExtension_BackgroundColor: clear,
            kCMTextFormatDescriptionExtension_DefaultTextBox: [
                kCMTextFormatDescriptionRect_Top: 0, kCMTextFormatDescriptionRect_Left: 0,
                kCMTextFormatDescriptionRect_Bottom: 0, kCMTextFormatDescriptionRect_Right: 0,
            ] as [CFString: Any],
            kCMTextFormatDescriptionExtension_DefaultStyle: [
                kCMTextFormatDescriptionStyle_StartChar: 0, kCMTextFormatDescriptionStyle_EndChar: 0,
                kCMTextFormatDescriptionStyle_Font: 1, kCMTextFormatDescriptionStyle_FontFace: 0,
                kCMTextFormatDescriptionStyle_FontSize: 18, kCMTextFormatDescriptionStyle_ForegroundColor: white,
            ] as [CFString: Any],
            kCMTextFormatDescriptionExtension_FontTable: ["1": "Sans-Serif"],
        ]
        var format: CMFormatDescription?
        let status = CMFormatDescriptionCreate(
            allocator: nil, mediaType: kCMMediaType_Text, mediaSubType: kCMTextFormatType_3GText,
            extensions: extensions as CFDictionary, formatDescriptionOut: &format)
        guard status == noErr, let format else { throw ChapterError.format(status) }
        return format
    }
}
```

- [ ] **Step 4: Run tests**

Run: `scripts/test.sh; echo "exit=$?"`
Expected: `Test run with 201 tests ... passed`, `exit=0`.

- [ ] **Step 5: Commit**

```zsh
git add Sources/DabberCore/Finalize/ChapterWriter.swift Tests/DabberCoreTests/FinalizerTests.swift
git diff --cached --stat
git commit -m "feat: write chapters into an m4a without re-encoding"
```

---

### Task 5: Finalize marks into chapters and `marks.txt` (TDD)

**Files:**
- Modify: `Sources/DabberCore/Finalize/Finalizer.swift`, `Tests/DabberCoreTests/FinalizerTests.swift`

Chapters are written after every file is verified and before the report is saved. A crash in between leaves `finalize == nil`, so recovery renders everything again, marks included.

- [ ] **Step 1: Append the failing tests to `Tests/DabberCoreTests/FinalizerTests.swift`**

```swift
@Test func marksBecomeChaptersInEveryFileAndMarksText() async throws {
    let dir = try makeSession()
    var m = try SessionManifest.load(from: dir)
    m.addMark(atNanos: m.sessionStartNanos + 2_500_000_000)
    m.addMark(atNanos: m.sessionStartNanos + 1_000_000_000)
    m.setMarkText(id: 2, "про деньги")
    try m.save(to: dir)
    try Finalizer.run(dir)
    let names = try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()
    #expect(names == ["computer audio.m4a", "marks.txt", "mic - A.m4a", "mix.m4a", "session.json"])
    for n in ["computer audio.m4a", "mic - A.m4a", "mix.m4a"] {
        let url = dir.appendingPathComponent(n)
        #expect(try await chapterList(url) == ["0.000 Start", "1.000 про деньги", "2.500 Mark 1"], "\(n)")
        #expect(try AVAudioFile(forReading: url).length == 144_000, "\(n)")
    }
    let text = try String(contentsOf: dir.appendingPathComponent("marks.txt"), encoding: .utf8)
    #expect(text == "00:00:01  про деньги\n00:00:02  Mark 1\n")
}

@Test func recoveryKeepsTheMarks() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("rec-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let pending = root.appendingPathComponent("pending")
    try FileManager.default.moveItem(at: try makeSession(), to: pending)
    var m = try SessionManifest.load(from: pending)
    m.addMark(atNanos: m.sessionStartNanos + 2_000_000_000)
    try m.save(to: pending)
    #expect(try Finalizer.recoverAll(root: root).map(\.path) == [pending.path])
    #expect(try await chapterList(pending.appendingPathComponent("mix.m4a")) == ["0.000 Start", "2.000 Mark 1"])
    #expect(try SessionManifest.load(from: pending).marks.count == 1)
}

@Test func sessionWithoutMarksGetsNoChapters() async throws {
    let dir = try makeSession()
    try Finalizer.run(dir)
    #expect(try await chapterList(dir.appendingPathComponent("mix.m4a")).isEmpty)
    #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("marks.txt").path))
}
```

- [ ] **Step 2: Run, expect failures**

Run: `scripts/test.sh; echo "exit=$?"`
Expected: `marksBecomeChaptersInEveryFileAndMarksText` and `recoveryKeepsTheMarks` fail (no chapters, no `marks.txt`), non-zero exit.

- [ ] **Step 3: Implement**

In `Sources/DabberCore/Finalize/Finalizer.swift` replace
```swift
        for writer in writers { try writer.closeAndVerify() }
        try mix.closeAndVerify()
```
with
```swift
        for writer in writers { try writer.closeAndVerify() }
        try mix.closeAndVerify()
        if !manifest.marks.isEmpty, total > 0 {
            let millis = total * 1000 / Timeline.rate
            try Chapters.text(manifest.marks, durationMillis: millis)
                .write(to: dir.appendingPathComponent(Chapters.textFile), atomically: true, encoding: .utf8)
            let chapters = Chapters.make(manifest.marks, durationMillis: millis)
            for writer in writers + [mix] { try ChapterWriter.write(chapters, into: writer.url) }
        }
```

- [ ] **Step 4: Run tests**

Run: `scripts/test.sh; echo "exit=$?"`
Expected: `Test run with 204 tests ... passed`, `exit=0`.

- [ ] **Step 5: Commit**

```zsh
git add Sources/DabberCore/Finalize/Finalizer.swift Tests/DabberCoreTests/FinalizerTests.swift
git diff --cached --stat
git commit -m "feat: finalize marks into chapters and marks.txt"
```

---

### Task 6: Headless `--mark-at` and the end-to-end check (automated)

**Files:**
- Modify: `Sources/Dabber/Headless.swift`

`--mark-at <seconds>[:text]` can repeat. The record loop ticks once a second; at the first tick at or after `<seconds>` it adds a mark at the current host time, sets the text and logs `MARK <id> at=<ms> ms <text>`. The logged milliseconds are the chapter start in the files.

- [ ] **Step 1: Parse the option**

In `Sources/Dabber/Headless.swift`, in the `--record` case, replace
```swift
            var seconds = 0.0
            var root = AppPaths.recordingsRoot
```
with
```swift
            var seconds = 0.0
            var marks: [(at: Double, text: String)] = []
            var root = AppPaths.recordingsRoot
```
and replace
```swift
                    root = URL(fileURLWithPath: args[i])
                default:
```
with
```swift
                    root = URL(fileURLWithPath: args[i])
                case "--mark-at":
                    i += 1
                    guard i < args.count else { return 64 }
                    let parts = args[i].split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
                    guard let at = Double(parts[0]) else { return 64 }
                    marks.append((at, parts.count > 1 ? String(parts[1]) : ""))
                default:
```

- [ ] **Step 2: Add the marks during the loop**

Replace
```swift
            log.line("SESSION \(dir.path)")
            let end = Date().addingTimeInterval(seconds)
```
with
```swift
            log.line("SESSION \(dir.path)")
            var pending = marks.sorted { $0.at < $1.at }
            let end = Date().addingTimeInterval(seconds)
```
and replace
```swift
                if status.phase != .recording {
                    log.line("ERROR recording stopped: \(status.lastError ?? "unknown")")
                    break
                }
            }
```
with
```swift
                if status.phase != .recording {
                    log.line("ERROR recording stopped: \(status.lastError ?? "unknown")")
                    break
                }
                while let mark = pending.first, status.elapsedSeconds >= mark.at {
                    pending.removeFirst()
                    let id = recorder.addMark(atNanos: HostClock.nowNanos()).last?.id ?? 0
                    if let m = recorder.setMarkText(id: id, mark.text).last {
                        log.line("MARK \(m.id) at=\(m.offsetNanos / 1_000_000) ms \(m.text)")
                    }
                }
            }
```

- [ ] **Step 3: Tests and build**

Run: `scripts/test.sh; echo "exit=$?"`, then `scripts/build-app.sh`.
Expected: `Test run with 204 tests ... passed`, `exit=0`; the build prints the `designated => identifier "local.dabber.Dabber"` line.

- [ ] **Step 4: Record 12 s of computer audio with two marks**

Run:
```zsh
rm -rf build/marks-e2e
scripts/run-headless.sh "$PWD/build/marks-e2e.log" --record --computer-audio --seconds 12 --mark-at 3 --mark-at "7:про деньги" --out "$PWD/build/marks-e2e" | grep -E "MARK|FINALIZED|EXIT"
```
Expected: `MARK 1 at=30xx ms `, `MARK 2 at=70xx ms про деньги`, `FINALIZED total=... gaps=... resampled=0`, `EXIT 0`.

- [ ] **Step 5: Check the chapters with ffprobe**

Run:
```zsh
S=$(dirname build/marks-e2e/*/session.json)
want=$(printf '0,Start\n%s,Mark 1\n%s,про деньги' $(grep -o 'MARK [0-9] at=[0-9]*' build/marks-e2e.log | sed 's/.*at=//'))
for f in "$S"/*.m4a; do
  got=$(ffprobe -v error -show_entries chapter=start:chapter_tags=title -of csv=p=0 "$f")
  [[ "$got" == "$want" ]] && echo "OK ${f:t}" || echo "FAIL ${f:t}: $got"
done
cat "$S/marks.txt"
```
Expected: `OK computer audio.m4a`, `OK mix.m4a`, then `00:00:03  Mark 1` and `00:00:07  про деньги`. A `FAIL` line is a bug: stop and report it with the ffprobe output.

- [ ] **Step 6: Commit**

```zsh
git add Sources/Dabber/Headless.swift
git diff --cached --stat
git commit -m "feat: add --mark-at to headless recording"
```

---

### Task 7: Mark button and marks list in the menu

**Files:**
- Modify: `Sources/Dabber/MenuApp.swift`

A thin view over `RecorderModel`: every action is one model call, and the comment field binds with `Binding(get:set:)`. It shows only while recording.

- [ ] **Step 1: Add `MarksView`**

In `Sources/Dabber/MenuApp.swift` replace
```swift
            if let warning = model.warning {
                Label(warning, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
```
with
```swift
            if model.isRecording { MarksView(model: model) }
            if let warning = model.warning {
                Label(warning, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
```
and replace
```swift
struct VirtualMicSection: View {
```
with
```swift
struct MarksView: View {
    let model: RecorderModel

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button("Mark") { model.mark() }
                .disabled(!model.canMark)
            if model.editingMarkID != nil {
                TextField("Comment (optional)", text: Binding(get: { model.draft }, set: { model.draft = $0 }))
                    .onSubmit { model.saveComment() }
            }
            ForEach(model.markRows) { row in
                HStack(spacing: 6) {
                    Text(row.time).monospacedDigit().foregroundStyle(.secondary)
                    Text(row.title).lineLimit(1)
                    Spacer()
                    Button { model.removeMark(row.id) } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.borderless)
                }
                .font(.caption)
            }
        }
    }
}

struct VirtualMicSection: View {
```

- [ ] **Step 2: Tests and build**

Run: `scripts/test.sh; echo "exit=$?"`, then `scripts/build-app.sh`.
Expected: `Test run with 204 tests ... passed`, `exit=0`; the build prints the designated line.

- [ ] **Step 3: Commit**

```zsh
git add Sources/Dabber/MenuApp.swift
git diff --cached --stat
git commit -m "feat: add Mark button and marks list to the menu"
```

---

### Task 8: Real session in the players (HUMAN)

**Files:**
- Create: `docs/spikes/2026-09-24-chapters-players.md`

- [ ] **Step 1: Record and play (HUMAN)**

Tell the user:
> Quit any running Dabber, run `open build/Dabber.app`, start a recording with something playing on the Mac.
> Press Mark three times about 20 s apart: type "про деньги" + Enter for the first, leave the second empty, type something for the third and close the menu without Enter. Remove nothing. Stop after about a minute.
> In Finder (Show last recording) check `marks.txt`, then open `mix.m4a` in QuickTime Player (View > Show Chapters or the chapter popup), and in IINA or VLC (chapter list). Copy `mix.m4a` to iCloud Drive and open it on the iPhone in Files.
> For each player: are there 4 chapters (Start, про деньги, Mark 2, your third text), and does picking one jump to the right place?
> Also: did the comment field take typing right after Mark, or did you have to click it first?

- [ ] **Step 2: Record the result and commit**

Write `docs/spikes/2026-09-24-chapters-players.md`: macOS and iOS versions, per player chapters yes/no, titles correct yes/no (Cyrillic), jumps yes/no; the comment-field focus answer; the ffprobe output of `mix.m4a` (`ffprobe -v error -show_entries chapter=start:chapter_tags=title -of csv=p=0 <path>`). Every "no" is a finding to report to the user before anything else.
```zsh
git add docs/spikes/2026-09-24-chapters-players.md
git diff --cached --stat
git commit -m "docs: record chapter check in the players"
```

## After this plan

- If a player shows no chapters but ffprobe does, the next things to try, in order: text track `languageCode = "en"` (the spike file `chapters-apple-en.m4a` tests it), then a Nero `chpl` atom in `udta` (what ffmpeg adds).
- If the comment field does not take focus after Mark, that needs focus handling without `@FocusState` (an AppKit first-responder call); not in this plan.
- Out of scope, from the spec: global hotkey, editing mark times, marks in the virtual mic, pre-roll offset.
