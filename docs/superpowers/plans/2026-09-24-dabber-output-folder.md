# Dabber Output Folder Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Recording always writes into the local work folder `~/Library/Application Support/Dabber/Sessions/<session>/`. After finalize the finished session is moved into the output folder the user chose (`<output>/<name>/`, " 2", " 3" on collisions); across volumes that is copy + check (file list and sizes) + delete. If the output folder is missing or the move fails, the session stays in the work folder, the menu says `Saved in the local folder: <reason>`, and the move is retried on the next launch and after the next finalize. Crash recovery scans the work folder and, once, the old `~/Recordings/Dabber` for unfinished sessions. The menu shows `Folder: <name>` and **Change…**; the choice persists. Headless `--out` stays the output root, `--work` picks the work folder.

**Architecture:**
- `Delivery` (new, `Sources/DabberCore/Finalize/Delivery.swift`) owns everything after finalize: `deliver(dir, into:mover:)` moves one finished session; `deliverPending(from:to:)` retries every finished session left in the work folder; `finishAndDeliver(dir, output:)` = `Finalizer.finish` + deliver + retry, the model's default finalize step; `recover(dirs, work:output:)` = `Finalizer.recoverAll` + retry, the launch pass; `adoptUnfinished(from:into:)` moves unfinished legacy sessions into the work folder.
- `Mover` holds the two file operations: `move` (same volume only, otherwise it throws `DeliveryError.otherVolume`) and `copy`. `Mover.live` uses `FileManager`; tests inject a `move` that always throws `.otherVolume` to drive the copy path, and a bad `copy` to drive the check.
- `finishAndDeliver` and `recover` run under one process-wide lock, so a delivery pass never sees a session between `Finalizer.run` (manifest says finalized) and `Finalizer.rename`.
- `RecorderModel` keeps `outputFolder` (persisted through a `persistOutput` closure, same pattern as `persist`), passes it to `finalize(dir, output)`, turns `DeliveryFailed` into the warning and the local `lastSessionDir`, and takes the launch result through `deliveryDone(failure:)`.
- `SessionRecorder` is unchanged; the app gives it `AppPaths.workRoot`, so the disk check (`freeBytes(root)`, `freeBytes(dir)`) runs on the work volume.

**Tech Stack:** Swift 6.4 with SwiftPM and Swift Testing, Foundation `FileManager`, SwiftUI `MenuBarExtra`, AppKit `NSOpenPanel`.

Spec: `docs/superpowers/specs/2026-09-24-dabber-output-folder-design.md`. Format model: `docs/superpowers/plans/2026-09-24-dabber-session-names.md`.

## Ground rules for implementers

- Repo root: the repository root. Branch `marks`. No remote. Never push, never switch branches.
- Commit messages: one line, `type: description`, no body, no trailers. `git add` by explicit path only; read `git diff --cached --stat` before every commit.
- Shell is zsh. Tests: `scripts/test.sh` only. Success means exit code 0: `scripts/test.sh > /tmp/dabber-test.log 2>&1; echo "exit=$?"`, then `tail -1 /tmp/dabber-test.log` for the count. Never judge by grepping text. No Xcode, no `xcodebuild`. Never use `@State`, `@Bindable` or `@FocusState`; bind with `Binding(get:set:)` onto the model.
- Swift warnings stay at 0: `sed 's/\x1b\[[0-9;]*m//g' /tmp/dabber-test.log | grep -cE '\.swift:[0-9]+:[0-9]+: warning:'` prints `0`.
- Never touch the real `~/Recordings/Dabber`, iCloud Drive or `~/Library/Application Support/Dabber`: tests and headless runs use temp folders (`--work`, `--out`). Never launch or quit `/Applications/Dabber.app`, never run `install-app.sh`.
- Code: English, no comments. KISS. Swift 6 language mode.
- Tasks marked **HUMAN** need the user. Stop there, tell the user exactly what to do in at most five short lines, and wait.
- Test counts assume the baseline of `e3f34a2`: **219 tests**. If `scripts/test.sh` reports a different baseline before Task 1, shift every expected count by the difference.

## Facts checked for this plan (2026-09-24, macOS 26.6.2)

- Device ids (`stat -f %d`): `$TMPDIR`, `~/Library/Application Support`, `~/Library/Mobile Documents` (iCloud Drive) and `~/Recordings` are all `16777234` (the Data volume); `/Volumes/<external disk>` is `16777233`. So a move into iCloud Drive is a same-volume rename, not the copy the spec expects; the copy path is for other volumes (external disks, `/Volumes/<external disk>`). The end-to-end check in Task 7 uses a folder on another volume as a real second volume.
- `URLResourceValues.volumeIdentifier` (cast to `NSObject`): equal for two temp folders, different for temp vs `/Volumes/<external disk>`; reading it for a missing path throws "no such file".
- `FileManager.moveItem` onto an existing non-empty directory throws `CocoaError.fileWriteFileExists` (516), as it does onto an empty one or a file (checked in the session names plan).
- Moving or copying into a `0555` folder throws code 513: "“a” couldn’t be moved because you don’t have permission to access “ro”." Moving into a missing folder throws code 4 with a long either/or message, so a missing output folder is checked first and reported as `folder not found: <path>`.
- `FileManager.copyItem` copies a folder with its files; `attributesOfItem[.size]` reads as `Int`.
- `FileManager.displayName(atPath:)` gives "iCloud Drive" for `~/Library/Mobile Documents/com~apple~CloudDocs` and "Dabber" for `~/Recordings/Dabber`.
- `/Volumes` is `drwxr-xr-x root wheel`.
- Not checked: `NSOpenPanel` from the menu-bar window on screen, a real external disk, iCloud upload of a delivered folder (Task 8, HUMAN).

## Decisions

- Work folder: `~/Library/Application Support/Dabber/Sessions` (`AppPaths.workRoot`, created by `SessionRecorder.start` as before). Output default: `~/Recordings/Dabber` (`AppPaths.recordingsRoot`); the app creates it at launch only while it is the chosen folder. A chosen folder is never created: a missing one (unplugged disk, deleted folder) is `folder not found`.
- The output name is the session name from `session.json` (`SessionManifest.name`), not the work folder name, so a " 2" picked in the work folder does not leak into the output folder. Collisions walk `<name>`, `<name> 2`, ... as `Finalizer.rename` does.
- Same volume: `moveItem` (a rename). Other volume: copy into a hidden `<output>/.<work folder name>.partial`, compare the file lists and sizes, rename the copy to the free name, then delete the work folder. Any failure removes the partial copy and keeps the work folder. A partial copy left by a crash is removed before the next copy.
- A delivery pass only takes sessions whose `session.json` has a finalize report, so a live recording (no report) is never touched.
- `finishAndDeliver`: if the new session cannot be delivered, the older ones are not retried in that pass (same folder, same reason). The warning names the first failure.
- Lock: `finishAndDeliver` and `recover` share one `NSLock`. Scenario: a long crash recovery runs at launch while the user records and stops a short session; without the lock one pass could move a session between `Finalizer.run` and `Finalizer.rename`. Cost: that stop shows "Finalizing…" until recovery is done.
- The warning `Saved in the local folder: <reason>` stays until a later delivery pass succeeds (next finalize or next launch); closing the menu does not clear it, because the sessions are still local.
- Changing the folder does not move anything by itself; the next finalize retries (spec: retries on launch and after finalize).
- Legacy scan: once per install, `adoptUnfinished(from: ~/Recordings/Dabber, into: workRoot)` moves only folders that `Finalizer.needsRecovery` accepts (manifest without a finalize report plus CAF files) into the work folder, then the usual recovery and delivery handle them. The flag (`legacySessionsAdopted`) is set only when the scan did not throw, so a failed scan is tried again next launch. Finished sessions stay where they are.
- Headless: `--out` is the output root (created if missing, as before), `--work` the work folder (default `AppPaths.workRoot`). Headless delivers only its own session (`Delivery.deliver`), never other pending ones, and logs `DELIVERED <path>`.

## File structure

```
Sources/DabberCore/Finalize/Delivery.swift       DeliveryError, DeliveryFailed, Mover, Delivery
Sources/DabberCore/App/AppPaths.swift            (modify) workRoot
Sources/DabberCore/App/RecorderModel.swift       (modify) outputFolder, setOutputFolder, finalize(dir, output), delivery warning
Sources/Dabber/AppDelegate.swift                 (modify) work root, output folder, legacy scan, launch recovery + delivery
Sources/Dabber/MenuApp.swift                     (modify) Folder row with Change…
Sources/Dabber/Headless.swift                    (modify) --work, DELIVERED
Tests/DabberCoreTests/DeliveryTests.swift
Tests/DabberCoreTests/FinalizerTests.swift       (modify)
Tests/DabberCoreTests/RecorderModelTests.swift   (modify)
docs/spikes/2026-09-24-output-folder-check.md
```

---

### Task 1: Move a finished session into the output folder (TDD)

**Files:**
- Create: `Sources/DabberCore/Finalize/Delivery.swift`, `Tests/DabberCoreTests/DeliveryTests.swift`

- [ ] **Step 1: Write the failing tests `Tests/DabberCoreTests/DeliveryTests.swift`**

```swift
import Foundation
import Testing
@testable import DabberCore

private let startedAt = Date(timeIntervalSince1970: 1_800_000_000)
private let name = SessionNaming.sessionName(startedAt, title: "Sync")
private let audio = Data(repeating: 7, count: 1_000)

private func temp(_ tag: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(tag)-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@discardableResult
private func session(in root: URL, folder: String, title: String = "Sync", finished: Bool = true) throws -> URL {
    let dir = root.appendingPathComponent(folder)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false)
    var m = SessionManifest(appVersion: "t", startedAt: startedAt, sessionStartNanos: 1)
    m.title = title
    if finished { m.finalize = FinalizeReport(totalFrames: 0, gaps: [], driftMillis: [:], resampled: []) }
    try m.save(to: dir)
    let file = finished ? SessionNaming.sessionName(startedAt, title: title) + ".m4a" : "computer audio.seg000.caf"
    try audio.write(to: dir.appendingPathComponent(file))
    return dir
}

private func names(_ dir: URL) throws -> [String] {
    try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()
}

@Test func finishedSessionMovesIntoTheOutputFolderUnderItsName() throws {
    let work = try temp("work"), out = try temp("out")
    let moved = try Delivery.deliver(try session(in: work, folder: name + " 2"), into: out)
    #expect(moved.path == out.appendingPathComponent(name).path)
    #expect(try names(moved) == [name + ".m4a", "session.json"])
    #expect(try names(work).isEmpty)
}

@Test func takenNamesInTheOutputFolderGetANumber() throws {
    let work = try temp("work"), out = try temp("out")
    try FileManager.default.createDirectory(at: out.appendingPathComponent(name), withIntermediateDirectories: false)
    try Data([1]).write(to: out.appendingPathComponent(name + " 2"))
    let moved = try Delivery.deliver(try session(in: work, folder: name), into: out)
    #expect(moved.lastPathComponent == name + " 3")
    #expect(try names(moved) == [name + ".m4a", "session.json"])
}

@Test func missingOutputFolderLeavesTheSessionInPlace() throws {
    let work = try temp("work")
    let out = work.deletingLastPathComponent().appendingPathComponent("gone-\(UUID().uuidString)")
    let dir = try session(in: work, folder: name)
    #expect(throws: DeliveryError.folderMissing(out.path)) { try Delivery.deliver(dir, into: out) }
    #expect(DeliveryError.folderMissing(out.path).localizedDescription == "folder not found: \(out.path)")
    #expect(try names(dir) == [name + ".m4a", "session.json"])
    #expect(!FileManager.default.fileExists(atPath: out.path))
}

@Test func unwritableOutputFolderLeavesTheSessionInPlace() throws {
    let work = try temp("work"), out = try temp("out")
    try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: out.path)
    defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: out.path) }
    let dir = try session(in: work, folder: name)
    #expect(throws: CocoaError.self) { try Delivery.deliver(dir, into: out) }
    #expect(try names(dir) == [name + ".m4a", "session.json"])
    #expect(try names(out).isEmpty)
}
```

- [ ] **Step 2: Run, expect compile failure**

Run: `scripts/test.sh > /tmp/dabber-test.log 2>&1; echo "exit=$?"`
Expected: `cannot find 'Delivery' in scope` in the log, non-zero exit.

- [ ] **Step 3: Implement `Sources/DabberCore/Finalize/Delivery.swift`**

```swift
import Foundation

public enum DeliveryError: LocalizedError, Equatable {
    case otherVolume
    case folderMissing(String)

    public var errorDescription: String? {
        switch self {
        case .otherVolume: return "not on the same volume"
        case .folderMissing(let path): return "folder not found: \(path)"
        }
    }
}

public struct Mover: Sendable {
    public var move: @Sendable (URL, URL) throws -> Void
    public var copy: @Sendable (URL, URL) throws -> Void

    public init(move: @escaping @Sendable (URL, URL) throws -> Void, copy: @escaping @Sendable (URL, URL) throws -> Void) {
        self.move = move
        self.copy = copy
    }

    public static let live = Mover(
        move: { from, to in
            guard try sameVolume(from, to.deletingLastPathComponent()) else { throw DeliveryError.otherVolume }
            try FileManager.default.moveItem(at: from, to: to)
        },
        copy: { try FileManager.default.copyItem(at: $0, to: $1) })

    static func sameVolume(_ a: URL, _ b: URL) throws -> Bool {
        let ids = try [a, b].map { try $0.resourceValues(forKeys: [.volumeIdentifierKey]).volumeIdentifier as? NSObject }
        return ids[0] != nil && ids[0] == ids[1]
    }
}

public enum Delivery {
    public static func deliver(_ dir: URL, into output: URL, mover: Mover = .live) throws -> URL {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: output.path, isDirectory: &isDir), isDir.boolValue else {
            throw DeliveryError.folderMissing(output.path)
        }
        let name = try SessionManifest.load(from: dir).name
        return try place(name, in: output) { try mover.move(dir, $0) }
    }

    static func place(_ name: String, in parent: URL, _ move: (URL) throws -> Void) throws -> URL {
        var n = 1
        while true {
            let target = parent.appendingPathComponent(n == 1 ? name : "\(name) \(n)")
            do {
                try move(target)
                return target
            } catch CocoaError.fileWriteFileExists {
                n += 1
            }
        }
    }
}
```

- [ ] **Step 4: Run tests**

Run: `scripts/test.sh > /tmp/dabber-test.log 2>&1; echo "exit=$?"; tail -1 /tmp/dabber-test.log`
Expected: `Test run with 223 tests ... passed`, `exit=0`.

- [ ] **Step 5: Commit**

```zsh
git add Sources/DabberCore/Finalize/Delivery.swift Tests/DabberCoreTests/DeliveryTests.swift
git diff --cached --stat
git commit -m "feat: move finished sessions into the output folder"
```

---

### Task 2: Copy, check, then delete across volumes (TDD)

**Files:**
- Modify: `Sources/DabberCore/Finalize/Delivery.swift`, `Tests/DabberCoreTests/DeliveryTests.swift`

- [ ] **Step 1: Write the failing tests (append to `DeliveryTests.swift`)**

```swift
private let otherVolume = Mover(move: { _, _ in throw DeliveryError.otherVolume }, copy: Mover.live.copy)

@Test func acrossVolumesTheSessionIsCopiedCheckedThenRemoved() throws {
    let work = try temp("work"), out = try temp("out")
    try FileManager.default.createDirectory(at: out.appendingPathComponent(name), withIntermediateDirectories: false)
    let moved = try Delivery.deliver(try session(in: work, folder: name), into: out, mover: otherVolume)
    #expect(moved.lastPathComponent == name + " 2")
    #expect(try names(moved) == [name + ".m4a", "session.json"])
    #expect(try Data(contentsOf: moved.appendingPathComponent(name + ".m4a")) == audio)
    #expect(try names(out) == [name, name + " 2"])
    #expect(try names(work).isEmpty)
}

@Test func aCopyThatDoesNotMatchKeepsTheWorkFilesAndLeavesNothingBehind() throws {
    let work = try temp("work"), out = try temp("out")
    let dir = try session(in: work, folder: name)
    let short = Mover(move: otherVolume.move) { from, to in
        try FileManager.default.copyItem(at: from, to: to)
        try Data([7]).write(to: to.appendingPathComponent(name + ".m4a"))
    }
    let partial = Mover(move: otherVolume.move) { from, to in
        try FileManager.default.copyItem(at: from, to: to)
        try FileManager.default.removeItem(at: to.appendingPathComponent("session.json"))
    }
    for mover in [short, partial] {
        #expect(throws: DeliveryError.copyMismatch(name)) { try Delivery.deliver(dir, into: out, mover: mover) }
        #expect(try names(dir) == [name + ".m4a", "session.json"])
        #expect(try Data(contentsOf: dir.appendingPathComponent(name + ".m4a")) == audio)
        #expect(try names(out).isEmpty)
    }
}

@Test func aCopyLeftByAnInterruptedDeliveryIsReplaced() throws {
    let work = try temp("work"), out = try temp("out")
    let stale = out.appendingPathComponent("." + name + Delivery.partialSuffix)
    try FileManager.default.createDirectory(at: stale, withIntermediateDirectories: false)
    try Data([1]).write(to: stale.appendingPathComponent("junk"))
    let moved = try Delivery.deliver(try session(in: work, folder: name), into: out, mover: otherVolume)
    #expect(try names(out) == [name])
    #expect(try names(moved) == [name + ".m4a", "session.json"])
}

@Test func unwritableOutputFolderOnAnotherVolumeLeavesTheSessionInPlace() throws {
    let work = try temp("work"), out = try temp("out")
    try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: out.path)
    defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: out.path) }
    let dir = try session(in: work, folder: name)
    #expect(throws: CocoaError.self) { try Delivery.deliver(dir, into: out, mover: otherVolume) }
    #expect(try names(dir) == [name + ".m4a", "session.json"])
    #expect(try names(out).isEmpty)
}
```

- [ ] **Step 2: Run, expect compile failure**

Run: `scripts/test.sh > /tmp/dabber-test.log 2>&1; echo "exit=$?"`
Expected: `type 'DeliveryError' has no member 'copyMismatch'` in the log, non-zero exit.

- [ ] **Step 3: Implement**

In `DeliveryError` add the case and its text:
```swift
    case copyMismatch(String)
```
```swift
        case .copyMismatch(let folder): return "copy of \(folder) did not match"
```
In `Delivery` replace
```swift
        let name = try SessionManifest.load(from: dir).name
        return try place(name, in: output) { try mover.move(dir, $0) }
    }
```
with
```swift
        let name = try SessionManifest.load(from: dir).name
        do {
            return try place(name, in: output) { try mover.move(dir, $0) }
        } catch DeliveryError.otherVolume {
            let copy = output.appendingPathComponent("." + dir.lastPathComponent + partialSuffix)
            try? FileManager.default.removeItem(at: copy)
            do {
                try mover.copy(dir, copy)
                guard try listing(copy) == listing(dir) else { throw DeliveryError.copyMismatch(dir.lastPathComponent) }
            } catch {
                try? FileManager.default.removeItem(at: copy)
                throw error
            }
            let target = try place(name, in: output) { try FileManager.default.moveItem(at: copy, to: $0) }
            try FileManager.default.removeItem(at: dir)
            return target
        }
    }

    private static func listing(_ dir: URL) throws -> [String: Int] {
        var sizes: [String: Int] = [:]
        for file in try FileManager.default.contentsOfDirectory(atPath: dir.path) {
            sizes[file] = try FileManager.default.attributesOfItem(atPath: dir.appendingPathComponent(file).path)[.size] as? Int
        }
        return sizes
    }
```
and add at the top of `Delivery`:
```swift
    public static let partialSuffix = ".partial"

```

- [ ] **Step 4: Run tests**

Run: `scripts/test.sh > /tmp/dabber-test.log 2>&1; echo "exit=$?"; tail -1 /tmp/dabber-test.log`
Expected: `Test run with 227 tests ... passed`, `exit=0`.

- [ ] **Step 5: Commit**

```zsh
git add Sources/DabberCore/Finalize/Delivery.swift Tests/DabberCoreTests/DeliveryTests.swift
git diff --cached --stat
git commit -m "feat: copy and check sessions delivered to another volume"
```

---

### Task 3: Retry pending sessions after finalize and at launch (TDD)

**Files:**
- Modify: `Sources/DabberCore/Finalize/Delivery.swift`, `Tests/DabberCoreTests/DeliveryTests.swift`, `Tests/DabberCoreTests/FinalizerTests.swift`

- [ ] **Step 1: Write the failing tests**

Append to `DeliveryTests.swift`:
```swift
@Test func pendingDeliveryMovesFinishedSessionsAndLeavesUnfinishedOnes() throws {
    let work = try temp("work")
    let out = work.deletingLastPathComponent().appendingPathComponent("later-\(UUID().uuidString)")
    try session(in: work, folder: "a", title: "A")
    try session(in: work, folder: "b", title: "B")
    try session(in: work, folder: "live", finished: false)
    #expect(Delivery.deliverPending(from: work, to: out) == "folder not found: \(out.path)")
    #expect(try names(work) == ["a", "b", "live"])
    try FileManager.default.createDirectory(at: out, withIntermediateDirectories: false)
    #expect(Delivery.deliverPending(from: work, to: out) == nil)
    #expect(try names(work) == ["live"])
    #expect(try names(out) == ["A", "B"].map { SessionNaming.sessionName(startedAt, title: $0) })
}
```
Append inside the `extension FinalizerTests` in `FinalizerTests.swift` (after `recoveryAppliesTheSavedTitle`):
```swift
    @Test func finishAndDeliverKeepsASessionLocalThenDeliversItWithTheNextOne() throws {
        let (work, dir) = try namedSession("Sync")
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("out-\(UUID().uuidString)")
        let name = SessionNaming.sessionName(startedAt, title: "Sync")
        let failed = #expect(throws: DeliveryFailed.self) { try Delivery.finishAndDeliver(dir, output: out) }
        #expect(failed?.dir.path == work.appendingPathComponent(name).path)
        #expect(failed?.reason == "folder not found: \(out.path)")
        #expect(FileManager.default.fileExists(atPath: work.appendingPathComponent(name).appendingPathComponent(name + ".m4a").path))
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: false)
        let next = work.appendingPathComponent("next")
        try FileManager.default.moveItem(at: try makeSession(), to: next)
        let dateName = SessionNaming.sessionName(startedAt, title: "")
        #expect(try Delivery.finishAndDeliver(next, output: out).path == out.appendingPathComponent(dateName).path)
        #expect(try FileManager.default.contentsOfDirectory(atPath: out.path).sorted() == [dateName, name])
        #expect(try FileManager.default.contentsOfDirectory(atPath: work.path).isEmpty)
    }

    @Test func launchRecoveryFinishesCrashedSessionsThenDeliversThem() throws {
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("work-\(UUID().uuidString)")
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("out-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: try makeSession(), to: work.appendingPathComponent("crashed"))
        let failure = Delivery.recover(Finalizer.sessionFolders(root: work), work: work, output: out) { dir, error in
            Issue.record("\(dir.lastPathComponent): \(error)")
        }
        #expect(failure == nil)
        let name = SessionNaming.sessionName(startedAt, title: "")
        #expect(try FileManager.default.contentsOfDirectory(atPath: out.path) == [name])
        #expect(FileManager.default.fileExists(atPath: out.appendingPathComponent(name).appendingPathComponent(name + ".m4a").path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: work.path).isEmpty)
    }
```

- [ ] **Step 2: Run, expect compile failure**

Run: `scripts/test.sh > /tmp/dabber-test.log 2>&1; echo "exit=$?"`
Expected: `type 'Delivery' has no member 'deliverPending'` in the log, non-zero exit.

- [ ] **Step 3: Implement**

In `Delivery.swift` add after `DeliveryError`:
```swift
public struct DeliveryFailed: Error {
    public let dir: URL
    public let reason: String
}
```
In `Delivery` add after `partialSuffix`:
```swift
    private static let lock = NSLock()

    public static func finishAndDeliver(_ dir: URL, output: URL, mover: Mover = .live) throws -> URL {
        try lock.withLock {
            let done = try Finalizer.finish(dir)
            let moved: URL
            do {
                moved = try deliver(done, into: output, mover: mover)
            } catch {
                throw DeliveryFailed(dir: done, reason: error.localizedDescription)
            }
            if let failure = deliverPending(from: done.deletingLastPathComponent(), to: output, mover: mover) {
                throw DeliveryFailed(dir: moved, reason: failure)
            }
            return moved
        }
    }

    public static func recover(
        _ dirs: [URL], work: URL, output: URL, mover: Mover = .live, onError: (URL, any Error) -> Void = { _, _ in }
    ) -> String? {
        lock.withLock {
            Finalizer.recoverAll(dirs: dirs, onError: onError)
            return deliverPending(from: work, to: output, mover: mover)
        }
    }

    public static func deliverPending(from work: URL, to output: URL, mover: Mover = .live) -> String? {
        var failure: String?
        for dir in Finalizer.sessionFolders(root: work) where (try? SessionManifest.load(from: dir))?.finalize != nil {
            do {
                _ = try deliver(dir, into: output, mover: mover)
            } catch {
                failure = failure ?? error.localizedDescription
            }
        }
        return failure
    }
```

- [ ] **Step 4: Run tests**

Run: `scripts/test.sh > /tmp/dabber-test.log 2>&1; echo "exit=$?"; tail -1 /tmp/dabber-test.log`
Expected: `Test run with 230 tests ... passed`, `exit=0`.

- [ ] **Step 5: Commit**

```zsh
git add Sources/DabberCore/Finalize/Delivery.swift Tests/DabberCoreTests/DeliveryTests.swift Tests/DabberCoreTests/FinalizerTests.swift
git diff --cached --stat
git commit -m "feat: retry pending deliveries after finalize and at launch"
```

---

### Task 4: Adopt unfinished sessions from the old folder (TDD)

**Files:**
- Modify: `Sources/DabberCore/Finalize/Delivery.swift`, `Tests/DabberCoreTests/DeliveryTests.swift`

- [ ] **Step 1: Write the failing tests (append to `DeliveryTests.swift`)**

```swift
@Test func legacyUnfinishedSessionsAreAdoptedAndFinishedOnesStay() throws {
    let legacy = try temp("legacy"), work = try temp("work")
    try session(in: legacy, folder: "2026-09-20 10-00-00", finished: false)
    try session(in: legacy, folder: "2026-09-21 10-00 Done", title: "Done")
    try session(in: work, folder: "2026-09-20 10-00-00", finished: false)
    let adopted = try Delivery.adoptUnfinished(from: legacy, into: work)
    #expect(adopted.map(\.path) == [work.appendingPathComponent("2026-09-20 10-00-00 2").path])
    #expect(try names(adopted[0]) == ["computer audio.seg000.caf", "session.json"])
    #expect(try names(legacy) == ["2026-09-21 10-00 Done"])
}

@Test func missingLegacyFolderAdoptsNothing() throws {
    let base = try temp("none")
    let work = base.appendingPathComponent("work")
    #expect(try Delivery.adoptUnfinished(from: base.appendingPathComponent("legacy"), into: work).isEmpty)
    #expect(!FileManager.default.fileExists(atPath: work.path))
}
```

- [ ] **Step 2: Run, expect compile failure**

Run: `scripts/test.sh > /tmp/dabber-test.log 2>&1; echo "exit=$?"`
Expected: `type 'Delivery' has no member 'adoptUnfinished'` in the log, non-zero exit.

- [ ] **Step 3: Implement (add to `Delivery`, after `deliverPending`)**

```swift
    public static func adoptUnfinished(from legacy: URL, into work: URL) throws -> [URL] {
        let unfinished = Finalizer.sessionFolders(root: legacy).filter(Finalizer.needsRecovery)
        guard !unfinished.isEmpty else { return [] }
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        return try unfinished.map { dir in
            try place(dir.lastPathComponent, in: work) { try FileManager.default.moveItem(at: dir, to: $0) }
        }
    }
```

- [ ] **Step 4: Run tests**

Run: `scripts/test.sh > /tmp/dabber-test.log 2>&1; echo "exit=$?"; tail -1 /tmp/dabber-test.log`
Expected: `Test run with 232 tests ... passed`, `exit=0`.

- [ ] **Step 5: Commit**

```zsh
git add Sources/DabberCore/Finalize/Delivery.swift Tests/DabberCoreTests/DeliveryTests.swift
git diff --cached --stat
git commit -m "feat: adopt unfinished sessions from the old recordings folder"
```

---

### Task 5: Output folder and delivery warning in `RecorderModel` (TDD)

**Files:**
- Modify: `Sources/DabberCore/App/RecorderModel.swift`, `Tests/DabberCoreTests/RecorderModelTests.swift`

- [ ] **Step 1: Write the failing tests**

The finalize closure gains the output folder. Update the existing call sites:
```zsh
sed -i '' -e 's/finalize: { finalized(\$0); return \$0 })/finalize: { dir, _ in finalized(dir); return dir })/' \
  -e 's/finalize: { \$0 }/finalize: { dir, _ in dir }/' \
  -e 's/finalize: { _ in renamed }/finalize: { _, _ in renamed }/' Tests/DabberCoreTests/RecorderModelTests.swift
grep -n "finalize:" Tests/DabberCoreTests/RecorderModelTests.swift
```
Expected: 7 lines, none with `$0`.

Append to `RecorderModelTests.swift`:
```swift
@MainActor @Test func finalizeGetsTheChosenFolderAndTheChoiceIsPersisted() async {
    let e = FakeEngine()
    nonisolated(unsafe) var outputs: [String] = []
    nonisolated(unsafe) var saved: [String] = []
    let m = RecorderModel(
        engine: e, catalog: FakeCatalog(devices: [airpods]), enabledIDs: ["computer"], persist: { _ in },
        finalize: { dir, out in outputs.append(out.path); return dir },
        outputFolder: URL(fileURLWithPath: "/tmp/out-a"), persistOutput: { saved.append($0.path) })
    m.refreshDevices()
    #expect(m.outputFolder.path == "/tmp/out-a")
    m.setOutputFolder(URL(fileURLWithPath: "/tmp/out-b"))
    #expect(m.outputFolder.path == "/tmp/out-b")
    #expect(saved == ["/tmp/out-b"])
    await m.startStop()
    await m.startStop()
    #expect(outputs == ["/tmp/out-b"])
}

@MainActor @Test func failedDeliveryKeepsTheLocalSessionAndWarnsUntilADeliverySucceeds() async {
    let e = FakeEngine()
    let local = URL(fileURLWithPath: "/tmp/work/2026-09-24 10-00")
    let moved = URL(fileURLWithPath: "/tmp/out/2026-09-24 10-00")
    let fail = Atomic<Bool>(true)
    let m = RecorderModel(
        engine: e, catalog: FakeCatalog(devices: [airpods]), enabledIDs: ["computer"], persist: { _ in },
        finalize: { _, _ in
            if fail.load(ordering: .relaxed) { throw DeliveryFailed(dir: local, reason: "folder not found: /tmp/out") }
            return moved
        })
    m.refreshDevices()
    await m.startStop()
    await m.startStop()
    #expect(m.lastSessionDir == local)
    #expect(m.errorText == nil)
    #expect(m.warning == "Saved in the local folder: folder not found: /tmp/out")
    m.menuClosed()
    #expect(m.warning == "Saved in the local folder: folder not found: /tmp/out")
    fail.store(false, ordering: .relaxed)
    await m.startStop()
    await m.startStop()
    #expect(m.lastSessionDir == moved)
    #expect(m.warning == nil)
}

@MainActor @Test func launchDeliveryResultSetsAndClearsTheWarning() {
    let m = model(FakeEngine())
    m.deliveryDone(failure: "folder not found: /x")
    #expect(m.warning == "Saved in the local folder: folder not found: /x")
    m.deliveryDone(failure: nil)
    #expect(m.warning == nil)
}
```

- [ ] **Step 2: Run, expect compile failure**

Run: `scripts/test.sh > /tmp/dabber-test.log 2>&1; echo "exit=$?"`
Expected: a closure/argument mismatch such as `contextual closure type '(URL) throws -> URL' expects 1 argument, but 2 were used` in the log, non-zero exit.

- [ ] **Step 3: Implement in `Sources/DabberCore/App/RecorderModel.swift`**

Add after `public private(set) var title = ""`:
```swift
    public private(set) var outputFolder: URL
```
Replace
```swift
    private let finalize: @Sendable (URL) throws -> URL
```
with
```swift
    private let finalize: @Sendable (URL, URL) throws -> URL
    private let persistOutput: @Sendable (URL) -> Void
```
Add after `private var recoveryNotes: [String] = []`:
```swift
    private var deliveryNote: String?
```
In `init`, replace
```swift
        finalize: @escaping @Sendable (URL) throws -> URL = { try Finalizer.finish($0) },
        clock: @escaping @Sendable () -> UInt64 = HostClock.nowNanos,
        calendar: any CalendarSource = NoCalendar()
    ) {
```
with
```swift
        finalize: @escaping @Sendable (URL, URL) throws -> URL = { try Delivery.finishAndDeliver($0, output: $1) },
        clock: @escaping @Sendable () -> UInt64 = HostClock.nowNanos,
        calendar: any CalendarSource = NoCalendar(),
        outputFolder: URL = AppPaths.recordingsRoot,
        persistOutput: @escaping @Sendable (URL) -> Void = { _ in }
    ) {
```
and after `self.calendar = calendar` add
```swift
        self.outputFolder = outputFolder
        self.persistOutput = persistOutput
```
Add after `setTitle`:
```swift
    public func setOutputFolder(_ url: URL) {
        outputFolder = url
        persistOutput(url)
    }

    public func deliveryDone(failure: String?) {
        deliveryNote = failure
        tick()
    }
```
In `tick`, replace
```swift
        notes += recoveryNotes
```
with
```swift
        if let deliveryNote { notes.append("Saved in the local folder: \(deliveryNote)") }
        notes += recoveryNotes
```
In `finalizeSession`, replace
```swift
        let finalize = self.finalize
        let task = Task {
            do {
                lastSessionDir = try await Task.detached { try finalize(dir) }.value
                errorText = nil
            } catch {
```
with
```swift
        let finalize = self.finalize
        let output = outputFolder
        let task = Task {
            do {
                lastSessionDir = try await Task.detached { try finalize(dir, output) }.value
                errorText = nil
                deliveryNote = nil
            } catch let failed as DeliveryFailed {
                lastSessionDir = failed.dir
                errorText = nil
                deliveryNote = failed.reason
            } catch {
```

- [ ] **Step 4: Run tests**

Run: `scripts/test.sh > /tmp/dabber-test.log 2>&1; echo "exit=$?"; tail -1 /tmp/dabber-test.log`
Expected: `Test run with 235 tests ... passed`, `exit=0`.

- [ ] **Step 5: Commit**

```zsh
git add Sources/DabberCore/App/RecorderModel.swift Tests/DabberCoreTests/RecorderModelTests.swift
git diff --cached --stat
git commit -m "feat: keep the output folder in the model and warn when a session stays local"
```

---

### Task 6: Work folder, launch pass and the Folder row in the app

**Files:**
- Modify: `Sources/DabberCore/App/AppPaths.swift`, `Sources/Dabber/AppDelegate.swift`, `Sources/Dabber/MenuApp.swift`

No unit tests (app target); checked by the build here and by Task 8.

- [ ] **Step 1: `AppPaths.workRoot`**

In `Sources/DabberCore/App/AppPaths.swift` add after `recordingsRoot`:
```swift

    public static var workRoot: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Dabber/Sessions")
    }
```

- [ ] **Step 2: `AppDelegate`**

Replace
```swift
    private static let enabledKey = "enabledSources"
    private static let namesKey = "sourceNames"
```
with
```swift
    private static let enabledKey = "enabledSources"
    private static let namesKey = "sourceNames"
    private static let outputKey = "outputFolder"
    private static let legacyKey = "legacySessionsAdopted"
```
Replace
```swift
        engine: SessionRecorder(root: AppPaths.recordingsRoot, appVersion: AppPaths.version),
```
with
```swift
        engine: SessionRecorder(root: AppPaths.workRoot, appVersion: AppPaths.version),
```
Replace
```swift
        calendar: EventKitCalendar())
```
with
```swift
        calendar: EventKitCalendar(),
        outputFolder: UserDefaults.standard.string(forKey: outputKey).map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? AppPaths.recordingsRoot,
        persistOutput: { UserDefaults.standard.set($0.path, forKey: outputKey) })
```
Replace
```swift
        let pending = Finalizer.sessionFolders(root: AppPaths.recordingsRoot)
        Task.detached {
            _ = Finalizer.recoverAll(dirs: pending) { dir, error in
                Task { @MainActor in Self.model.recoveryFailed(dir, error) }
            }
        }
```
with
```swift
        let work = AppPaths.workRoot
        let output = Self.model.outputFolder
        if output.path == AppPaths.recordingsRoot.path {
            try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        }
        let defaults = UserDefaults.standard
        if !defaults.bool(forKey: Self.legacyKey),
           (try? Delivery.adoptUnfinished(from: AppPaths.recordingsRoot, into: work)) != nil {
            defaults.set(true, forKey: Self.legacyKey)
        }
        let pending = Finalizer.sessionFolders(root: work)
        Task.detached {
            let failure = Delivery.recover(pending, work: work, output: output) { dir, error in
                Task { @MainActor in Self.model.recoveryFailed(dir, error) }
            }
            await MainActor.run { Self.model.deliveryDone(failure: failure) }
        }
```
The snapshot `pending` is still taken before any recording can start, so a live session is never recovered.

- [ ] **Step 3: Folder row in `MenuApp.swift`**

In `RecordingSection.body` replace
```swift
            Button("Show last recording") {
```
with
```swift
            HStack {
                Text("Folder: \(FileManager.default.displayName(atPath: model.outputFolder.path))")
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Button("Change…") { chooseFolder() }
                    .buttonStyle(.borderless)
            }
            .font(.caption)
            Button("Show last recording") {
```
and add after `body` in `RecordingSection`:
```swift

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = model.outputFolder
        panel.prompt = "Choose"
        NSApp.activate()
        if panel.runModal() == .OK, let url = panel.url { model.setOutputFolder(url) }
    }
```

- [ ] **Step 4: Build and test**

Run: `swift build > /tmp/dabber-build.log 2>&1; echo "exit=$?"` then `scripts/test.sh > /tmp/dabber-test.log 2>&1; echo "exit=$?"; tail -1 /tmp/dabber-test.log`
Expected: `exit=0` twice, 235 tests, warnings 0 in both logs (`sed 's/\x1b\[[0-9;]*m//g' /tmp/dabber-build.log | grep -cE '\.swift:[0-9]+:[0-9]+: warning:'` prints `0`).

- [ ] **Step 5: Commit**

```zsh
git add Sources/DabberCore/App/AppPaths.swift Sources/Dabber/AppDelegate.swift Sources/Dabber/MenuApp.swift
git diff --cached --stat
git commit -m "feat: record into the work folder and choose the output folder in the menu"
```

---

### Task 7: Headless `--work` and delivery, end-to-end check (automated)

**Files:**
- Modify: `Sources/Dabber/Headless.swift`

- [ ] **Step 1: Implement**

In the `--record` case replace
```swift
            var root = AppPaths.recordingsRoot
```
with
```swift
            var output = AppPaths.recordingsRoot
            var work = AppPaths.workRoot
```
replace
```swift
                case "--out":
                    i += 1
                    guard i < args.count else { return 64 }
                    root = URL(fileURLWithPath: args[i])
```
with
```swift
                case "--out":
                    i += 1
                    guard i < args.count else { return 64 }
                    output = URL(fileURLWithPath: args[i])
                case "--work":
                    i += 1
                    guard i < args.count else { return 64 }
                    work = URL(fileURLWithPath: args[i])
```
replace
```swift
            let recorder = SessionRecorder(root: root, appVersion: AppPaths.version)
```
with
```swift
            let recorder = SessionRecorder(root: work, appVersion: AppPaths.version)
```
and replace
```swift
            log.line("NAMED \(try Finalizer.rename(stopped).path)")
            return 0
```
with
```swift
            let named = try Finalizer.rename(stopped)
            log.line("NAMED \(named.path)")
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            log.line("DELIVERED \(try Delivery.deliver(named, into: output).path)")
            return 0
```

- [ ] **Step 2: Build the app**

Run: `scripts/build-app.sh > /tmp/dabber-app.log 2>&1; echo "exit=$?"`
Expected: `exit=0`, 0 Swift warnings in the log.

- [ ] **Step 3: Same volume (both folders on the Data volume)**

```zsh
W=$(mktemp -d /tmp/dabber-e2e-work.XXXXXX); O=$(mktemp -d /tmp/dabber-e2e-out.XXXXXX)
scripts/run-headless.sh /tmp/dabber-e2e-same.log --record --computer-audio --seconds 5 --title x --work "$W" --out "$O"; echo "exit=$?"
ls -la "$W"; ls -la "$O"/*
```
Expected: `exit=0`, the log has `SESSION $W/...`, `NAMED $W/<date> x`, `DELIVERED $O/<date> x`; `$W` is empty; `$O/<date> x/` holds `<date> x.m4a`, `computer audio.m4a`, `session.json`.

- [ ] **Step 4: Other volume (work on the Data volume, output on `/Volumes/<external disk>`)**

```zsh
W=$(mktemp -d /tmp/dabber-e2e-work.XXXXXX); O=$(mktemp -d /Volumes/External/dabber-build/e2e-out.XXXXXX)
stat -f %d "$W" "$O"
scripts/run-headless.sh /tmp/dabber-e2e-cross.log --record --computer-audio --seconds 5 --title x --work "$W" --out "$O"; echo "exit=$?"
ls -la "$W"; ls -la "$O"; ls -la "$O"/*
```
Expected: two different device ids, `exit=0`, `DELIVERED $O/<date> x`; `$W` empty; `$O` holds only `<date> x/` (no `.partial` folder) with the same three files.

- [ ] **Step 5: Commit**

```zsh
git add Sources/Dabber/Headless.swift
git diff --cached --stat
git commit -m "feat: deliver headless recordings into --out from a --work folder"
```

---

### Task 8: Real app with a chosen folder (HUMAN)

**Files:**
- Create: `docs/spikes/2026-09-24-output-folder-check.md`

- [ ] **Step 1: Check (HUMAN)**

Tell the user:
> Quit any running Dabber, run `open build/Dabber.app`. Menu shows `Folder: Dabber`?
> Change… → pick or create a folder in iCloud Drive; record 20 s; Show last recording opens `<name>/` there with `<name>.m4a`?
> `chmod 555` that folder (or pick a folder on a USB disk and eject it); record 10 s: warning `Saved in the local folder: …`, Show last recording opens `~/Library/Application Support/Dabber/Sessions/…`?
> `chmod 755` (or plug the disk back); record 10 s: both sessions land in the folder, the warning is gone?
> Quit and relaunch: `Folder:` still shows your choice?

- [ ] **Step 2: Record the result and commit**

Write `docs/spikes/2026-09-24-output-folder-check.md`: macOS version; open panel shown and folder accepted yes/no; iCloud delivery path; warning text as seen; retry result; choice kept after relaunch. Every "no" is a finding to report to the user before anything else.
```zsh
git add docs/spikes/2026-09-24-output-folder-check.md
git diff --cached --stat
git commit -m "docs: record output folder check"
```

## After this plan

- If `NSOpenPanel` shows behind other windows or the menu window swallows it: open it with `panel.begin` after the menu closes, or keep `runModal` but call `NSApp.activate()` earlier.
- Sessions stay local until the next finalize or launch even if the folder comes back earlier; a retry on folder change or on a timer is the next step if that is annoying.
- Out of scope, from the spec: per-session folder choice, moving already finished sessions between folders, cleaning up old sessions.
