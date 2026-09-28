# Dabber Mark Hotkey Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** While recording, a quick double tap of the right Option key makes a mark, like the Mark button, with a short sound. It needs Input Monitoring; without it everything works as before and the menu says how to allow it.

**Architecture:** A pure `DoubleTap` detector (DabberCore, tested) turns key events into a fire. `RecorderModel` owns an optional `MarkHotkey` (protocol, tested with a fake): started after a recording starts, stopped with it, fire → `mark()`, plus a hint text. `LiveMarkHotkey` (app) is a listen-only `CGEventTap` that feeds the detector.

**Tech Stack:** Swift 6.4, SwiftPM, Swift Testing, CoreGraphics event taps, SwiftUI MenuBarExtra.

Spec: `docs/superpowers/specs/2026-09-28-dabber-mark-hotkey-design.md`.

## Ground rules for implementers

- Repo root: the repository root. Branch `claude/recordings-audio-screenshots-2c3d94` (a worktree). Never push, never use git stash.
- Commit messages: one line, `type: description`, no body, no trailers. `git add` by explicit path only; read `git diff --cached --stat` before every commit.
- Tests: `scripts/test.sh` only. Success means exit code 0 (`scripts/test.sh > log 2>&1; echo "exit=$?"`), never through a pipe. Remove `log` afterwards. Never use `@State` or `@Bindable`; bind with `Binding(get:set:)`.
- Code: English, no comments, KISS, Swift 6. The diffs below are exact: apply them as shown, context lines included.
- Tasks marked **HUMAN** need the user. Stop there.
- Baseline at `f2d7409`: **259 tests**.

## Facts checked for this plan

The complete code was applied task by task to a clone at `f2d7409`: `scripts/test.sh` exit 0 with 263, 266, 266, 266 tests; `swift build` without Swift warnings. Not checked: the event tap on a real keyboard, the Input Monitoring prompt, the sound, the menu on screen (Task 5).

## Tasks

### Task 1: Double-tap detector

**Files:**
- Create: `Sources/DabberCore/Model/DoubleTap.swift`
- Create: `Tests/DabberCoreTests/DoubleTapTests.swift`

`DoubleTap` is a pure detector: feed it `.down` / `.up` of the right Option key or `.other` for any other key or modifier, with the event time in seconds. A tap is a press released within 0.4 s; two taps whose releases are less than 0.4 s apart return `true` once. Anything else in between cancels.

- [ ] **Step 1: Write the failing tests**

`Tests/DabberCoreTests/DoubleTapTests.swift` (new file):

```swift
import Testing
@testable import DabberCore

private func run(_ events: [(DoubleTap.Key, Double)]) -> [Bool] {
    var tap = DoubleTap()
    return events.map { tap.handle($0.0, at: $0.1) }
}

@Test func twoQuickTapsFireOnTheSecondRelease() {
    #expect(run([(.down, 0), (.up, 0.08), (.down, 0.2), (.up, 0.28)]) == [false, false, false, true])
}

@Test func slowTapsAndLongPressesDoNotFire() {
    #expect(run([(.down, 0), (.up, 0.08), (.down, 0.5), (.up, 0.58)]).allSatisfy { !$0 })
    #expect(run([(.down, 0), (.up, 0.5), (.down, 0.6), (.up, 0.7)]).allSatisfy { !$0 })
}

@Test func anotherKeyInBetweenCancels() {
    #expect(run([(.down, 0), (.up, 0.08), (.other, 0.1), (.down, 0.2), (.up, 0.28)]).allSatisfy { !$0 })
    #expect(run([(.down, 0), (.other, 0.05), (.up, 0.08), (.down, 0.2), (.up, 0.28)]).allSatisfy { !$0 })
}

@Test func threeTapsFireOnceAndFourFireTwice() {
    let taps = (0..<4).flatMap { i in [(DoubleTap.Key.down, Double(i) * 0.2), (.up, Double(i) * 0.2 + 0.08)] }
    #expect(run(Array(taps.prefix(6))).filter { $0 }.count == 1)
    #expect(run(taps).filter { $0 }.count == 2)
}
```

- [ ] **Step 2: Run the tests and see them fail**

Run: `scripts/test.sh; echo "exit=$?"`

Expected: build error: cannot find `DoubleTap` in scope. `exit=1`.

- [ ] **Step 3: Implement**

`Sources/DabberCore/Model/DoubleTap.swift` (new file):

```swift
public struct DoubleTap: Sendable {
    public enum Key: Sendable { case down, up, other }

    public static let window = 0.4

    private var downAt: Double?
    private var lastTap: Double?

    public init() {}

    public mutating func handle(_ key: Key, at time: Double) -> Bool {
        switch key {
        case .down:
            downAt = time
        case .up:
            defer { downAt = nil }
            guard let downAt, time - downAt < Self.window else {
                lastTap = nil
                return false
            }
            if let lastTap, time - lastTap < Self.window {
                self.lastTap = nil
                return true
            }
            lastTap = time
        case .other:
            downAt = nil
            lastTap = nil
        }
        return false
    }
}
```

- [ ] **Step 4: Run the tests**

Run: `scripts/test.sh; echo "exit=$?"`

Expected: `Test run with 263 tests in 2 suites passed`, `exit=0`.

- [ ] **Step 5: Commit**

```bash
git add "Sources/DabberCore/Model/DoubleTap.swift" "Tests/DabberCoreTests/DoubleTapTests.swift"
git diff --cached --stat
git commit -m "feat: double-tap detector"
```

### Task 2: Mark hotkey in the recorder model

**Files:**
- Modify: `Sources/DabberCore/App/RecorderModel.swift`
- Modify: `Tests/DabberCoreTests/RecorderModelTests.swift`

`MarkHotkey` is the seam for the keyboard listener. `RecorderModel` starts it after a recording starts (its `Bool` result is whether the permission is there), stops it on Stop and whenever the engine is idle (a session that stopped itself), and turns a fire into `mark()` on the main actor. `hotkeyHint` is the text under the Mark button while recording.

- [ ] **Step 1: Write the failing tests**

`Tests/DabberCoreTests/RecorderModelTests.swift`:

```diff
@@ -791,3 +791,63 @@ private func slidesModel(
     m.menuClosed()
     #expect(m.warning == nil)
 }
+
+private final class FakeHotkey: MarkHotkey, @unchecked Sendable {
+    let allowed: Bool
+    var fire: (@Sendable () -> Void)?
+    var stops = 0
+    init(allowed: Bool = true) { self.allowed = allowed }
+    func start(_ fire: @escaping @Sendable () -> Void) -> Bool {
+        self.fire = fire
+        return allowed
+    }
+    func stop() {
+        stops += 1
+        fire = nil
+    }
+}
+
+@MainActor
+private func hotkeyModel(_ engine: FakeEngine, _ hotkey: FakeHotkey) -> RecorderModel {
+    let m = RecorderModel(
+        engine: engine, catalog: FakeCatalog(devices: [airpods]), enabledIDs: ["computer", "ap"], persist: { _ in },
+        finalize: { dir, _ in dir }, hotkey: hotkey)
+    m.refreshDevices()
+    return m
+}
+
+@MainActor @Test func hotkeyMarksOnlyWhileRecording() async {
+    let e = FakeEngine()
+    let hotkey = FakeHotkey()
+    let m = hotkeyModel(e, hotkey)
+    #expect(hotkey.fire == nil)
+    #expect(m.hotkeyHint == nil)
+    await m.startStop()
+    #expect(m.hotkeyHint == "Double-tap right ⌥ to mark")
+    hotkey.fire?()
+    for _ in 0..<20 where m.marks.isEmpty { await Task.yield() }
+    #expect(m.marks.count == 1)
+    await m.startStop()
+    #expect(hotkey.fire == nil)
+    #expect(hotkey.stops == 1)
+    #expect(m.hotkeyHint == nil)
+}
+
+@MainActor @Test func hotkeyWithoutPermissionSaysHowToAllowIt() async {
+    let m = hotkeyModel(FakeEngine(), FakeHotkey(allowed: false))
+    await m.startStop()
+    #expect(m.hotkeyHint == "Allow Input Monitoring for the ⌥⌥ hotkey")
+    #expect(m.warning == nil)
+}
+
+@MainActor @Test func hotkeyStopsWhenTheSessionStopsItself() async {
+    let e = FakeEngine()
+    let hotkey = FakeHotkey()
+    let m = hotkeyModel(e, hotkey)
+    await m.startStop()
+    e.phase = .idle
+    m.tick()
+    m.tick()
+    #expect(hotkey.stops == 1)
+    #expect(hotkey.fire == nil)
+}
```

- [ ] **Step 2: Run the tests and see them fail**

Run: `scripts/test.sh; echo "exit=$?"`

Expected: build error: cannot find type `MarkHotkey` in scope, `RecorderModel.init` has no `hotkey:` argument. `exit=1`.

- [ ] **Step 3: Implement**

`Sources/DabberCore/App/RecorderModel.swift`:

```diff
@@ -19,6 +19,11 @@ extension SessionRecorder: RecordingEngine {
     }
 }
 
+public protocol MarkHotkey: Sendable {
+    func start(_ fire: @escaping @Sendable () -> Void) -> Bool
+    func stop()
+}
+
 public protocol DeviceCatalog: Sendable {
     func inputs() throws -> [InputDevice]
     func defaultInputUID() -> String?
@@ -70,6 +75,7 @@ public final class RecorderModel {
     public private(set) var title = ""
     public private(set) var outputFolder: URL
     public private(set) var slidesOn: Bool
+    public private(set) var hotkeyAllowed: Bool?
 
     private let engine: any RecordingEngine
     private let catalog: any DeviceCatalog
@@ -81,6 +87,7 @@ public final class RecorderModel {
     private let calendar: any CalendarSource
     private let slides: SlideRecorder?
     private let persistSlides: @Sendable (Bool) -> Void
+    private let hotkey: (any MarkHotkey)?
     private var enabledIDs: Set<String>
     private var names: [String: String]
     private enum StartNote { case noneSelected(String), missing(String?), unavailable }
@@ -107,7 +114,8 @@ public final class RecorderModel {
         persistOutput: @escaping @Sendable (URL) -> Void = { _ in },
         slides: SlideRecorder? = nil,
         slidesOn: Bool = false,
-        persistSlides: @escaping @Sendable (Bool) -> Void = { _ in }
+        persistSlides: @escaping @Sendable (Bool) -> Void = { _ in },
+        hotkey: (any MarkHotkey)? = nil
     ) {
         self.engine = engine
         self.catalog = catalog
@@ -123,6 +131,7 @@ public final class RecorderModel {
         self.slides = slides
         self.slidesOn = slidesOn
         self.persistSlides = persistSlides
+        self.hotkey = hotkey
         lastSessionDir = engine.lastSessionDir
     }
 
@@ -132,6 +141,10 @@ public final class RecorderModel {
     }
     public var canStartStop: Bool { !finalizing && !starting && (isRecording || rows.contains(where: \.enabled)) }
     public var canMark: Bool { phase == .recording && !finalizing }
+    public var hotkeyHint: String? {
+        guard isRecording, let hotkeyAllowed else { return nil }
+        return hotkeyAllowed ? "Double-tap right ⌥ to mark" : "Allow Input Monitoring for the ⌥⌥ hotkey"
+    }
     public var markRows: [MarkRow] {
         marks.enumerated().map { i, m in MarkRow(id: m.id, time: Self.format(seconds: m.seconds), title: m.title(number: i + 1)) }
     }
@@ -230,6 +243,7 @@ public final class RecorderModel {
     public func stopAndFinalize() async {
         saveComment()
         slides?.stop()
+        stopHotkey()
         finalizing = true
         let engine = self.engine
         guard let dir = await Task.detached(operation: { engine.stop() }).value else {
@@ -262,7 +276,10 @@ public final class RecorderModel {
         guard !starting else { return }
         let status = engine.status(at: now)
         let stoppedItself = phase != .idle && status.phase == .idle && !finalizing
-        if status.phase == .idle { slides?.stop() }
+        if status.phase == .idle {
+            slides?.stop()
+            stopHotkey()
+        }
         phase = status.phase
         elapsed = Self.format(seconds: status.phase == .idle ? 0 : status.elapsedSeconds)
         var notes: [String] = []
@@ -322,6 +339,12 @@ public final class RecorderModel {
         }
     }
 
+    private func stopHotkey() {
+        guard hotkeyAllowed != nil else { return }
+        hotkey?.stop()
+        hotkeyAllowed = nil
+    }
+
     nonisolated public static func format(seconds: Double) -> String {
         let s = Int(seconds)
         let h = s / 3600, m = s % 3600 / 60, r = s % 60
@@ -388,6 +411,7 @@ public final class RecorderModel {
         do {
             _ = try await Task.detached { try engine.start(specs: startSpecs, title: title, slides: recordSlides) }.value
             if recordSlides { slides?.start { try engine.addFrame(atNanos: $0, data: $1) } }
+            hotkeyAllowed = hotkey?.start { [weak self] in Task { @MainActor in self?.mark() } }
             self.title = title
             sessionMics = startSpecs.filter { $0.kind == .mic }
             stopErrorSeen = false
```

- [ ] **Step 4: Run the tests**

Run: `scripts/test.sh; echo "exit=$?"`

Expected: `Test run with 266 tests in 2 suites passed`, `exit=0`.

- [ ] **Step 5: Commit**

```bash
git add "Sources/DabberCore/App/RecorderModel.swift" "Tests/DabberCoreTests/RecorderModelTests.swift"
git diff --cached --stat
git commit -m "feat: mark hotkey in the recorder model"
```

### Task 3: Double-tap right Option makes a mark

**Files:**
- Modify: `Sources/Dabber/AppDelegate.swift`
- Create: `Sources/Dabber/LiveMarkHotkey.swift`
- Modify: `Sources/Dabber/MenuApp.swift`

`LiveMarkHotkey` asks for Input Monitoring (`CGPreflightListenEventAccess() || CGRequestListenEventAccess()`), then creates a listen-only `CGEventTap` for flagsChanged and keyDown on the main run loop. The right Option key is key code 61; a press counts only when Option is the only modifier held. The event timestamp feeds `DoubleTap`. A disabled tap (timeout) is enabled again. On a double tap it plays the system sound Tink and calls the model. The menu shows the hint under Mark; AppDelegate passes `LiveMarkHotkey()`.

- [ ] **Step 1: Make the change**

`Sources/Dabber/AppDelegate.swift`:

```diff
@@ -23,7 +23,8 @@ final class AppDelegate: NSObject, NSApplicationDelegate {
         persistOutput: { UserDefaults.standard.set($0.path, forKey: outputKey) },
         slides: SlideRecorder(grabber: LiveScreenGrabber()),
         slidesOn: UserDefaults.standard.bool(forKey: slidesKey),
-        persistSlides: { UserDefaults.standard.set($0, forKey: slidesKey) })
+        persistSlides: { UserDefaults.standard.set($0, forKey: slidesKey) },
+        hotkey: LiveMarkHotkey())
 
     private static let feedKey = "virtualMic"
```

`Sources/Dabber/LiveMarkHotkey.swift` (new file):

```swift
import AppKit
import DabberCore

final class LiveMarkHotkey: MarkHotkey, @unchecked Sendable {
    private static let rightOption: Int64 = 61
    private static let modifiers: CGEventFlags = [.maskShift, .maskControl, .maskAlternate, .maskCommand, .maskSecondaryFn]

    private let lock = NSLock()
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var detector = DoubleTap()
    private var fire: (@Sendable () -> Void)?

    func start(_ fire: @escaping @Sendable () -> Void) -> Bool {
        stop()
        guard CGPreflightListenEventAccess() || CGRequestListenEventAccess() else { return false }
        let mask = CGEventMask(1 << CGEventType.flagsChanged.rawValue) | CGEventMask(1 << CGEventType.keyDown.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly, eventsOfInterest: mask,
            callback: { _, type, event, info in
                if let info { Unmanaged<LiveMarkHotkey>.fromOpaque(info).takeUnretainedValue().handle(type, event) }
                return Unmanaged.passUnretained(event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque())
        else { return false }
        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        lock.withLock {
            self.tap = tap
            self.source = source
            self.fire = fire
            detector = DoubleTap()
        }
        return true
    }

    func stop() {
        lock.withLock {
            if let tap {
                CGEvent.tapEnable(tap: tap, enable: false)
                CFMachPortInvalidate(tap)
            }
            if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
            tap = nil
            source = nil
            fire = nil
        }
    }

    private func handle(_ type: CGEventType, _ event: CGEvent) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            lock.withLock { if let tap { CGEvent.tapEnable(tap: tap, enable: true) } }
            return
        }
        var key = DoubleTap.Key.other
        if type == .flagsChanged, event.getIntegerValueField(.keyboardEventKeycode) == Self.rightOption {
            let held = event.flags.intersection(Self.modifiers)
            key = held == .maskAlternate ? .down : held.isEmpty ? .up : .other
        }
        let time = Double(event.timestamp) / 1e9
        guard let fired = lock.withLock({ detector.handle(key, at: time) ? fire : nil }) else { return }
        NSSound(named: "Tink")?.play()
        fired()
    }
}
```

`Sources/Dabber/MenuApp.swift`:

```diff
@@ -131,6 +131,9 @@ struct MarksView: View {
         VStack(alignment: .leading, spacing: 4) {
             Button("Mark") { model.mark() }
                 .disabled(!model.canMark)
+            if let hint = model.hotkeyHint {
+                Text(hint).font(.caption).foregroundStyle(.secondary)
+            }
             if model.editingMarkID != nil {
                 TextField("Comment (optional)", text: Binding(get: { model.draft }, set: { model.draft = $0 }))
                     .onSubmit { model.saveComment() }
```

- [ ] **Step 2: Run the tests**

Run: `scripts/test.sh; echo "exit=$?"`

Expected: `Test run with 266 tests in 2 suites passed`, `exit=0`. Also run `swift build 2>&1 | grep -E "warning:|error:" | grep -v "ld: warning"` (expect no output) and `scripts/build-app.sh; echo "exit=$?"` (expect exit 0). Do not run the app.

- [ ] **Step 3: Commit**

```bash
git add "Sources/Dabber/AppDelegate.swift" "Sources/Dabber/LiveMarkHotkey.swift" "Sources/Dabber/MenuApp.swift"
git diff --cached --stat
git commit -m "feat: double-tap right option makes a mark"
```

### Task 4: README

**Files:**
- Modify: `README.md`
- Modify: `README.ru.md`

Both READMEs: the Input Monitoring permission row and a Hotkey paragraph in the Marks section.

- [ ] **Step 1: Make the change**

`README.md`:

```diff
@@ -45,6 +45,7 @@ Dabber is built from source on your Mac. There is no prebuilt download.
 | --- | --- | --- |
 | Microphone | First recording (or virtual mic use) with a microphone | To record your microphones |
 | System Audio Recording | First recording (or virtual mic use) with Mac audio | To record sound played by other apps |
+| Input Monitoring | First recording | To notice a double tap of the right Option key (the Mark hotkey). Dabber only listens and only while recording. If you decline, use the Mark button |
 | Screen Recording | First recording with Record slides on | To take the screenshots for the slides video |
 | Calendars (full access) | First recording | To read the title of the current event and name the recording after it. Dabber only reads events. If you decline, recordings are named by date and time |
 
@@ -138,6 +139,12 @@ While recording, press **Mark**. A comment field appears; type a short note and
 Marks without a comment are called "Mark 1", "Mark 2" and so on. The list under the button shows the time of each
 mark; the minus button removes one.
 
+**Hotkey:** double-tap the right Option key (⌥⌥) to make a mark without opening the menu. A short sound confirms
+it; type the comment later in the menu if you want one. It works only while recording, and only a quick double tap
+of the right Option key alone counts (Option with a letter never makes a mark). It needs the Input Monitoring
+permission; without it the menu says "Allow Input Monitoring for the ⌥⌥ hotkey" (System Settings > Privacy &
+Security > Input Monitoring, then quit and start Dabber again).
+
 After Stop, marks become chapters (plus a first chapter "Start" at 0:00) in the mix and in the track files.
 Chapters were checked in QuickTime Player, Preview and VLC (IINA and iPhone apps were not checked). The same
 marks are written to `marks.txt` as `HH:MM:SS  comment` lines.
```

`README.ru.md`:

```diff
@@ -45,6 +45,7 @@ Dabber собирается из исходников на вашем Mac. Го
 | --- | --- | --- |
 | Микрофон | Первая запись (или первое использование виртуального микрофона) с микрофоном | Чтобы записывать микрофоны |
 | Запись системного звука | Первая запись (или первое использование виртуального микрофона) со звуком Mac | Чтобы записывать звук других приложений |
+| Мониторинг ввода | Первая запись | Чтобы заметить двойное нажатие правого Option (горячая клавиша Mark). Dabber только слушает и только во время записи. Если отказать, ставьте отметки кнопкой Mark |
 | Запись экрана | Первая запись с включённым Record slides | Чтобы делать снимки экрана для видео со слайдами |
 | Календари (полный доступ) | Первая запись | Чтобы прочитать название текущего события и назвать по нему запись. Dabber только читает события. Если отказать, записи называются по дате и времени |
 
@@ -140,6 +141,12 @@ VIRTUAL MIC больше не пишет «Driver not installed». Если пи
 пустым. Отметки без комментария называются «Mark 1», «Mark 2» и так далее. В списке под кнопкой видно время каждой
 отметки; кнопка с минусом удаляет отметку.
 
+**Горячая клавиша:** дважды быстро нажмите правый Option (⌥⌥), чтобы поставить отметку, не открывая меню.
+Короткий звук подтверждает отметку; комментарий можно дописать потом в меню. Работает только во время записи и
+только при быстром двойном нажатии одного правого Option (Option с буквой отметку не ставит). Нужно разрешение
+«Мониторинг ввода»; без него меню пишет «Allow Input Monitoring for the ⌥⌥ hotkey» (Системные настройки >
+Конфиденциальность и безопасность > Мониторинг ввода, затем закройте и снова запустите Dabber).
+
 После Stop отметки становятся главами (плюс первая глава «Start» на 0:00) в миксе и в файлах дорожек. Главы
 проверены в QuickTime Player, Просмотре (Preview) и VLC (IINA и приложения на iPhone не проверялись). Те же отметки
 записываются в `marks.txt` строками вида `ЧЧ:ММ:СС  комментарий`.
```

- [ ] **Step 2: Run the tests**

Run: `scripts/test.sh; echo "exit=$?"`

Expected: `Test run with 266 tests in 2 suites passed`, `exit=0`.

- [ ] **Step 3: Commit**

```bash
git add "README.md" "README.ru.md"
git diff --cached --stat
git commit -m "docs: mark hotkey in the README"
```

### Task 5 (HUMAN): real keyboard check

- [ ] `scripts/install-app.sh`, start Dabber, press Record. Allow Input Monitoring when asked (System Settings > Privacy & Security > Input Monitoring), then quit and start Dabber again and press Record.
- [ ] The menu shows "Double-tap right ⌥ to mark" under Mark. Double-tap the right Option key in another app: a Tink sound, a new mark in the menu.
- [ ] Type text with Option+letters and hold the right Option: no marks. Double-tap the left Option: no mark.
- [ ] Two taps of the right Option about 1 s apart: no mark (checks that event timestamps are nanoseconds).
- [ ] After Stop, double taps do nothing.
