# Dabber Slides Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** With the menu switch **Record slides** on, Dabber takes a screenshot of the display under the mouse pointer every 2 seconds while recording, keeps only changed screens as HEIC files, and after Stop builds `<name>.mp4` next to `<name>.m4a`: HEVC video where each kept screen stays until the next one, the mix audio copied without re-encoding, the same chapters and title. With the switch off everything stays as before.

**Architecture:**
- `SessionManifest.frames` records each kept frame (`offsetNanos`, `frames/<offsetNanos>.heic`) at once, like marks, so crash recovery also builds the video. `FinalizeReport.slidesError` records a failed video.
- `Frames` / `FrameSampler` (DabberCore, pure, tested): scale to at most 1920 wide, compare a 64x36 gray thumbnail with the last kept one, encode HEIC. `SlideRecorder` (DabberCore, tested with a fake grabber) runs the 2 s loop and stores changed frames through `SessionRecorder.addFrame`. `LiveScreenGrabber` (app) is the only ScreenCaptureKit code.
- `SlideshowWriter` (DabberCore, Finalize) writes the `.mp4` with `AVAssetWriter`. It shares `WriterFeed`, `AudioPassthrough` and the chapter track with `ChapterWriter` (refactor in Task 4). `Finalizer.run` calls it after the mix has its chapters; a failure never fails the finalize.
- `RecorderModel.slidesOn` is the saved switch; screen problems and a failed video go into the existing warning line.

**Tech Stack:** Swift 6.4 with SwiftPM and Swift Testing, ScreenCaptureKit (`SCScreenshotManager`), CoreGraphics, ImageIO (HEIC), AVFoundation (`AVAssetWriter`, HEVC), CoreVideo, SwiftUI `MenuBarExtra`, ffprobe.

Spec: `docs/superpowers/specs/2026-09-28-dabber-screenshots-video-design.md`. Format model: `docs/superpowers/plans/2026-09-24-dabber-marks.md`.

## Ground rules for implementers

- Repo root: the repository root. Branch `claude/recordings-audio-screenshots-2c3d94` (a worktree). Never push.
- Commit messages: one line, `type: description`, no body, no trailers. `git add` by explicit path only; read `git diff --cached --stat` before every commit.
- Shell is zsh. Tests: `scripts/test.sh` only (bare `swift test` cannot find the Swift Testing macro plugin). Success means exit code 0 (`scripts/test.sh; echo "exit=$?"`), never grep for text. No Xcode, no `xcodebuild`. Never use `@State` or `@Bindable` (the SwiftUI macro plugin is not in the CLT toolchain); bind with `Binding(get:set:)` onto the model.
- Code: English, no comments. KISS. Swift 6 language mode. The diffs below are exact: apply them as shown, context lines included.
- Tasks marked **HUMAN** need the user. Stop there, tell the user exactly what to do in at most five short lines, and wait.
- Test counts assume the baseline of `af8dd1a`: **235 tests**. If `scripts/test.sh` reports a different baseline before Task 1, shift every expected count by the difference.

## Facts checked for this plan

The complete code of this plan was applied task by task to a clone of this branch at `af8dd1a` outside the repo, one commit per task (on 2026-09-28, macOS 26.7, Swift 6.4 CLT):
- `scripts/test.sh` exit 0 after every task, with 236, 241, 242, 242, 245, 249, 254, 259, 259, 259 tests. The `SlideRecorder` tests passed 300 repetitions; the whole suite 3 out of 3 after Task 8. Tasks 5, 6, 7 and 9 include four fixes found by the per-task code reviews during execution (writer cancel on a failed feed; frames kept when no video was made; no stale capture status after stop and a retry after a failed store; display lookup without the main thread so headless capture does not hang).
- `swift build` printed no Swift warnings. `scripts/build-app.sh` built and signed `build/Dabber.app`.
- A 10-minute sample made with `SlideshowWriter` (frames at 0:00, 4:00, 8:00; tones 220, 440, 660 Hz; chapters "Start", "Слайд 2", "Слайд 3"), checked with ffprobe:
  `codec_name=hevc|codec_tag_string=hvc1|width=1920|height=1080|duration=600.000000`, `codec_name=aac|codec_tag_string=mp4a|duration=600.000000`, a `tx3g` stream, the three chapters with exact times and UTF-8 titles, video packets `0.000000,K__`, `240.000000,K__`, `480.000000,K__`. File size 15.5 MB, of which the audio is 15.5 MB.
- Not checked: `LiveScreenGrabber` on the real screen, the Screen Recording prompt, the menu on screen, HEIC size of real screenshots, the change threshold on real screens, players other than ffprobe and AVFoundation. Task 11 covers these.

## Gate before Task 5: players

The user plays the 10-minute sample `sample.mp4` (handed over in chat) in QuickTime Player, VLC, iPhone Files and Telegram: picture, sound, seeking to about 5:00 and 9:00, chapters. If a player that matters shows no picture or cannot seek, stop and report; the fallback is H.264: in Task 5 use `AVVideoCodecType.h264` instead of `.hevc`, and in the Task 5 test expect `.h264` and `avc1` instead of `.hevc` and `hvc1`/`hev1`. If the check has not happened yet, do Tasks 1-4 and stop.

## Decisions

- `WriterFeed.run(writer)` cancels the writer when a lane fails or the feed times out, so no partial file is left (found by the Task 4 code review, fixed in Task 5, verified with a broken second frame).

- Capture: every 2 s, sleeping 2 s after each grab, so a slow grab never queues another. The capture time is the host clock read before the grab. The display is the one under the mouse pointer; ScreenCaptureKit is asked for the picture already scaled to at most 1920 wide (even sides), so `Frames.scaled` is only a safety net.
- Change rule: 64x36 gray thumbnail; changed when at least 4 thumbnail pixels differ by more than 24 of 255, or the display changed. Tested: a 2x20 px caret and a 60x12 px clock-sized area do not count, a 50x50 px area and a new slide do. The constants are `Frames.pixelDelta` and `Frames.changedPixels`; Task 11 checks them on real screens.
- Files: `frames/<offsetNanos>.heic`, quality 0.8. The manifest is saved after each kept frame.
- Video: `.mp4`, HEVC tagged `hvc1`, frame reordering off, a key frame at least every 60 s of media time (`SlideshowWriter.keyFrameSeconds`). Chapters are linked from the video and the audio track.
- The spec's "Screen: on" status line is dropped: the checked **Record slides** toggle already says it is on. Problems are warnings: `Screen: no permission (Privacy & Security > Screen & System Audio Recording)`, `Screen: <error>`, and after the finalize `Slides video failed: <error>` (cleared once the menu was seen). The spec is updated to match.
- `frames/` is deleted only when the `.mp4` was made (found by the Task 6 code review: a session without any audio would otherwise lose its only record).
- A failed video keeps `frames/` in the delivered folder, so the copy check across volumes (`Delivery.listing`) now compares every file in subfolders.
- Permission is asked at Record with `CGRequestScreenCaptureAccess()`. Without it the session records sound only and shows the warning.

## File structure

- `Sources/DabberCore/Slides/Frames.swift`: `Frames` (scale, thumbnail, change rule, HEIC, decode, render), `FrameSampler`.
- `Sources/DabberCore/Slides/SlideRecorder.swift`: `ScreenGrabber`, `ScreenGrab`, `ScreenStatus`, `SlideRecorder`.
- `Sources/DabberCore/Finalize/WriterFeed.swift`: `WriterFeed`, `AudioPassthrough`.
- `Sources/DabberCore/Finalize/SlideshowWriter.swift`: `Slide`, `SlideshowWriter`, `SlideshowError`.
- `Sources/Dabber/LiveScreenGrabber.swift`: ScreenCaptureKit capture.
- Modified: `SessionManifest`, `DiskCheck`, `SessionRecorder`, `ChapterWriter`, `Finalizer`, `Delivery`, `RecorderModel`, `AppDelegate`, `MenuApp`, `Headless`, both READMEs.

## Tasks

### Task 1: Frame records in the session manifest

**Files:**
- Modify: `Sources/DabberCore/Model/SessionManifest.swift`
- Modify: `Tests/DabberCoreTests/ManifestTests.swift`

`SessionManifest.frames` lists every kept screenshot: its offset from `sessionStartNanos` and its file `frames/<offsetNanos>.heic`. `FinalizeReport.slidesError` holds why the video could not be made. Old manifests without these keys still load.

- [ ] **Step 1: Write the failing tests**

`Tests/DabberCoreTests/ManifestTests.swift`:

```diff
@@ -72,3 +72,19 @@ import Testing
     #expect(AACWriter.bitRate(channels: 2) == 256_000)
     #expect(DiskCheck.secondsLeft(freeBytes: 652_000_000, channels: [2, 1], elapsedSeconds: 0) == 1_000)
 }
+
+@Test func framesAreNamedByOffsetAndOldManifestsHaveNone() throws {
+    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("m-\(UUID().uuidString)")
+    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
+    var m = SessionManifest(appVersion: "t", startedAt: Date(timeIntervalSince1970: 1_800_000_000), sessionStartNanos: 5_000)
+    #expect(m.addFrame(atNanos: 2_000_005_000) == FrameRecord(offsetNanos: 2_000_000_000, file: "frames/2000000000.heic"))
+    #expect(m.addFrame(atNanos: 10) == FrameRecord(offsetNanos: 0, file: "frames/0.heic"))
+    m.finalize = FinalizeReport(totalFrames: 1, gaps: [], driftMillis: [:], resampled: [], slidesError: "boom")
+    try m.save(to: dir)
+    #expect(try SessionManifest.load(from: dir) == m)
+    let old = #"{"appVersion":"t","startedAt":"2027-01-15T08:00:00Z","sessionStartNanos":1,"sources":[],"finalize":{"totalFrames":1,"gaps":[],"driftMillis":{},"resampled":[]}}"#
+    try Data(old.utf8).write(to: dir.appendingPathComponent("session.json"))
+    let loaded = try SessionManifest.load(from: dir)
+    #expect(loaded.frames.isEmpty)
+    #expect(loaded.finalize?.slidesError == nil)
+}
```

- [ ] **Step 2: Run the tests and see them fail**

Run: `scripts/test.sh; echo "exit=$?"`

Expected: build error: `SessionManifest` has no member `addFrame`, `FinalizeReport` has no argument `slidesError`. `exit=1`.

- [ ] **Step 3: Implement**

`Sources/DabberCore/Model/SessionManifest.swift`:

```diff
@@ -73,11 +73,23 @@ public struct FinalizeReport: Codable, Equatable, Sendable {
     public var gaps: [GapRecord]
     public var driftMillis: [String: Double]
     public var resampled: [String]
-    public init(totalFrames: Int, gaps: [GapRecord], driftMillis: [String: Double], resampled: [String]) {
+    public var slidesError: String?
+    public init(totalFrames: Int, gaps: [GapRecord], driftMillis: [String: Double], resampled: [String], slidesError: String? = nil) {
         self.totalFrames = totalFrames
         self.gaps = gaps
         self.driftMillis = driftMillis
         self.resampled = resampled
+        self.slidesError = slidesError
+    }
+}
+
+public struct FrameRecord: Codable, Equatable, Sendable {
+    public let offsetNanos: UInt64
+    public let file: String
+
+    public init(offsetNanos: UInt64, file: String) {
+        self.offsetNanos = offsetNanos
+        self.file = file
     }
 }
 
@@ -89,6 +101,7 @@ public struct SessionManifest: Codable, Equatable, Sendable {
     public var sessionStartNanos: UInt64
     public var sources: [SourceManifest] = []
     public var marks: [Mark] = []
+    public var frames: [FrameRecord] = []
     public var title = ""
     public var finalize: FinalizeReport?
 
@@ -98,7 +111,7 @@ public struct SessionManifest: Codable, Equatable, Sendable {
         self.sessionStartNanos = sessionStartNanos
     }
 
-    private enum CodingKeys: String, CodingKey { case appVersion, startedAt, sessionStartNanos, sources, marks, title, finalize }
+    private enum CodingKeys: String, CodingKey { case appVersion, startedAt, sessionStartNanos, sources, marks, frames, title, finalize }
 
     public var name: String { SessionNaming.sessionName(startedAt, title: title) }
 
@@ -109,6 +122,7 @@ public struct SessionManifest: Codable, Equatable, Sendable {
         sessionStartNanos = try c.decode(UInt64.self, forKey: .sessionStartNanos)
         sources = try c.decode([SourceManifest].self, forKey: .sources)
         marks = try c.decodeIfPresent([Mark].self, forKey: .marks) ?? []
+        frames = try c.decodeIfPresent([FrameRecord].self, forKey: .frames) ?? []
         title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
         finalize = try c.decodeIfPresent(FinalizeReport.self, forKey: .finalize)
     }
@@ -131,6 +145,16 @@ public struct SessionManifest: Codable, Equatable, Sendable {
         marks.removeAll { $0.id == id }
     }
 
+    public static let framesDir = "frames"
+
+    @discardableResult
+    public mutating func addFrame(atNanos: UInt64) -> FrameRecord {
+        let offset = atNanos > sessionStartNanos ? atNanos - sessionStartNanos : 0
+        let frame = FrameRecord(offsetNanos: offset, file: "\(Self.framesDir)/\(offset).heic")
+        frames.append(frame)
+        return frame
+    }
+
     public func save(to dir: URL) throws {
         let encoder = JSONEncoder()
         encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
```

- [ ] **Step 4: Run the tests**

Run: `scripts/test.sh; echo "exit=$?"`

Expected: `Test run with 236 tests in 2 suites passed`, `exit=0`.

- [ ] **Step 5: Commit**

```bash
git add "Sources/DabberCore/Model/SessionManifest.swift" "Tests/DabberCoreTests/ManifestTests.swift"
git diff --cached --stat
git commit -m "feat: frame records in the session manifest"
```

### Task 2: Frame scaling, change detection and HEIC encoding

**Files:**
- Create: `Sources/DabberCore/Slides/Frames.swift`
- Create: `Tests/DabberCoreTests/FramesTests.swift`

`Frames` holds the pure image helpers: fit into at most 1920 wide with even sides, a 64x36 gray thumbnail, the change rule (more than 3 thumbnail pixels differ by more than 24), HEIC at quality 0.8, decode. `FrameSampler` keeps the last kept thumbnail and display and returns HEIC data only for a changed screen or another display. The test helper `screen(...)` is shared with later tests.

- [ ] **Step 1: Write the failing tests**

`Tests/DabberCoreTests/FramesTests.swift` (new file):

```swift
import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import DabberCore

func screen(width: Int = 1920, height: Int = 1080, gray: CGFloat = 1, rects: [CGRect] = []) -> CGImage {
    let ctx = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
    ctx.setFillColor(CGColor(gray: gray, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
    ctx.setFillColor(CGColor(gray: 1 - gray, alpha: 1))
    for r in rects { ctx.fill(r) }
    return ctx.makeImage()!
}

@Test func framesFitIntoAtMost1920WideWithEvenSides() {
    #expect(Frames.fitSize(width: 3840, height: 2160) == (1920, 1080))
    #expect(Frames.fitSize(width: 1440, height: 900) == (1440, 900))
    #expect(Frames.fitSize(width: 3456, height: 2234) == (1920, 1240))
    #expect(Frames.fitSize(width: 1001, height: 601) == (1000, 600))
}

@Test func largeScreensAreScaledDown() throws {
    let big = try Frames.scaled(screen(width: 3840, height: 2160))
    #expect((big.width, big.height) == (1920, 1080))
    let small = screen(width: 1440, height: 900)
    #expect(try Frames.scaled(small) === small)
}

@Test func caretSizedChangesDoNotCountButContentDoes() throws {
    let base = try Frames.thumbnail(screen())
    #expect(!Frames.changed(base, base))
    #expect(!Frames.changed(base, try Frames.thumbnail(screen(rects: [CGRect(x: 900, y: 500, width: 2, height: 20)]))))
    #expect(!Frames.changed(base, try Frames.thumbnail(screen(rects: [CGRect(x: 1800, y: 1062, width: 60, height: 12)]))))
    #expect(Frames.changed(base, try Frames.thumbnail(screen(rects: [CGRect(x: 200, y: 200, width: 400, height: 300)]))))
    #expect(Frames.changed(base, try Frames.thumbnail(screen(gray: 0))))
}

@Test func heicRoundTripKeepsTheSize() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("f-\(UUID().uuidString).heic")
    let data = try Frames.heic(screen(rects: [CGRect(x: 100, y: 100, width: 300, height: 200)]))
    let source = CGImageSourceCreateWithData(data as CFData, nil)!
    #expect(CGImageSourceGetType(source) as String? == "public.heic")
    try data.write(to: url)
    let back = try Frames.decode(url)
    #expect((back.width, back.height) == (1920, 1080))
    #expect(throws: FrameError.self) { try Frames.decode(URL(fileURLWithPath: "/nonexistent.heic")) }
}

@Test func samplerKeepsOnlyChangedFramesAndDisplaySwitches() throws {
    let s = FrameSampler()
    #expect(try s.offer(screen(), display: 1) != nil)
    #expect(try s.offer(screen(), display: 1) == nil)
    #expect(try s.offer(screen(rects: [CGRect(x: 900, y: 500, width: 2, height: 20)]), display: 1) == nil)
    #expect(try s.offer(screen(), display: 2) != nil)
    #expect(try s.offer(screen(gray: 0), display: 2) != nil)
    #expect(try s.offer(screen(gray: 0, rects: [CGRect(x: 1800, y: 1062, width: 60, height: 12)]), display: 2) == nil)
}
```

- [ ] **Step 2: Run the tests and see them fail**

Run: `scripts/test.sh; echo "exit=$?"`

Expected: build error: cannot find `Frames` and `FrameSampler` in scope. `exit=1`.

- [ ] **Step 3: Implement**

`Sources/DabberCore/Slides/Frames.swift` (new file):

```swift
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum FrameError: Error, CustomStringConvertible {
    case draw
    case encode
    case decode(String)

    public var description: String {
        switch self {
        case .draw: return "could not draw frame"
        case .encode: return "could not encode frame"
        case .decode(let file): return "\(file): could not decode frame"
        }
    }
}

public enum Frames {
    public static let maxWidth = 1920
    public static let quality = 0.8
    static let thumbWidth = 64
    static let thumbHeight = 36
    static let pixelDelta = 24
    static let changedPixels = 4

    public static func fitSize(width: Int, height: Int) -> (width: Int, height: Int) {
        let w = min(width, maxWidth)
        let h = Int((Double(height) * Double(w) / Double(width)).rounded())
        return (max(2, w & ~1), max(2, h & ~1))
    }

    public static func scaled(_ image: CGImage) throws -> CGImage {
        let size = fitSize(width: image.width, height: image.height)
        if size.width == image.width, size.height == image.height { return image }
        return try draw(image, width: size.width, height: size.height)
    }

    public static func draw(_ image: CGImage?, width: Int, height: Int) throws -> CGImage {
        guard let ctx = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { throw FrameError.draw }
        ctx.setFillColor(CGColor(gray: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        if let image {
            ctx.interpolationQuality = .high
            ctx.draw(image, in: fit(image, width: width, height: height))
        }
        guard let out = ctx.makeImage() else { throw FrameError.draw }
        return out
    }

    static func fit(_ image: CGImage, width: Int, height: Int) -> CGRect {
        let scale = min(Double(width) / Double(image.width), Double(height) / Double(image.height))
        let w = Double(image.width) * scale, h = Double(image.height) * scale
        return CGRect(x: (Double(width) - w) / 2, y: (Double(height) - h) / 2, width: w, height: h)
    }

    public static func thumbnail(_ image: CGImage) throws -> [UInt8] {
        var pixels = [UInt8](repeating: 0, count: thumbWidth * thumbHeight)
        let drawn = pixels.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(
                data: raw.baseAddress, width: thumbWidth, height: thumbHeight, bitsPerComponent: 8,
                bytesPerRow: thumbWidth, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
            else { return false }
            ctx.interpolationQuality = .medium
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: thumbWidth, height: thumbHeight))
            return true
        }
        guard drawn else { throw FrameError.draw }
        return pixels
    }

    public static func changed(_ a: [UInt8], _ b: [UInt8]) -> Bool {
        zip(a, b).count { abs(Int($0) - Int($1)) > pixelDelta } >= changedPixels
    }

    public static func heic(_ image: CGImage) throws -> Data {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.heic.identifier as CFString, 1, nil) else {
            throw FrameError.encode
        }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw FrameError.encode }
        return data as Data
    }

    public static func decode(_ url: URL) throws -> CGImage {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { throw FrameError.decode(url.lastPathComponent) }
        return image
    }
}

public final class FrameSampler {
    private var last: (display: UInt32, thumb: [UInt8])?

    public init() {}

    public func offer(_ image: CGImage, display: UInt32) throws -> Data? {
        let frame = try Frames.scaled(image)
        let thumb = try Frames.thumbnail(frame)
        if let last, last.display == display, !Frames.changed(last.thumb, thumb) { return nil }
        let data = try Frames.heic(frame)
        last = (display, thumb)
        return data
    }
}
```

- [ ] **Step 4: Run the tests**

Run: `scripts/test.sh; echo "exit=$?"`

Expected: `Test run with 241 tests in 2 suites passed`, `exit=0`.

- [ ] **Step 5: Commit**

```bash
git add "Sources/DabberCore/Slides/Frames.swift" "Tests/DabberCoreTests/FramesTests.swift"
git diff --cached --stat
git commit -m "feat: frame scaling, change detection and HEIC encoding"
```

### Task 3: Session recorder stores frames and counts them in the disk estimate

**Files:**
- Modify: `Sources/DabberCore/Engine/SessionRecorder.swift`
- Modify: `Sources/DabberCore/Model/DiskCheck.swift`
- Modify: `Tests/DabberCoreTests/ManifestTests.swift`
- Modify: `Tests/DabberCoreTests/SessionRecorderTests.swift`

`SessionRecorder.addFrame(atNanos:data:)` writes the HEIC file and saves the manifest at once, under the recorder lock, only while recording. `start(... slides:)` tells the disk estimate to add the worst case for slides: 50 KB/s of frames while recording, plus the frames and a second copy of the mix audio in the output.

- [ ] **Step 1: Write the failing tests**

`Tests/DabberCoreTests/ManifestTests.swift`:

```diff
@@ -71,6 +71,7 @@ import Testing
     #expect(AACWriter.bitRate(channels: 1) == 96_000)
     #expect(AACWriter.bitRate(channels: 2) == 256_000)
     #expect(DiskCheck.secondsLeft(freeBytes: 652_000_000, channels: [2, 1], elapsedSeconds: 0) == 1_000)
+    #expect(DiskCheck.secondsLeft(freeBytes: 784_000_000, channels: [2, 1], elapsedSeconds: 0, slides: true) == 1_000)
 }
 
 @Test func framesAreNamedByOffsetAndOldManifestsHaveNone() throws {
```

`Tests/DabberCoreTests/SessionRecorderTests.swift`:

```diff
@@ -154,6 +154,19 @@ private let specs = [
         #expect(try SessionManifest.load(from: dir).title == "Планёрка ")
     }
 
+    @Test func framesAreWrittenAndSavedToTheManifestAtOnce() throws {
+        let (r, _) = try recorder()
+        let dir = try r.start(specs: specs, slides: true)
+        let start = try SessionManifest.load(from: dir).sessionStartNanos
+        #expect(try r.addFrame(atNanos: start + 2_000_000_000, data: Data([1, 2, 3])))
+        #expect(try SessionManifest.load(from: dir).frames == [FrameRecord(offsetNanos: 2_000_000_000, file: "frames/2000000000.heic")])
+        #expect(try Data(contentsOf: dir.appendingPathComponent("frames/2000000000.heic")) == Data([1, 2, 3]))
+        _ = r.stop()
+        #expect(try !r.addFrame(atNanos: start + 4_000_000_000, data: Data([4])))
+        #expect(try SessionManifest.load(from: dir).frames.count == 1)
+        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("frames/4000000000.heic").path))
+    }
+
     @Test func stopWithoutStartReturnsNil() throws {
         let (r, _) = try recorder()
         #expect(r.stop() == nil)
```

- [ ] **Step 2: Run the tests and see them fail**

Run: `scripts/test.sh; echo "exit=$?"`

Expected: build error: extra argument `slides` in `start` and in `secondsLeft`, no member `addFrame`. `exit=1`.

- [ ] **Step 3: Implement**

`Sources/DabberCore/Engine/SessionRecorder.swift`:

```diff
@@ -50,6 +50,7 @@ public final class SessionRecorder: @unchecked Sendable {
     private var lastError: String?
     private var lastDiskCheck: Date?
     private var diskWarning: String?
+    private var slides = false
     public private(set) var lastSessionDir: URL?
 
     public init(
@@ -71,7 +72,7 @@ public final class SessionRecorder: @unchecked Sendable {
     }
 
     @discardableResult
-    public func start(specs: [SourceSpec], title: String = "", at date: Date = Date()) throws -> URL {
+    public func start(specs: [SourceSpec], title: String = "", slides: Bool = false, at date: Date = Date()) throws -> URL {
         lock.lock(); defer { lock.unlock() }
         guard state.phase == .idle else { throw RecorderError.busy }
         guard !specs.isEmpty else { throw RecorderError.noSources }
@@ -111,6 +112,7 @@ public final class SessionRecorder: @unchecked Sendable {
         lastError = nil
         lastDiskCheck = nil
         diskWarning = nil
+        self.slides = slides
         _ = state.start()
         sleepWatcher = SleepWatcher(
             willSleep: { [weak self] in self?.forEachSource { $0.pause() } },
@@ -172,6 +174,19 @@ public final class SessionRecorder: @unchecked Sendable {
 
     public func setTitle(_ title: String) { _ = edit { $0.title = title } }
 
+    @discardableResult
+    public func addFrame(atNanos: UInt64, data: Data) throws -> Bool {
+        lock.lock(); defer { lock.unlock() }
+        guard state.phase == .recording, var manifest, let dir else { return false }
+        let frame = manifest.addFrame(atNanos: atNanos)
+        let url = dir.appendingPathComponent(frame.file)
+        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
+        try data.write(to: url, options: .atomic)
+        self.manifest = manifest
+        try manifest.save(to: dir)
+        return true
+    }
+
     private func edit(_ change: (inout SessionManifest) -> Void) -> SessionManifest? {
         lock.lock(); defer { lock.unlock() }
         guard state.phase == .recording, var manifest, let dir else { return nil }
@@ -214,7 +229,8 @@ public final class SessionRecorder: @unchecked Sendable {
         lastDiskCheck = now
         guard let free = try? freeBytes(dir) else { return nil }
         let left = DiskCheck.secondsLeft(
-            freeBytes: free, channels: sources.map(\.writer.channels), elapsedSeconds: now.timeIntervalSince(startedAt))
+            freeBytes: free, channels: sources.map(\.writer.channels), elapsedSeconds: now.timeIntervalSince(startedAt),
+            slides: slides)
         diskWarning = left < DiskCheck.warnSeconds
             ? "disk space low: about \(max(0, Int(left / 60))) min of recording left" : nil
         return left < DiskCheck.stopSeconds ? free : nil
```

`Sources/DabberCore/Model/DiskCheck.swift`:

```diff
@@ -7,9 +7,13 @@ public enum DiskCheck {
     public static let warnSeconds: Double = 20 * 60
     public static let stopSeconds: Double = 2 * 60
 
-    public static func secondsLeft(freeBytes: Int64, channels: [Int], elapsedSeconds: Double) -> Double {
-        let caf = Double(channels.reduce(0, +) * MemoryLayout<Float>.size * Timeline.rate)
-        let m4a = Double((channels + [2]).map(AACWriter.bitRate).reduce(0, +)) / 8
+    public static let slidesBytesPerSecond = 50_000
+
+    public static func secondsLeft(freeBytes: Int64, channels: [Int], elapsedSeconds: Double, slides: Bool = false) -> Double {
+        let frames = slides ? Double(slidesBytesPerSecond) : 0
+        let caf = Double(channels.reduce(0, +) * MemoryLayout<Float>.size * Timeline.rate) + frames
+        let mixCopy = slides ? Double(AACWriter.bitRate(channels: 2)) / 8 : 0
+        let m4a = Double((channels + [2]).map(AACWriter.bitRate).reduce(0, +)) / 8 + frames + mixCopy
         return (Double(freeBytes) - m4a * elapsedSeconds) / (caf + m4a)
     }
```

- [ ] **Step 4: Run the tests**

Run: `scripts/test.sh; echo "exit=$?"`

Expected: `Test run with 242 tests in 2 suites passed`, `exit=0`.

- [ ] **Step 5: Commit**

```bash
git add "Sources/DabberCore/Engine/SessionRecorder.swift" "Sources/DabberCore/Model/DiskCheck.swift" "Tests/DabberCoreTests/ManifestTests.swift" "Tests/DabberCoreTests/SessionRecorderTests.swift"
git diff --cached --stat
git commit -m "feat: session recorder stores frames and counts them in the disk estimate"
```

### Task 4: Shared writer feed, audio passthrough and chapter lane

**Files:**
- Modify: `Sources/DabberCore/Finalize/ChapterWriter.swift`
- Create: `Sources/DabberCore/Finalize/WriterFeed.swift`

Pure refactor so the video writer can reuse what `ChapterWriter` does. `WriterFeed` feeds any number of `AVAssetWriterInput`s from pull closures (one queue per input) and passes on the first error. `AudioPassthrough` opens the audio track of a file for copying without re-encoding. `ChapterWriter.chapterLane` adds the disabled `tx3g` chapter track linked from the given tracks; `titleMetadata` builds the title tag. No behaviour change: the existing chapter tests must pass unchanged.

- [ ] **Step 1: Make the change**

`Sources/DabberCore/Finalize/ChapterWriter.swift`:

```diff
@@ -19,47 +19,20 @@ public enum ChapterWriter {
     public static func write(_ chapters: [Chapter], title: String? = nil, into url: URL) throws {
         let name = url.lastPathComponent
         let frames = try AVAudioFile(forReading: url).length
-        let movie = AVMovie(url: url)
-        guard let track = movie.tracks.first(where: { $0.mediaType == .audio }) else { throw ChapterError.noAudio(name) }
-        let reader = try AVAssetReader(asset: movie)
-        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
-        reader.add(output)
-        guard reader.startReading(), let first = output.copyNextSampleBuffer(), let audioFormat = first.formatDescription else {
-            throw ChapterError.noAudio(name)
-        }
+        let source = try AudioPassthrough(url)
         let temp = try FileManager.default.url(
             for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: url, create: true)
         defer { try? FileManager.default.removeItem(at: temp) }
         let out = temp.appendingPathComponent(name)
         let writer = try AVAssetWriter(outputURL: out, fileType: .m4a)
-        if let title {
-            let item = AVMutableMetadataItem()
-            item.identifier = .commonIdentifierTitle
-            item.value = title as NSString
-            writer.metadata = [item]
-        }
-        let audio = AVAssetWriterInput(mediaType: .audio, outputSettings: nil, sourceFormatHint: audioFormat)
+        writer.metadata = titleMetadata(title)
+        let audio = AVAssetWriterInput(mediaType: .audio, outputSettings: nil, sourceFormatHint: source.format)
         writer.add(audio)
         let end = CMTime(value: frames, timescale: CMTimeScale(Timeline.rate))
-        var text: AVAssetWriterInput?
-        var samples: [CMSampleBuffer] = []
-        if !chapters.isEmpty {
-            let textFormat = try Self.textFormat()
-            let input = AVAssetWriterInput(mediaType: .text, outputSettings: nil, sourceFormatHint: textFormat)
-            input.marksOutputTrackAsEnabled = false
-            writer.add(input)
-            audio.addTrackAssociation(withTrackOf: input, type: AVAssetTrack.AssociationType.chapterList.rawValue)
-            samples = try chapters.indices.map { i in
-                let start = CMTime(value: CMTimeValue(chapters[i].startMillis), timescale: 1000)
-                let next = i + 1 < chapters.count ? CMTime(value: CMTimeValue(chapters[i + 1].startMillis), timescale: 1000) : end
-                return try Self.sample(chapters[i].title, start: start, duration: next - start, format: textFormat)
-            }
-            text = input
-        }
+        let text = try chapterLane(chapters, end: end, writer: writer, linkedFrom: [audio])
         guard writer.startWriting() else { throw ChapterError.write(name, "\(writer.error.map { "\($0)" } ?? "start")") }
         writer.startSession(atSourceTime: .zero)
-        let feed = Feed(audio: audio, text: text, output: output, first: first, samples: samples)
-        guard feed.run() else {
+        guard try WriterFeed([source.lane(audio)] + (text.map { [$0] } ?? [])).run() else {
             writer.cancelWriting()
             throw ChapterError.write(name, "timed out")
         }
@@ -67,8 +40,8 @@ public enum ChapterWriter {
         let done = DispatchSemaphore(value: 0)
         writer.finishWriting { done.signal() }
         done.wait()
-        guard writer.status == .completed, reader.status == .completed else {
-            throw ChapterError.write(name, "\(writer.error ?? reader.error.map { $0 as any Error } ?? ChapterError.noAudio(name))")
+        guard writer.status == .completed, source.reader.status == .completed else {
+            throw ChapterError.write(name, "\(writer.error ?? source.reader.error.map { $0 as any Error } ?? ChapterError.noAudio(name))")
         }
         let written = try AVAudioFile(forReading: out).length
         guard written == frames else {
@@ -77,52 +50,31 @@ public enum ChapterWriter {
         _ = try FileManager.default.replaceItemAt(url, withItemAt: out)
     }
 
-    private final class Feed: @unchecked Sendable {
-        let audio: AVAssetWriterInput
-        let text: AVAssetWriterInput?
-        let output: AVAssetReaderTrackOutput
-        var first: CMSampleBuffer?
-        var samples: [CMSampleBuffer]
-        let group = DispatchGroup()
-
-        init(audio: AVAssetWriterInput, text: AVAssetWriterInput?, output: AVAssetReaderTrackOutput,
-             first: CMSampleBuffer, samples: [CMSampleBuffer]) {
-            self.audio = audio
-            self.text = text
-            self.output = output
-            self.first = first
-            self.samples = samples
-        }
-
-        func run() -> Bool {
-            if let text {
-                group.enter()
-                text.requestMediaDataWhenReady(on: DispatchQueue(label: "dabber.chapters.text")) { self.feedText() }
-            }
-            group.enter()
-            audio.requestMediaDataWhenReady(on: DispatchQueue(label: "dabber.chapters.audio")) { self.feedAudio() }
-            return group.wait(timeout: .now() + 600) == .success
-        }
-
-        private func feedText() {
-            guard let text else { return }
-            while text.isReadyForMoreMediaData {
-                guard !samples.isEmpty, text.append(samples.removeFirst()) else { return finish(text) }
-            }
-        }
+    static func titleMetadata(_ title: String?) -> [AVMetadataItem] {
+        guard let title else { return [] }
+        let item = AVMutableMetadataItem()
+        item.identifier = .commonIdentifierTitle
+        item.value = title as NSString
+        return [item]
+    }
 
-        private func feedAudio() {
-            while audio.isReadyForMoreMediaData {
-                let next = first ?? output.copyNextSampleBuffer()
-                first = nil
-                guard let next, audio.append(next) else { return finish(audio) }
-            }
+    static func chapterLane(
+        _ chapters: [Chapter], end: CMTime, writer: AVAssetWriter, linkedFrom tracks: [AVAssetWriterInput]
+    ) throws -> WriterFeed.Lane? {
+        guard !chapters.isEmpty else { return nil }
+        let format = try textFormat()
+        let input = AVAssetWriterInput(mediaType: .text, outputSettings: nil, sourceFormatHint: format)
+        input.marksOutputTrackAsEnabled = false
+        writer.add(input)
+        for track in tracks {
+            track.addTrackAssociation(withTrackOf: input, type: AVAssetTrack.AssociationType.chapterList.rawValue)
         }
-
-        private func finish(_ input: AVAssetWriterInput) {
-            input.markAsFinished()
-            group.leave()
+        var samples = try chapters.indices.map { i in
+            let start = CMTime(value: CMTimeValue(chapters[i].startMillis), timescale: 1000)
+            let next = i + 1 < chapters.count ? CMTime(value: CMTimeValue(chapters[i + 1].startMillis), timescale: 1000) : end
+            return try sample(chapters[i].title, start: start, duration: next - start, format: format)
         }
+        return (input, { samples.isEmpty ? nil : samples.removeFirst() })
     }
 
     private static func sample(_ title: String, start: CMTime, duration: CMTime, format: CMFormatDescription) throws -> CMSampleBuffer {
```

`Sources/DabberCore/Finalize/WriterFeed.swift` (new file):

```swift
import AVFoundation

final class WriterFeed: @unchecked Sendable {
    typealias Lane = (input: AVAssetWriterInput, next: () throws -> CMSampleBuffer?)

    private let lanes: [Lane]
    private let group = DispatchGroup()
    private let lock = NSLock()
    private var failure: (any Error)?

    init(_ lanes: [Lane]) {
        self.lanes = lanes
    }

    func run(timeout: TimeInterval = 600) throws -> Bool {
        for i in lanes.indices {
            group.enter()
            lanes[i].input.requestMediaDataWhenReady(on: DispatchQueue(label: "dabber.feed.\(i)")) { self.feed(i) }
        }
        guard group.wait(timeout: .now() + timeout) == .success else { return false }
        if let failure = lock.withLock({ failure }) { throw failure }
        return true
    }

    private func feed(_ i: Int) {
        let lane = lanes[i]
        while lane.input.isReadyForMoreMediaData {
            do {
                guard let next = try lane.next(), lane.input.append(next) else { return finish(lane.input) }
            } catch {
                lock.withLock { failure = failure ?? error }
                return finish(lane.input)
            }
        }
    }

    private func finish(_ input: AVAssetWriterInput) {
        input.markAsFinished()
        group.leave()
    }
}

struct AudioPassthrough {
    let reader: AVAssetReader
    let format: CMFormatDescription
    let lane: (AVAssetWriterInput) -> WriterFeed.Lane

    init(_ url: URL) throws {
        let name = url.lastPathComponent
        let movie = AVMovie(url: url)
        guard let track = movie.tracks.first(where: { $0.mediaType == .audio }) else { throw ChapterError.noAudio(name) }
        let reader = try AVAssetReader(asset: movie)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        reader.add(output)
        guard reader.startReading(), let first = output.copyNextSampleBuffer(), let format = first.formatDescription else {
            throw ChapterError.noAudio(name)
        }
        self.reader = reader
        self.format = format
        lane = { input in
            var pending: CMSampleBuffer? = first
            return (input, {
                if let buffer = pending {
                    pending = nil
                    return buffer
                }
                return output.copyNextSampleBuffer()
            })
        }
    }
}
```

- [ ] **Step 2: Run the tests**

Run: `scripts/test.sh; echo "exit=$?"`

Expected: `Test run with 242 tests in 2 suites passed`, `exit=0`.

- [ ] **Step 3: Commit**

```bash
git add "Sources/DabberCore/Finalize/ChapterWriter.swift" "Sources/DabberCore/Finalize/WriterFeed.swift"
git diff --cached --stat
git commit -m "refactor: shared writer feed, audio passthrough and chapter lane"
```

### Task 5: Slideshow writer

**Files:**
- Modify: `Sources/DabberCore/Finalize/ChapterWriter.swift`
- Create: `Sources/DabberCore/Finalize/SlideshowWriter.swift`
- Modify: `Sources/DabberCore/Finalize/WriterFeed.swift`
- Modify: `Sources/DabberCore/Slides/Frames.swift`
- Modify: `Tests/DabberCoreTests/FinalizerTests.swift`

`SlideshowWriter.write` makes the `.mp4`: HEVC video (`hvc1`), audio copied from the mix, chapters linked from both tracks, the title tag. One video sample per frame at its time, a black sample at 0 if the first frame is later, frames at or after the end of the audio dropped, of two frames with the same time the later wins. The size is the first frame's; other sizes are letterboxed. Frame reordering is off (without it the encoder stored the samples as 0, 2, 1) and a key frame comes at least every 60 s of media time, so seeking stays fast. It also changes `WriterFeed.run` to take the writer and cancel it on a failed lane or a timeout (a code review of Task 4 found that a throwing lane skipped `cancelWriting()`, which left a partial `.mp4` behind; the new test case for a broken second frame proves the file is gone). Both writers call `try WriterFeed(...).run(writer)`.

- [ ] **Step 1: Write the failing tests**

`Tests/DabberCoreTests/FinalizerTests.swift`:

```diff
@@ -1,4 +1,5 @@
 import AVFoundation
+import CoreGraphics
 import AudioToolbox
 import Foundation
 import Testing
@@ -492,3 +493,91 @@ extension FinalizerTests {
         #expect(try FileManager.default.contentsOfDirectory(atPath: work.path).isEmpty)
     }
 }
+
+extension FinalizerTests {
+    private func slide(_ dir: URL, atSeconds s: Double, _ image: CGImage) throws -> Slide {
+        let url = dir.appendingPathComponent("\(s).heic")
+        try Frames.heic(image).write(to: url)
+        return Slide(offsetNanos: UInt64(s * 1e9), url: url)
+    }
+
+    private func videoTimes(_ url: URL) throws -> [Double] {
+        let movie = AVMovie(url: url)
+        let reader = try AVAssetReader(asset: movie)
+        let output = AVAssetReaderTrackOutput(track: movie.tracks.first { $0.mediaType == .video }!, outputSettings: nil)
+        reader.add(output)
+        #expect(reader.startReading())
+        var times: [Double] = []
+        while let buffer = output.copyNextSampleBuffer() {
+            if buffer.numSamples > 0 { times.append((buffer.presentationTimeStamp.seconds * 1000).rounded() / 1000) }
+        }
+        return times
+    }
+
+    @Test func slideTimesStartBlackDropLateFramesAndKeepTheLaterOfTwins() {
+        let a = URL(fileURLWithPath: "/a"), b = URL(fileURLWithPath: "/b"), c = URL(fileURLWithPath: "/c")
+        let times = SlideshowWriter.times(
+            [Slide(offsetNanos: 2_000, url: b), Slide(offsetNanos: 1_000, url: a), Slide(offsetNanos: 2_000, url: c), Slide(offsetNanos: 9_000, url: a)],
+            endNanos: 5_000)
+        #expect(times.map(\.atNanos) == [0, 1_000, 2_000])
+        #expect(times.map(\.slide?.url) == [nil, a, c])
+        #expect(SlideshowWriter.times([Slide(offsetNanos: 0, url: a)], endNanos: 5_000).map(\.atNanos) == [0])
+        #expect(SlideshowWriter.times([], endNanos: 5_000).isEmpty)
+    }
+
+    @Test func slideshowIsHEVCWithTheSameAudioChaptersAndTitle() async throws {
+        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sl-\(UUID().uuidString)")
+        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
+        let audio = dir.appendingPathComponent("mix.m4a")
+        let writer = try AACWriter(url: audio, channels: 2)
+        try writer.write(sine(frames: 144_000, channels: 2))
+        try writer.closeAndVerify()
+        let slides = [
+            try slide(dir, atSeconds: 1, screen(rects: [CGRect(x: 100, y: 100, width: 300, height: 200)])),
+            try slide(dir, atSeconds: 2, screen(width: 1440, height: 900, gray: 0)),
+        ]
+        let out = dir.appendingPathComponent("mix.mp4")
+        try SlideshowWriter.write(
+            audio: audio, slides: slides, chapters: [Chapter(startMillis: 0, title: "Start"), Chapter(startMillis: 1_500, title: "про деньги")],
+            title: "Созвон", to: out)
+        #expect(try videoTimes(out) == [0, 1, 2])
+        let asset = AVURLAsset(url: out)
+        let track = try await asset.loadTracks(withMediaType: .video).first!
+        let format = try await track.load(.formatDescriptions).first!
+        #expect(format.mediaSubType == .hevc)
+        #expect(format.dimensions.width == 1920 && format.dimensions.height == 1080)
+        let range = try await track.load(.timeRange)
+        #expect(abs(range.end.seconds - 3) < 0.01)
+        #expect(try audioBytes(out) == audioBytes(audio))
+        #expect(try await chapterList(out) == ["0.000 Start", "1.500 про деньги"])
+        #expect(try await titleTag(out) == "Созвон")
+        let bytes = try Data(contentsOf: out)
+        #expect(bytes.range(of: Data("hvc1".utf8)) != nil)
+        #expect(bytes.range(of: Data("hev1".utf8)) == nil)
+    }
+
+    @Test func slideshowWithoutUsableFramesFails() throws {
+        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sl-\(UUID().uuidString)")
+        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
+        let audio = dir.appendingPathComponent("mix.m4a")
+        let writer = try AACWriter(url: audio, channels: 2)
+        try writer.write(sine(frames: 48_000, channels: 2))
+        try writer.closeAndVerify()
+        let late = try slide(dir, atSeconds: 5, screen())
+        #expect(throws: SlideshowError.self) {
+            try SlideshowWriter.write(audio: audio, slides: [late], chapters: [], title: nil, to: dir.appendingPathComponent("mix.mp4"))
+        }
+        let missing = Slide(offsetNanos: 0, url: dir.appendingPathComponent("gone.heic"))
+        #expect(throws: FrameError.self) {
+            try SlideshowWriter.write(audio: audio, slides: [missing], chapters: [], title: nil, to: dir.appendingPathComponent("mix.mp4"))
+        }
+        let good = try slide(dir, atSeconds: 0, screen())
+        let broken = dir.appendingPathComponent("broken.heic")
+        try Data([1, 2, 3]).write(to: broken)
+        let out = dir.appendingPathComponent("mix.mp4")
+        #expect(throws: FrameError.self) {
+            try SlideshowWriter.write(audio: audio, slides: [good, Slide(offsetNanos: 500_000_000, url: broken)], chapters: [], title: nil, to: out)
+        }
+        #expect(!FileManager.default.fileExists(atPath: out.path))
+    }
+}
```

- [ ] **Step 2: Run the tests and see them fail**

Run: `scripts/test.sh; echo "exit=$?"`

Expected: build error: cannot find `Slide`, `SlideshowWriter` and `SlideshowError` in scope. `exit=1`.

- [ ] **Step 3: Implement**

`Sources/DabberCore/Finalize/ChapterWriter.swift`:

```diff
@@ -32,10 +32,7 @@ public enum ChapterWriter {
         let text = try chapterLane(chapters, end: end, writer: writer, linkedFrom: [audio])
         guard writer.startWriting() else { throw ChapterError.write(name, "\(writer.error.map { "\($0)" } ?? "start")") }
         writer.startSession(atSourceTime: .zero)
-        guard try WriterFeed([source.lane(audio)] + (text.map { [$0] } ?? [])).run() else {
-            writer.cancelWriting()
-            throw ChapterError.write(name, "timed out")
-        }
+        try WriterFeed([source.lane(audio)] + (text.map { [$0] } ?? [])).run(writer)
         writer.endSession(atSourceTime: end)
         let done = DispatchSemaphore(value: 0)
         writer.finishWriting { done.signal() }
```

`Sources/DabberCore/Finalize/SlideshowWriter.swift` (new file):

```swift
import AVFoundation
import CoreVideo

public enum SlideshowError: Error, CustomStringConvertible {
    case noFrames
    case pixelBuffer(Int32)
    case write(String)

    public var description: String {
        switch self {
        case .noFrames: return "no frames"
        case .pixelBuffer(let status): return "pixel buffer: \(status)"
        case .write(let why): return "writing video failed: \(why)"
        }
    }
}

public struct Slide: Equatable, Sendable {
    public let offsetNanos: UInt64
    public let url: URL

    public init(offsetNanos: UInt64, url: URL) {
        self.offsetNanos = offsetNanos
        self.url = url
    }
}

public enum SlideshowWriter {
    public static let keyFrameSeconds = 60.0

    public static func write(audio: URL, slides: [Slide], chapters: [Chapter], title: String?, to out: URL) throws {
        let frames = try AVAudioFile(forReading: audio).length
        let end = CMTime(value: frames, timescale: CMTimeScale(Timeline.rate))
        let shown = times(slides, endNanos: UInt64(frames) * 1_000_000_000 / UInt64(Timeline.rate))
        guard let first = shown.first(where: { $0.slide != nil })?.slide else { throw SlideshowError.noFrames }
        let firstImage = try Frames.decode(first.url)
        let size = Frames.fitSize(width: firstImage.width, height: firstImage.height)
        let source = try AudioPassthrough(audio)
        try? FileManager.default.removeItem(at: out)
        let writer = try AVAssetWriter(outputURL: out, fileType: .mp4)
        writer.metadata = ChapterWriter.titleMetadata(title)
        let video = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.hevc, AVVideoWidthKey: size.width, AVVideoHeightKey: size.height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAllowFrameReorderingKey: false, AVVideoMaxKeyFrameIntervalDurationKey: keyFrameSeconds,
            ],
        ])
        writer.add(video)
        let sound = AVAssetWriterInput(mediaType: .audio, outputSettings: nil, sourceFormatHint: source.format)
        writer.add(sound)
        let text = try ChapterWriter.chapterLane(chapters, end: end, writer: writer, linkedFrom: [video, sound])
        var index = 0
        let pictures: WriterFeed.Lane = (video, {
            guard index < shown.count else { return nil }
            let item = shown[index]
            index += 1
            let next = index < shown.count ? time(shown[index].atNanos) : end
            let image = try item.slide.map { try Frames.decode($0.url) }
            return try sample(image, width: size.width, height: size.height, at: time(item.atNanos), until: next)
        })
        guard writer.startWriting() else { throw SlideshowError.write("\(writer.error.map { "\($0)" } ?? "start")") }
        writer.startSession(atSourceTime: .zero)
        try WriterFeed([pictures, source.lane(sound)] + (text.map { [$0] } ?? [])).run(writer)
        writer.endSession(atSourceTime: end)
        let done = DispatchSemaphore(value: 0)
        writer.finishWriting { done.signal() }
        done.wait()
        guard writer.status == .completed, source.reader.status == .completed else {
            throw SlideshowError.write("\(writer.error ?? source.reader.error.map { $0 as any Error } ?? SlideshowError.noFrames)")
        }
    }

    static func times(_ slides: [Slide], endNanos: UInt64) -> [(atNanos: UInt64, slide: Slide?)] {
        var out: [(atNanos: UInt64, slide: Slide?)] = []
        for slide in slides.sorted(by: { $0.offsetNanos < $1.offsetNanos }) where slide.offsetNanos < endNanos {
            if out.last?.atNanos == slide.offsetNanos { out.removeLast() }
            out.append((slide.offsetNanos, slide))
        }
        if out.first.map({ $0.atNanos > 0 }) ?? false { out.insert((0, nil), at: 0) }
        return out
    }

    private static func time(_ nanos: UInt64) -> CMTime { CMTime(value: CMTimeValue(nanos), timescale: 1_000_000_000) }

    private static func sample(_ image: CGImage?, width: Int, height: Int, at start: CMTime, until next: CMTime) throws -> CMSampleBuffer {
        var buffer: CVPixelBuffer?
        let attrs: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary]
        var status = CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, attrs as CFDictionary, &buffer)
        guard status == kCVReturnSuccess, let buffer else { throw SlideshowError.pixelBuffer(status) }
        CVPixelBufferLockBaseAddress(buffer, [])
        let ctx = Frames.context(
            CVPixelBufferGetBaseAddress(buffer), width: width, height: height, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer))
        if let ctx { Frames.render(image, in: ctx, width: width, height: height) }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        guard ctx != nil else { throw FrameError.draw }
        var format: CMVideoFormatDescription?
        status = CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: buffer, formatDescriptionOut: &format)
        guard status == noErr, let format else { throw SlideshowError.pixelBuffer(status) }
        var timing = CMSampleTimingInfo(duration: next - start, presentationTimeStamp: start, decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        status = CMSampleBufferCreateReadyWithImageBuffer(
            allocator: nil, imageBuffer: buffer, formatDescription: format, sampleTiming: &timing, sampleBufferOut: &sample)
        guard status == noErr, let sample else { throw SlideshowError.pixelBuffer(status) }
        return sample
    }
}
```

`Sources/DabberCore/Finalize/WriterFeed.swift`:

```diff
@@ -1,5 +1,9 @@
 import AVFoundation
 
+struct FeedTimedOut: Error, CustomStringConvertible {
+    var description: String { "timed out" }
+}
+
 final class WriterFeed: @unchecked Sendable {
     typealias Lane = (input: AVAssetWriterInput, next: () throws -> CMSampleBuffer?)
 
@@ -12,14 +16,16 @@ final class WriterFeed: @unchecked Sendable {
         self.lanes = lanes
     }
 
-    func run(timeout: TimeInterval = 600) throws -> Bool {
+    func run(_ writer: AVAssetWriter, timeout: TimeInterval = 600) throws {
         for i in lanes.indices {
             group.enter()
             lanes[i].input.requestMediaDataWhenReady(on: DispatchQueue(label: "dabber.feed.\(i)")) { self.feed(i) }
         }
-        guard group.wait(timeout: .now() + timeout) == .success else { return false }
-        if let failure = lock.withLock({ failure }) { throw failure }
-        return true
+        let done = group.wait(timeout: .now() + timeout) == .success
+        if let error = lock.withLock({ failure }) ?? (done ? nil : FeedTimedOut()) {
+            writer.cancelWriting()
+            throw error
+        }
     }
 
     private func feed(_ i: Int) {
```

`Sources/DabberCore/Slides/Frames.swift`:

```diff
@@ -38,19 +38,25 @@ public enum Frames {
     }
 
     public static func draw(_ image: CGImage?, width: Int, height: Int) throws -> CGImage {
-        guard let ctx = CGContext(
-            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
+        guard let ctx = context(nil, width: width, height: height, bytesPerRow: 0) else { throw FrameError.draw }
+        render(image, in: ctx, width: width, height: height)
+        guard let out = ctx.makeImage() else { throw FrameError.draw }
+        return out
+    }
+
+    static func context(_ data: UnsafeMutableRawPointer?, width: Int, height: Int, bytesPerRow: Int) -> CGContext? {
+        CGContext(
+            data: data, width: width, height: height, bitsPerComponent: 8, bytesPerRow: bytesPerRow,
             space: CGColorSpace(name: CGColorSpace.sRGB)!,
             bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
-        else { throw FrameError.draw }
+    }
+
+    static func render(_ image: CGImage?, in ctx: CGContext, width: Int, height: Int) {
         ctx.setFillColor(CGColor(gray: 0, alpha: 1))
         ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
-        if let image {
-            ctx.interpolationQuality = .high
-            ctx.draw(image, in: fit(image, width: width, height: height))
-        }
-        guard let out = ctx.makeImage() else { throw FrameError.draw }
-        return out
+        guard let image else { return }
+        ctx.interpolationQuality = .high
+        ctx.draw(image, in: fit(image, width: width, height: height))
     }
 
     static func fit(_ image: CGImage, width: Int, height: Int) -> CGRect {
```

- [ ] **Step 4: Run the tests**

Run: `scripts/test.sh; echo "exit=$?"`

Expected: `Test run with 245 tests in 2 suites passed`, `exit=0`.

- [ ] **Step 5: Commit**

```bash
git add "Sources/DabberCore/Finalize/ChapterWriter.swift" "Sources/DabberCore/Finalize/SlideshowWriter.swift" "Sources/DabberCore/Finalize/WriterFeed.swift" "Sources/DabberCore/Slides/Frames.swift" "Tests/DabberCoreTests/FinalizerTests.swift"
git diff --cached --stat
git commit -m "feat: slideshow writer builds an HEVC mp4 from frames and the mix"
```

### Task 6: Finalize builds the slideshow video

**Files:**
- Modify: `Sources/DabberCore/Finalize/Delivery.swift`
- Modify: `Sources/DabberCore/Finalize/Finalizer.swift`
- Modify: `Tests/DabberCoreTests/DeliveryTests.swift`
- Modify: `Tests/DabberCoreTests/FinalizerTests.swift`

After the mix has its chapters, `Finalizer.run` makes `mix.mp4` from the frames whose files exist. When the `.mp4` exists, `frames/` is deleted after the report is saved; otherwise (failure, or a session without any audio) the frames are kept. Failure removes the partial `.mp4`, keeps `frames/` and writes the error into the report; the audio files are delivered as usual. `rename` renames `mix.mp4` with the mix. Because `frames/` can now reach delivery, the copy check across volumes compares every file in subfolders, not only the top level.

- [ ] **Step 1: Write the failing tests**

`Tests/DabberCoreTests/DeliveryTests.swift`:

```diff
@@ -98,6 +98,24 @@ private let otherVolume = Mover(move: { _, _ in throw DeliveryError.otherVolume
     }
 }
 
+@Test func acrossVolumesFilesInSubfoldersAreCheckedToo() throws {
+    let work = try temp("work"), out = try temp("out")
+    let dir = try session(in: work, folder: name)
+    try FileManager.default.createDirectory(at: dir.appendingPathComponent("frames"), withIntermediateDirectories: false)
+    try audio.write(to: dir.appendingPathComponent("frames/1.heic"))
+    let moved = try Delivery.deliver(dir, into: out, mover: otherVolume)
+    #expect(try Data(contentsOf: moved.appendingPathComponent("frames/1.heic")) == audio)
+    let dir2 = try session(in: work, folder: name)
+    try FileManager.default.createDirectory(at: dir2.appendingPathComponent("frames"), withIntermediateDirectories: false)
+    try audio.write(to: dir2.appendingPathComponent("frames/1.heic"))
+    let short = Mover(move: otherVolume.move) { from, to in
+        try FileManager.default.copyItem(at: from, to: to)
+        try Data([7]).write(to: to.appendingPathComponent("frames/1.heic"))
+    }
+    #expect(throws: DeliveryError.copyMismatch(name)) { try Delivery.deliver(dir2, into: out, mover: short) }
+    #expect(try Data(contentsOf: dir2.appendingPathComponent("frames/1.heic")) == audio)
+}
+
 @Test func aCopyLeftByAnInterruptedDeliveryIsReplaced() throws {
     let work = try temp("work"), out = try temp("out")
     let stale = out.appendingPathComponent("." + name + Delivery.partialSuffix)
```

`Tests/DabberCoreTests/FinalizerTests.swift`:

```diff
@@ -581,3 +581,59 @@ extension FinalizerTests {
         #expect(!FileManager.default.fileExists(atPath: out.path))
     }
 }
+
+extension FinalizerTests {
+    private func addFrames(_ dir: URL, _ items: [(seconds: Double, data: Data)]) throws {
+        var m = try SessionManifest.load(from: dir)
+        for item in items {
+            let frame = m.addFrame(atNanos: m.sessionStartNanos + UInt64(item.seconds * 1e9))
+            let url = dir.appendingPathComponent(frame.file)
+            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
+            try item.data.write(to: url)
+        }
+        try m.save(to: dir)
+    }
+
+    @Test func framesBecomeTheSlideshowAndAreDeletedAfterwards() async throws {
+        let (_, dir) = try namedSession("Demo")
+        try addFrames(dir, [(0.5, try Frames.heic(screen())), (1.5, try Frames.heic(screen(gray: 0)))])
+        var m = try SessionManifest.load(from: dir)
+        m.addMark(atNanos: m.sessionStartNanos + 1_000_000_000)
+        try m.save(to: dir)
+        let out = try Finalizer.finish(dir)
+        let name = SessionNaming.sessionName(startedAt, title: "Demo")
+        #expect(try SessionManifest.load(from: out).finalize?.slidesError == nil)
+        let names = Set(try FileManager.default.contentsOfDirectory(atPath: out.path))
+        #expect(names == ["computer audio.m4a", "marks.txt", "mic - A.m4a", name + ".m4a", name + ".mp4", "session.json"])
+        let video = out.appendingPathComponent(name + ".mp4")
+        #expect(try audioBytes(video) == audioBytes(out.appendingPathComponent(name + ".m4a")))
+        #expect(try await chapterList(video) == ["0.000 Start", "1.000 Mark 1"])
+        #expect(try await titleTag(video) == name)
+        #expect(try videoTimes(video) == [0, 0.5, 1.5])
+    }
+
+    @Test func aBrokenFrameKeepsTheAudioAndTheFramesAndReportsTheError() throws {
+        let (_, dir) = try namedSession("Broken")
+        try addFrames(dir, [(0.5, Data([1, 2, 3]))])
+        let out = try Finalizer.finish(dir)
+        let name = SessionNaming.sessionName(startedAt, title: "Broken")
+        #expect(try SessionManifest.load(from: out).finalize?.slidesError == "500000000.heic: could not decode frame")
+        let names = Set(try FileManager.default.contentsOfDirectory(atPath: out.path))
+        #expect(names == ["computer audio.m4a", "frames", "mic - A.m4a", name + ".m4a", "session.json"])
+        #expect(try AVAudioFile(forReading: out.appendingPathComponent(name + ".m4a")).length == 144_000)
+    }
+
+    @Test func framesOfASessionWithoutAudioAreKept() throws {
+        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("fin-\(UUID().uuidString)")
+        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
+        var m = SessionManifest(appVersion: "t", startedAt: Date(), sessionStartNanos: 10_000_000_000)
+        m.sources = [
+            SourceManifest(kind: .mic, uid: "ap", name: "AirPods", file: "mic - AirPods.m4a", channels: 1, segments: [], restarts: [], overruns: 0),
+        ]
+        try m.save(to: dir)
+        try addFrames(dir, [(0.5, try Frames.heic(screen()))])
+        #expect(try Finalizer.run(dir).totalFrames == 0)
+        let names = Set(try FileManager.default.contentsOfDirectory(atPath: dir.path))
+        #expect(names == ["frames", "mic - AirPods.m4a", "mix.m4a", "session.json"])
+    }
+}
```

- [ ] **Step 2: Run the tests and see them fail**

Run: `scripts/test.sh; echo "exit=$?"`

Expected: no build error; `framesBecomeTheSlideshowAndAreDeletedAfterwards`, `aBrokenFrameKeepsTheAudioAndTheFramesAndReportsTheError`, `framesOfASessionWithoutAudioAreKept` and `acrossVolumesFilesInSubfoldersAreCheckedToo` fail. `exit=1`.

- [ ] **Step 3: Implement**

`Sources/DabberCore/Finalize/Delivery.swift`:

```diff
@@ -117,8 +117,9 @@ public enum Delivery {
 
     private static func listing(_ dir: URL) throws -> [String: Int] {
         var sizes: [String: Int] = [:]
-        for file in try FileManager.default.contentsOfDirectory(atPath: dir.path) {
-            sizes[file] = try FileManager.default.attributesOfItem(atPath: dir.appendingPathComponent(file).path)[.size] as? Int
+        for file in try FileManager.default.subpathsOfDirectory(atPath: dir.path) {
+            let attrs = try FileManager.default.attributesOfItem(atPath: dir.appendingPathComponent(file).path)
+            sizes[file] = attrs[.type] as? FileAttributeType == .typeDirectory ? -1 : attrs[.size] as? Int
         }
         return sizes
     }
```

`Sources/DabberCore/Finalize/Finalizer.swift`:

```diff
@@ -4,6 +4,7 @@ import Synchronization
 public enum Finalizer {
     public static let chunkFrames = 48_000
     public static let mixFile = "mix.m4a"
+    public static let videoFile = "mix.mp4"
 
     private struct Track {
         let base: String
@@ -41,6 +42,7 @@ public enum Finalizer {
                 plans: plans))
         }
         let total = tracks.map(\.reader.totalFrames).max() ?? 0
+        var slidesError: String?
         let writers = try tracks.map { try AACWriter(url: dir.appendingPathComponent($0.base + ".m4a"), channels: $0.channels) }
         let mix = try AACWriter(url: dir.appendingPathComponent(mixFile), channels: 2)
         var start = 0
@@ -65,6 +67,7 @@ public enum Finalizer {
                 for writer in writers { try ChapterWriter.write(chapters, into: writer.url) }
             }
             try ChapterWriter.write(chapters, title: manifest.name, into: mix.url)
+            slidesError = slideshow(manifest, dir: dir, chapters: chapters)
         }
         var gaps: [GapRecord] = []
         var drift: [String: Double] = [:]
@@ -76,15 +79,35 @@ public enum Finalizer {
                 if plan.resample { resampled.append(plan.file) }
             }
         }
-        let report = FinalizeReport(totalFrames: total, gaps: gaps, driftMillis: drift, resampled: resampled)
+        let report = FinalizeReport(
+            totalFrames: total, gaps: gaps, driftMillis: drift, resampled: resampled, slidesError: slidesError)
         manifest.finalize = report
         try manifest.save(to: dir)
         for name in rendered {
             try FileManager.default.removeItem(at: dir.appendingPathComponent(name))
         }
+        if FileManager.default.fileExists(atPath: dir.appendingPathComponent(videoFile).path) {
+            try? FileManager.default.removeItem(at: dir.appendingPathComponent(SessionManifest.framesDir))
+        }
         return report
     }
 
+    private static func slideshow(_ manifest: SessionManifest, dir: URL, chapters: [Chapter]) -> String? {
+        let slides = manifest.frames
+            .map { Slide(offsetNanos: $0.offsetNanos, url: dir.appendingPathComponent($0.file)) }
+            .filter { FileManager.default.fileExists(atPath: $0.url.path) }
+        guard !slides.isEmpty else { return nil }
+        let out = dir.appendingPathComponent(videoFile)
+        do {
+            try SlideshowWriter.write(
+                audio: dir.appendingPathComponent(mixFile), slides: slides, chapters: chapters, title: manifest.name, to: out)
+            return nil
+        } catch {
+            try? FileManager.default.removeItem(at: out)
+            return "\(error)"
+        }
+    }
+
     public static func finish(_ dir: URL) throws -> URL {
         try run(dir)
         return try rename(dir)
@@ -93,6 +116,10 @@ public enum Finalizer {
     public static func rename(_ dir: URL) throws -> URL {
         let name = try SessionManifest.load(from: dir).name
         try FileManager.default.moveItem(at: dir.appendingPathComponent(mixFile), to: dir.appendingPathComponent(name + ".m4a"))
+        let video = dir.appendingPathComponent(videoFile)
+        if FileManager.default.fileExists(atPath: video.path) {
+            try FileManager.default.moveItem(at: video, to: dir.appendingPathComponent(name + ".mp4"))
+        }
         let parent = dir.deletingLastPathComponent()
         var n = 1
         while true {
```

- [ ] **Step 4: Run the tests**

Run: `scripts/test.sh; echo "exit=$?"`

Expected: `Test run with 249 tests in 2 suites passed`, `exit=0`.

- [ ] **Step 5: Commit**

```bash
git add "Sources/DabberCore/Finalize/Delivery.swift" "Sources/DabberCore/Finalize/Finalizer.swift" "Tests/DabberCoreTests/DeliveryTests.swift" "Tests/DabberCoreTests/FinalizerTests.swift"
git diff --cached --stat
git commit -m "feat: finalize builds the slideshow video from stored frames"
```

### Task 7: Slide recorder loop

**Files:**
- Create: `Sources/DabberCore/Slides/SlideRecorder.swift`
- Create: `Tests/DabberCoreTests/SlideRecorderTests.swift`

`SlideRecorder` runs the capture loop off the main thread: read the host clock, grab, offer to a `FrameSampler`, store the changed frame, sleep 2 s. Sleeping after each grab means grabs never queue up. Without permission it does nothing and reports `.noPermission`; a failed grab reports `.failed` until the next good one. `ScreenGrabber` is the seam for the real ScreenCaptureKit code in the app. A status set by a cancelled loop is ignored, so `stop()` always leaves `nil` behind (the Task 7 review reproduced a stale `.on` about once in 230 runs). After any error the sampler is reset, so the same screen is stored again once the disk is back. `deinit` cancels the loop.

- [ ] **Step 1: Write the failing tests**

`Tests/DabberCoreTests/SlideRecorderTests.swift` (new file):

```swift
import CoreGraphics
import Foundation
import Synchronization
import Testing
@testable import DabberCore

private struct GrabFailed: Error, CustomStringConvertible {
    var description: String { "grab failed" }
}

private final class FakeGrabber: ScreenGrabber, @unchecked Sendable {
    let permitted: Bool
    private let lock = NSLock()
    private var queue: [Result<ScreenGrab, GrabFailed>]
    private var grabs = 0
    var grabCount: Int { lock.withLock { grabs } }

    init(permitted: Bool = true, _ queue: [Result<ScreenGrab, GrabFailed>]) {
        self.permitted = permitted
        self.queue = queue
    }

    func allowed() -> Bool { permitted }

    func grab() async throws -> ScreenGrab {
        let next = lock.withLock {
            grabs += 1
            return queue.count > 1 ? queue.removeFirst() : queue.first
        }
        guard let next else { throw GrabFailed() }
        return try next.get()
    }
}

private final class Store: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [(UInt64, Data)] = []
    var count: Int { lock.withLock { items.count } }
    var times: [UInt64] { lock.withLock { items.map(\.0) } }
    func add(_ at: UInt64, _ data: Data) -> Bool { lock.withLock { items.append((at, data)) }; return true }
}

private final class FailOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var failed = false
    func check() throws {
        let first = lock.withLock { () -> Bool in
            defer { failed = true }
            return !failed
        }
        if first { throw GrabFailed() }
    }
}

private func ticking() -> @Sendable () -> UInt64 {
    let n = Atomic<UInt64>(0)
    return { n.add(1, ordering: .relaxed).newValue }
}

@Test func slidesStoreOnlyChangedScreens() {
    let white = ScreenGrab(image: screen(), display: 1)
    let black = ScreenGrab(image: screen(gray: 0), display: 1)
    let grabber = FakeGrabber([.success(white), .success(white), .success(black), .success(black)])
    let slides = SlideRecorder(grabber: grabber, interval: .milliseconds(5), clock: ticking())
    let store = Store()
    slides.start { store.add($0, $1) }
    #expect(waitUntil { store.count == 2 })
    #expect(slides.status == .on)
    Thread.sleep(forTimeInterval: 0.1)
    slides.stop()
    #expect(store.count == 2)
    #expect(store.times == [1, 3])
    #expect(slides.status == nil)
}

@Test func slidesWithoutPermissionSayWhyAndDoNothing() {
    let slides = SlideRecorder(grabber: FakeGrabber(permitted: false, [.success(ScreenGrab(image: screen(), display: 1))]), interval: .milliseconds(5))
    let store = Store()
    slides.start { store.add($0, $1) }
    #expect(slides.status == .noPermission)
    Thread.sleep(forTimeInterval: 0.05)
    #expect(store.count == 0)
}

@Test func aFailedGrabIsReportedAndTheNextSuccessClearsIt() {
    let grabber = FakeGrabber([.failure(GrabFailed()), .failure(GrabFailed()), .success(ScreenGrab(image: screen(), display: 1))])
    let slides = SlideRecorder(grabber: grabber, interval: .milliseconds(20))
    let store = Store()
    slides.start { store.add($0, $1) }
    #expect(waitUntil { slides.status == .failed("grab failed") })
    #expect(waitUntil { store.count == 1 && slides.status == .on })
    slides.stop()
}

@Test func stoppedSlidesStopGrabbing() {
    let grabber = FakeGrabber([.success(ScreenGrab(image: screen(), display: 1)), .success(ScreenGrab(image: screen(), display: 2))])
    let slides = SlideRecorder(grabber: grabber, interval: .milliseconds(5))
    let store = Store()
    slides.start { store.add($0, $1) }
    #expect(waitUntil { store.count == 2 })
    slides.stop()
    Thread.sleep(forTimeInterval: 0.02)
    let grabs = grabber.grabCount
    Thread.sleep(forTimeInterval: 0.05)
    #expect(grabber.grabCount == grabs)
    #expect(store.count == 2)
    #expect(slides.status == nil)
}

@Test func aFailedStoreIsRetriedWithTheSameScreen() {
    let slides = SlideRecorder(grabber: FakeGrabber([.success(ScreenGrab(image: screen(), display: 1))]), interval: .milliseconds(5))
    let store = Store()
    let once = FailOnce()
    slides.start { at, data in
        try once.check()
        return store.add(at, data)
    }
    #expect(waitUntil { store.count == 1 })
    slides.stop()
}
```

- [ ] **Step 2: Run the tests and see them fail**

Run: `scripts/test.sh; echo "exit=$?"`

Expected: build error: cannot find `ScreenGrabber`, `ScreenGrab` and `SlideRecorder` in scope. `exit=1`.

- [ ] **Step 3: Implement**

`Sources/DabberCore/Slides/SlideRecorder.swift` (new file):

```swift
import CoreGraphics
import Foundation

public struct ScreenGrab: @unchecked Sendable {
    public let image: CGImage
    public let display: UInt32

    public init(image: CGImage, display: UInt32) {
        self.image = image
        self.display = display
    }
}

public protocol ScreenGrabber: Sendable {
    func allowed() -> Bool
    func grab() async throws -> ScreenGrab
}

public enum ScreenStatus: Equatable, Sendable {
    case on
    case noPermission
    case failed(String)
}

public final class SlideRecorder: @unchecked Sendable {
    public static let interval = Duration.seconds(2)

    private let grabber: any ScreenGrabber
    private let interval: Duration
    private let clock: @Sendable () -> UInt64
    private let lock = NSLock()
    private var task: Task<Void, Never>?
    private var current: ScreenStatus?

    public init(
        grabber: any ScreenGrabber, interval: Duration = SlideRecorder.interval,
        clock: @escaping @Sendable () -> UInt64 = HostClock.nowNanos
    ) {
        self.grabber = grabber
        self.interval = interval
        self.clock = clock
    }

    deinit {
        task?.cancel()
    }

    public var status: ScreenStatus? { lock.withLock { current } }

    public func start(store: @escaping @Sendable (UInt64, Data) throws -> Bool) {
        stop()
        guard grabber.allowed() else { return set(.noPermission) }
        set(.on)
        let (grabber, interval, clock) = (self.grabber, self.interval, self.clock)
        let task = Task.detached { [weak self] in
            var sampler = FrameSampler()
            while !Task.isCancelled {
                let at = clock()
                do {
                    let grab = try await grabber.grab()
                    guard !Task.isCancelled else { break }
                    if let data = try sampler.offer(grab.image, display: grab.display) {
                        _ = try store(at, data)
                    }
                    self?.set(.on)
                } catch {
                    sampler = FrameSampler()
                    self?.set(.failed("\(error)"))
                }
                try? await Task.sleep(for: interval)
            }
        }
        lock.withLock { self.task = task }
    }

    public func stop() {
        lock.withLock {
            task?.cancel()
            task = nil
            current = nil
        }
    }

    private func set(_ status: ScreenStatus) {
        lock.withLock { if !Task.isCancelled { current = status } }
    }
}
```

- [ ] **Step 4: Run the tests**

Run: `scripts/test.sh; echo "exit=$?"`

Expected: `Test run with 254 tests in 2 suites passed`, `exit=0`.

- [ ] **Step 5: Commit**

```bash
git add "Sources/DabberCore/Slides/SlideRecorder.swift" "Tests/DabberCoreTests/SlideRecorderTests.swift"
git diff --cached --stat
git commit -m "feat: slide recorder grabs the screen every 2 s while recording"
```

### Task 8: Record slides switch in the recorder model

**Files:**
- Modify: `Sources/DabberCore/App/RecorderModel.swift`
- Modify: `Tests/DabberCoreTests/RecorderModelTests.swift`

`RecorderModel.slidesOn` is the saved switch, locked while recording. Record passes it to the engine and starts the `SlideRecorder` into `engine.addFrame`. Stop, and a session that stopped itself, stop it. Screen problems and a failed video become warnings (the menu bar icon turns into the warning triangle); the failed-video warning is cleared once the menu was seen, like recovery failures (`recoveryNotes` is renamed to `notices`).

- [ ] **Step 1: Write the failing tests**

`Tests/DabberCoreTests/RecorderModelTests.swift`:

```diff
@@ -6,6 +6,8 @@ import Testing
 
 private final class FakeEngine: RecordingEngine, @unchecked Sendable {
     var started: [[SourceSpec]] = []
+    var slides: [Bool] = []
+    let frames = Mutex<[UInt64]>([])
     var phase: RecorderPhase = .idle
     var snapshots: [SourceSnapshot] = []
     var dir = URL(fileURLWithPath: "/tmp/fake-session")
@@ -16,13 +18,14 @@ private final class FakeEngine: RecordingEngine, @unchecked Sendable {
     var startGate: DispatchSemaphore?
     let startEntered = Atomic<Bool>(false)
 
-    func start(specs: [SourceSpec], title: String) throws -> URL {
+    func start(specs: [SourceSpec], title: String, slides: Bool) throws -> URL {
         startEntered.store(true, ordering: .relaxed)
         startGate?.wait()
         if let startError { throw startError }
         if phase != .idle { throw RecorderError.busy }
         lastError = nil
         started.append(specs)
+        self.slides.append(slides)
         manifest.title = title
         phase = .recording
         return dir
@@ -41,6 +44,12 @@ private final class FakeEngine: RecordingEngine, @unchecked Sendable {
     func removeMark(id: Int) -> [Mark] { editMarks { $0.removeMark(id: id) } }
     func setTitle(_ title: String) { _ = editMarks { $0.title = title } }
 
+    func addFrame(atNanos: UInt64, data: Data) throws -> Bool {
+        guard phase == .recording else { return false }
+        frames.withLock { $0.append(atNanos) }
+        return true
+    }
+
     private func editMarks(_ edit: (inout SessionManifest) -> Void) -> [Mark] {
         guard phase == .recording else { return [] }
         edit(&manifest)
@@ -700,3 +709,85 @@ private final class FakeCalendar: CalendarSource, @unchecked Sendable {
     m.deliveryDone(failure: nil)
     #expect(m.warning == nil)
 }
+
+private struct StillScreen: ScreenGrabber {
+    var permitted = true
+    func allowed() -> Bool { permitted }
+    func grab() async throws -> ScreenGrab { ScreenGrab(image: screen(), display: 1) }
+}
+
+@MainActor
+private func slidesModel(
+    _ engine: FakeEngine, on: Bool, permitted: Bool = true, persist: @escaping @Sendable (Bool) -> Void = { _ in }
+) -> (RecorderModel, SlideRecorder) {
+    let slides = SlideRecorder(grabber: StillScreen(permitted: permitted), interval: .milliseconds(5))
+    let m = RecorderModel(
+        engine: engine, catalog: FakeCatalog(devices: [airpods]), enabledIDs: ["computer", "ap"], persist: { _ in },
+        finalize: { dir, _ in dir }, slides: slides, slidesOn: on, persistSlides: persist)
+    m.refreshDevices()
+    return (m, slides)
+}
+
+@MainActor @Test func slidesSwitchIsSavedAndLockedWhileRecording() async {
+    let e = FakeEngine()
+    nonisolated(unsafe) var saved: [Bool] = []
+    let (m, _) = slidesModel(e, on: false) { saved.append($0) }
+    m.toggleSlides()
+    #expect(m.slidesOn)
+    await m.startStop()
+    m.toggleSlides()
+    #expect(m.slidesOn)
+    await m.startStop()
+    m.toggleSlides()
+    #expect(!m.slidesOn)
+    #expect(saved == [true, false])
+}
+
+@MainActor @Test func recordingWithSlidesGrabsIntoTheEngineUntilStop() async {
+    let e = FakeEngine()
+    let (m, slides) = slidesModel(e, on: true)
+    await m.startStop()
+    #expect(e.slides == [true])
+    #expect(waitUntil { e.frames.withLock { $0.count } == 1 })
+    #expect(slides.status == .on)
+    await m.startStop()
+    #expect(slides.status == nil)
+    let off = FakeEngine()
+    let (m2, slides2) = slidesModel(off, on: false)
+    await m2.startStop()
+    #expect(off.slides == [false])
+    #expect(slides2.status == nil)
+}
+
+@MainActor @Test func slidesStopWhenTheSessionStopsItself() async {
+    let e = FakeEngine()
+    let (m, slides) = slidesModel(e, on: true)
+    await m.startStop()
+    #expect(slides.status == .on)
+    e.phase = .idle
+    m.tick()
+    #expect(slides.status == nil)
+}
+
+@MainActor @Test func missingScreenPermissionIsAWarning() async {
+    let e = FakeEngine()
+    let (m, _) = slidesModel(e, on: true, permitted: false)
+    await m.startStop()
+    #expect(m.warning == "Screen: no permission (Privacy & Security > Screen & System Audio Recording)")
+    #expect(e.frames.withLock { $0.isEmpty })
+}
+
+@MainActor @Test func aFailedSlideshowIsAWarningUntilSeen() async throws {
+    let e = FakeEngine()
+    e.dir = FileManager.default.temporaryDirectory.appendingPathComponent("sv-\(UUID().uuidString)")
+    try FileManager.default.createDirectory(at: e.dir, withIntermediateDirectories: true)
+    var manifest = SessionManifest(appVersion: "t", startedAt: Date(), sessionStartNanos: 1)
+    manifest.finalize = FinalizeReport(totalFrames: 1, gaps: [], driftMillis: [:], resampled: [], slidesError: "no frames")
+    try manifest.save(to: e.dir)
+    let (m, _) = slidesModel(e, on: true)
+    await m.startStop()
+    await m.startStop()
+    #expect(m.warning == "Slides video failed: no frames")
+    m.menuClosed()
+    #expect(m.warning == nil)
+}
```

- [ ] **Step 2: Run the tests and see them fail**

Run: `scripts/test.sh; echo "exit=$?"`

Expected: build error: `FakeEngine` does not conform to `RecordingEngine`, `RecorderModel.init` has no `slides:` argument. `exit=1`.

- [ ] **Step 3: Implement**

`Sources/DabberCore/App/RecorderModel.swift`:

```diff
@@ -2,7 +2,7 @@ import Foundation
 import Observation
 
 public protocol RecordingEngine: Sendable {
-    func start(specs: [SourceSpec], title: String) throws -> URL
+    func start(specs: [SourceSpec], title: String, slides: Bool) throws -> URL
     func setTitle(_ title: String)
     func stop() -> URL?
     func status(at now: Date) -> RecorderStatus
@@ -10,10 +10,13 @@ public protocol RecordingEngine: Sendable {
     func addMark(atNanos: UInt64) -> [Mark]
     func setMarkText(id: Int, _ text: String) -> [Mark]
     func removeMark(id: Int) -> [Mark]
+    func addFrame(atNanos: UInt64, data: Data) throws -> Bool
 }
 
 extension SessionRecorder: RecordingEngine {
-    public func start(specs: [SourceSpec], title: String) throws -> URL { try start(specs: specs, title: title, at: Date()) }
+    public func start(specs: [SourceSpec], title: String, slides: Bool) throws -> URL {
+        try start(specs: specs, title: title, slides: slides, at: Date())
+    }
 }
 
 public protocol DeviceCatalog: Sendable {
@@ -66,6 +69,7 @@ public final class RecorderModel {
     public var draft = ""
     public private(set) var title = ""
     public private(set) var outputFolder: URL
+    public private(set) var slidesOn: Bool
 
     private let engine: any RecordingEngine
     private let catalog: any DeviceCatalog
@@ -75,6 +79,8 @@ public final class RecorderModel {
     private let persistOutput: @Sendable (URL) -> Void
     private let clock: @Sendable () -> UInt64
     private let calendar: any CalendarSource
+    private let slides: SlideRecorder?
+    private let persistSlides: @Sendable (Bool) -> Void
     private var enabledIDs: Set<String>
     private var names: [String: String]
     private enum StartNote { case noneSelected(String), missing(String?), unavailable }
@@ -86,7 +92,7 @@ public final class RecorderModel {
     private var finalizeTask: Task<Void, Never>?
     private var quitting = false
     private var stopErrorSeen = false
-    private var recoveryNotes: [String] = []
+    private var notices: [String] = []
     private var deliveryNote: String?
 
     public init(
@@ -98,7 +104,10 @@ public final class RecorderModel {
         clock: @escaping @Sendable () -> UInt64 = HostClock.nowNanos,
         calendar: any CalendarSource = NoCalendar(),
         outputFolder: URL = AppPaths.recordingsRoot,
-        persistOutput: @escaping @Sendable (URL) -> Void = { _ in }
+        persistOutput: @escaping @Sendable (URL) -> Void = { _ in },
+        slides: SlideRecorder? = nil,
+        slidesOn: Bool = false,
+        persistSlides: @escaping @Sendable (Bool) -> Void = { _ in }
     ) {
         self.engine = engine
         self.catalog = catalog
@@ -111,6 +120,9 @@ public final class RecorderModel {
         self.calendar = calendar
         self.outputFolder = outputFolder
         self.persistOutput = persistOutput
+        self.slides = slides
+        self.slidesOn = slidesOn
+        self.persistSlides = persistSlides
         lastSessionDir = engine.lastSessionDir
     }
 
@@ -157,6 +169,12 @@ public final class RecorderModel {
         persistOutput(url)
     }
 
+    public func toggleSlides() {
+        guard !isRecording else { return }
+        slidesOn.toggle()
+        persistSlides(slidesOn)
+    }
+
     public func deliveryDone(failure: String?) {
         deliveryNote = failure
         tick()
@@ -211,6 +229,7 @@ public final class RecorderModel {
 
     public func stopAndFinalize() async {
         saveComment()
+        slides?.stop()
         finalizing = true
         let engine = self.engine
         guard let dir = await Task.detached(operation: { engine.stop() }).value else {
@@ -229,13 +248,13 @@ public final class RecorderModel {
     public func menuClosed() {
         saveComment()
         guard warning != nil else { return }
-        recoveryNotes = []
+        notices = []
         if phase == .idle, !finalizing { stopErrorSeen = true }
         tick()
     }
 
     public func recoveryFailed(_ dir: URL, _ error: any Error) {
-        recoveryNotes.append("Could not finish \(dir.lastPathComponent): \(error)")
+        notices.append("Could not finish \(dir.lastPathComponent): \(error)")
         tick()
     }
 
@@ -243,6 +262,7 @@ public final class RecorderModel {
         guard !starting else { return }
         let status = engine.status(at: now)
         let stoppedItself = phase != .idle && status.phase == .idle && !finalizing
+        if status.phase == .idle { slides?.stop() }
         phase = status.phase
         elapsed = Self.format(seconds: status.phase == .idle ? 0 : status.elapsedSeconds)
         var notes: [String] = []
@@ -287,10 +307,15 @@ public final class RecorderModel {
             case .unavailable: notes.insert("No microphone available", at: 0)
             }
         }
+        switch slides?.status {
+        case .noPermission: notes.append("Screen: no permission (Privacy & Security > Screen & System Audio Recording)")
+        case .failed(let why): notes.append("Screen: \(why)")
+        case .on, nil: break
+        }
         if let note = status.diskWarning { notes.append(note) }
         if let error = status.lastError, !stopErrorSeen { notes.append("stopped: \(error)") }
         if let deliveryNote { notes.append("Saved in the local folder: \(deliveryNote)") }
-        notes += recoveryNotes
+        notes += notices
         warning = notes.isEmpty ? nil : notes.joined(separator: "; ")
         if stoppedItself, let dir = engine.lastSessionDir, dir != finalizedDir {
             finalizeSession(dir)
@@ -323,6 +348,9 @@ public final class RecorderModel {
                 lastSessionDir = dir
                 errorText = "finalize failed: \(error)"
             }
+            if let done = lastSessionDir, let why = (try? SessionManifest.load(from: done))?.finalize?.slidesError {
+                notices.append("Slides video failed: \(why)")
+            }
             finalizing = false
             finalizeTask = nil
             tick()
@@ -352,12 +380,14 @@ public final class RecorderModel {
         }
         let engine = self.engine
         let startSpecs = specs
+        let recordSlides = slidesOn && slides != nil
         starting = true
         let now = Date()
         let events = await calendar.events(from: now, to: now.addingTimeInterval(CalendarEvent.lookahead))
         let title = CalendarEvent.pickTitle(events, at: now)
         do {
-            _ = try await Task.detached { try engine.start(specs: startSpecs, title: title) }.value
+            _ = try await Task.detached { try engine.start(specs: startSpecs, title: title, slides: recordSlides) }.value
+            if recordSlides { slides?.start { try engine.addFrame(atNanos: $0, data: $1) } }
             self.title = title
             sessionMics = startSpecs.filter { $0.kind == .mic }
             stopErrorSeen = false
```

- [ ] **Step 4: Run the tests**

Run: `scripts/test.sh; echo "exit=$?"`

Expected: `Test run with 259 tests in 2 suites passed`, `exit=0`.

- [ ] **Step 5: Commit**

```bash
git add "Sources/DabberCore/App/RecorderModel.swift" "Tests/DabberCoreTests/RecorderModelTests.swift"
git diff --cached --stat
git commit -m "feat: record slides switch in the recorder model"
```

### Task 9: Menu switch, live screen capture and headless --slides

**Files:**
- Modify: `Sources/Dabber/AppDelegate.swift`
- Modify: `Sources/Dabber/Headless.swift`
- Create: `Sources/Dabber/LiveScreenGrabber.swift`
- Modify: `Sources/Dabber/MenuApp.swift`

`LiveScreenGrabber` finds the display under the mouse pointer with CoreGraphics (`CGEvent` location + `CGGetDisplaysWithPoint`; the Task 9 review showed that a `MainActor.run` hop never returns in headless mode, which has no run loop), asks ScreenCaptureKit for a screenshot already scaled to at most 1920 wide, without the pointer. Permission: `CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess()` (the second call shows the system prompt once). The menu gets a **Record slides** toggle under the sources. `AppDelegate` saves the switch as `recordSlides`. Headless `--record ... --slides` runs the same capture and logs the screen status each second and `FRAMES <count> bytes=<total>` before finalizing, for the hardware check. No unit tests: this code needs the real screen.

- [ ] **Step 1: Make the change**

`Sources/Dabber/AppDelegate.swift`:

```diff
@@ -7,6 +7,7 @@ final class AppDelegate: NSObject, NSApplicationDelegate {
     private static let namesKey = "sourceNames"
     private static let outputKey = "outputFolder"
     private static let legacyKey = "legacySessionsAdopted"
+    private static let slidesKey = "recordSlides"
 
     @MainActor static let model = RecorderModel(
         engine: SessionRecorder(root: AppPaths.workRoot, appVersion: AppPaths.version),
@@ -19,7 +20,10 @@ final class AppDelegate: NSObject, NSApplicationDelegate {
         calendar: EventKitCalendar(),
         outputFolder: UserDefaults.standard.string(forKey: outputKey).map { URL(fileURLWithPath: $0, isDirectory: true) }
             ?? AppPaths.recordingsRoot,
-        persistOutput: { UserDefaults.standard.set($0.path, forKey: outputKey) })
+        persistOutput: { UserDefaults.standard.set($0.path, forKey: outputKey) },
+        slides: SlideRecorder(grabber: LiveScreenGrabber()),
+        slidesOn: UserDefaults.standard.bool(forKey: slidesKey),
+        persistSlides: { UserDefaults.standard.set($0, forKey: slidesKey) })
 
     private static let feedKey = "virtualMic"
```

`Sources/Dabber/Headless.swift`:

```diff
@@ -178,6 +178,7 @@ enum Headless {
             var seconds = 0.0
             var marks: [(at: Double, text: String)] = []
             var title: String?
+            var slides = false
             var output = AppPaths.recordingsRoot
             var work = AppPaths.workRoot
             var i = 1
@@ -217,6 +218,8 @@ enum Headless {
                     let parts = args[i].split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
                     guard let at = Double(parts[0]) else { return 64 }
                     marks.append((at, parts.count > 1 ? String(parts[1]) : ""))
+                case "--slides":
+                    slides = true
                 case "--title":
                     i += 1
                     guard i < args.count else { return 64 }
@@ -233,8 +236,10 @@ enum Headless {
                     ? SourceSpec(kind: s.kind, uid: s.uid, name: s.name, excludedBundleIDs: excluded) : s
             }
             let recorder = SessionRecorder(root: work, appVersion: AppPaths.version)
-            let dir = try recorder.start(specs: specs)
+            let dir = try recorder.start(specs: specs, slides: slides)
             log.line("SESSION \(dir.path)")
+            let grabber = SlideRecorder(grabber: LiveScreenGrabber())
+            if slides { grabber.start { try recorder.addFrame(atNanos: $0, data: $1) } }
             if let title {
                 recorder.setTitle(title)
                 log.line("TITLE \(title)")
@@ -247,7 +252,8 @@ enum Headless {
                 let parts = status.sources.map { s in
                     "\(s.spec.name): \(s.status) \(String(format: "%.1f", s.levelDb)) dB" + (s.silent ? " SILENT" : "")
                 }
-                log.line("t=\(Int(status.elapsedSeconds)) \(status.phase) | " + parts.joined(separator: " | "))
+                log.line("t=\(Int(status.elapsedSeconds)) \(status.phase) | " + parts.joined(separator: " | ")
+                    + (slides ? " | screen: \(grabber.status.map { "\($0)" } ?? "off")" : ""))
                 if status.phase != .recording {
                     log.line("ERROR recording stopped: \(status.lastError ?? "unknown")")
                     break
@@ -260,10 +266,17 @@ enum Headless {
                     }
                 }
             }
+            grabber.stop()
             guard let stopped = recorder.stop() ?? recorder.lastSessionDir else { return 1 }
             log.line("STOPPED \(stopped.path)")
+            if slides {
+                let frames = (try? SessionManifest.load(from: stopped))?.frames ?? []
+                let bytes = frames.compactMap { try? FileManager.default.attributesOfItem(atPath: stopped.appendingPathComponent($0.file).path)[.size] as? Int }
+                log.line("FRAMES \(frames.count) bytes=\(bytes.reduce(0, +))")
+            }
             let report = try Finalizer.run(stopped)
-            log.line("FINALIZED total=\(report.totalFrames) gaps=\(report.gaps.count) resampled=\(report.resampled.count)")
+            log.line("FINALIZED total=\(report.totalFrames) gaps=\(report.gaps.count) resampled=\(report.resampled.count)"
+                + (report.slidesError.map { " slidesError=\($0)" } ?? ""))
             let named = try Finalizer.rename(stopped)
             log.line("NAMED \(named.path)")
             try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
```

`Sources/Dabber/LiveScreenGrabber.swift` (new file):

```swift
import CoreGraphics
import DabberCore
import ScreenCaptureKit

enum GrabError: Error, CustomStringConvertible {
    case noDisplay

    var description: String { "no display to capture" }
}

struct LiveScreenGrabber: ScreenGrabber {
    func allowed() -> Bool { CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess() }

    func grab() async throws -> ScreenGrab {
        let id = Self.displayUnderCursor()
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == id }) ?? content.displays.first else {
            throw GrabError.noDisplay
        }
        let mode = CGDisplayCopyDisplayMode(display.displayID)
        let size = Frames.fitSize(width: mode?.pixelWidth ?? display.width, height: mode?.pixelHeight ?? display.height)
        let config = SCStreamConfiguration()
        config.width = size.width
        config.height = size.height
        config.showsCursor = false
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        return ScreenGrab(image: image, display: display.displayID)
    }

    private static func displayUnderCursor() -> CGDirectDisplayID? {
        guard let point = CGEvent(source: nil)?.location else { return nil }
        var id = CGDirectDisplayID(0)
        var count: UInt32 = 0
        return CGGetDisplaysWithPoint(point, 1, &id, &count) == .success && count > 0 ? id : nil
    }
}
```

`Sources/Dabber/MenuApp.swift`:

```diff
@@ -79,6 +79,8 @@ struct RecordingSection: View {
                     if row.showsLevel { LevelBar(db: row.levelDb, warn: row.silent) }
                 }
             }
+            Toggle("Record slides", isOn: Binding(get: { model.slidesOn }, set: { _ in model.toggleSlides() }))
+                .disabled(model.isRecording)
             if model.isRecording {
                 HStack {
                     Text("Name").font(.caption).foregroundStyle(.secondary)
```

- [ ] **Step 2: Run the tests**

Run: `scripts/test.sh; echo "exit=$?"`

Expected: `Test run with 259 tests in 2 suites passed`, `exit=0`. Then run `scripts/build-app.sh; echo "exit=$?"`. Expected: `Build complete!`, a `designated => identifier "local.dabber.Dabber"` line, `exit=0`.

- [ ] **Step 3: Commit**

```bash
git add "Sources/Dabber/AppDelegate.swift" "Sources/Dabber/Headless.swift" "Sources/Dabber/LiveScreenGrabber.swift" "Sources/Dabber/MenuApp.swift"
git diff --cached --stat
git commit -m "feat: record slides in the menu, live screen capture and headless --slides"
```

### Task 10: README

**Files:**
- Modify: `README.md`
- Modify: `README.ru.md`

Both READMEs: the feature bullet, disk use, the Screen Recording permission, the `.mp4` in the folder listing, a Slides section with the privacy note, and the "Screen: no permission" troubleshooting entry.

- [ ] **Step 1: Make the change**

`README.md`:

```diff
@@ -11,6 +11,9 @@ Dabber is a small macOS menu bar app that records what your Mac plays and what y
   warning, so a lost microphone is noticed during the recording, not after it.
 - **Marks**: press Mark at an important moment and optionally type a comment. Marks become chapters in the
   recorded files and are also saved to `marks.txt`.
+- **Slides** (optional): with "Record slides" on, Dabber takes a screenshot every 2 seconds and, after Stop, makes a
+  video: the mix plays, and each change of the screen stays in the picture until the next change. No screen video
+  is recorded.
 - **Names from the calendar**: a recording is named after the calendar event that is on (or starts within 15 minutes).
   You can change the name while recording.
 - You choose the folder where finished recordings go.
@@ -33,7 +36,7 @@ Dabber is built from source on your Mac. There is no prebuilt download.
   not needed.
 - **Disk space:** about 1.5 GB for the Command Line Tools and up to about 1 GB for the build folders inside the
   repository. While recording, Dabber keeps uncompressed audio in a temporary folder: about 1.4 GB per hour for Mac
-  audio and about 0.7 GB per hour per microphone. A recording does not start with less than 2 GB free, and the menu
+  audio and about 0.7 GB per hour per microphone, plus up to about 180 MB per hour for slides. A recording does not start with less than 2 GB free, and the menu
   warns when less than about 20 minutes of recording space is left. Finished files are much smaller (compressed AAC).
 
 ### Permissions the app asks for
@@ -42,6 +45,7 @@ Dabber is built from source on your Mac. There is no prebuilt download.
 | --- | --- | --- |
 | Microphone | First recording (or virtual mic use) with a microphone | To record your microphones |
 | System Audio Recording | First recording (or virtual mic use) with Mac audio | To record sound played by other apps |
+| Screen Recording | First recording with Record slides on | To take the screenshots for the slides video |
 | Calendars (full access) | First recording | To read the title of the current event and name the recording after it. Dabber only reads events. If you decline, recordings are named by date and time |
 
 ## Install
@@ -119,6 +123,7 @@ with that name already exists, a number is added. Inside:
   2026-09-24 14-00 Weekly sync.m4a   the mix of all sources (stereo)
   computer audio.m4a                 Mac audio (stereo)
   mic - MacBook Air Microphone.m4a   one file per microphone (mono)
+  2026-09-24 14-00 Weekly sync.mp4   only with Record slides: the mix with the screen as slides
   marks.txt                          only if you made marks
   session.json                       technical details: sources, gaps, restarts
 ```
@@ -137,6 +142,22 @@ After Stop, marks become chapters (plus a first chapter "Start" at 0:00) in the
 Chapters were checked in QuickTime Player, Preview and VLC (IINA and iPhone apps were not checked). The same
 marks are written to `marks.txt` as `HH:MM:SS  comment` lines.
 
+### Slides
+
+Turn on **Record slides** under the sources before you press Record (it cannot be changed while recording). While
+recording, Dabber takes a screenshot of the display with the mouse pointer every 2 seconds. A screenshot is kept only
+when the screen has changed; a blinking text cursor or the menu bar clock does not count. The pointer itself is not
+in the picture.
+
+After Stop, Dabber makes `<name>.mp4` next to the mix: the same sound, HEVC video, 1920 pixels wide at most, the same
+chapters. Each kept screenshot is shown until the next one; the video is black until the first one. The screenshots
+are deleted after the video is made. If the video could not be made, the menu says "Slides video failed: …", the
+audio files are complete as usual, and the screenshots stay in the `frames` folder of the recording (HEIC files named
+by nanoseconds since the start).
+
+Everything on that display goes into the video: notifications, chats, passwords shown on screen. Turn Record slides
+off for recordings where this matters.
+
 ### Recording names
 
 When you press Record, Dabber looks at your calendars for an event that is going on or starts within the next 15
@@ -197,6 +218,9 @@ Your recordings in the output folder are not touched.
 
 - **The Mac audio track is silent.** Check System Settings > Privacy & Security > Screen & System Audio Recording and
   allow Dabber there. Without this permission Dabber cannot capture the Mac audio.
+- **Warning "Screen: no permission".** Record slides is on, but Dabber may not take screenshots. Open System Settings
+  > Privacy & Security > Screen & System Audio Recording, allow Dabber in the upper list (not "System Audio Recording
+  Only"), then quit and start Dabber again. The sound is recorded either way.
 - **Warning "… not connected — recording …" or "…: no signal for 10 s".** The first means an enabled microphone
   was absent when you started and another one is being recorded. The second means a microphone has been silent for
   10 seconds while the Mac was playing sound: check that the right microphone is enabled, not muted, and that Dabber
```

`README.ru.md`:

```diff
@@ -12,6 +12,9 @@ Dabber — небольшое приложение для строки меню
   предупреждение. Потерянный микрофон видно во время записи, а не после неё.
 - **Отметки**: нажмите Mark в важный момент и при желании введите комментарий. Отметки становятся главами в
   записанных файлах и сохраняются в `marks.txt`.
+- **Слайды** (по желанию): с включённым «Record slides» Dabber раз в 2 секунды делает снимок экрана, а после Stop
+  собирает видео: играет микс, а каждое изменение экрана остаётся на картинке до следующего изменения. Видео экрана
+  не пишется.
 - **Названия из календаря**: запись называется по событию календаря, которое идёт сейчас (или начнётся в ближайшие
   15 минут). Название можно изменить во время записи.
 - Папку для готовых записей выбираете вы.
@@ -33,7 +36,7 @@ Dabber собирается из исходников на вашем Mac. Го
 - **Command Line Tools для Xcode.** Установка в Терминале: `xcode-select --install`. Полный Xcode не нужен.
 - **Место на диске:** около 1,5 ГБ на Command Line Tools и до 1 ГБ на папки сборки внутри репозитория. Во время
   записи Dabber хранит несжатый звук во временной папке: около 1,4 ГБ в час на звук Mac и около 0,7 ГБ в час на
-  каждый микрофон. Запись не начнётся, если свободно меньше 2 ГБ, а меню предупредит, когда места останется меньше
+  каждый микрофон, плюс до 180 МБ в час на слайды. Запись не начнётся, если свободно меньше 2 ГБ, а меню предупредит, когда места останется меньше
   чем примерно на 20 минут записи. Готовые файлы намного меньше (сжатый AAC).
 
 ### Какие разрешения запросит приложение
@@ -42,6 +45,7 @@ Dabber собирается из исходников на вашем Mac. Го
 | --- | --- | --- |
 | Микрофон | Первая запись (или первое использование виртуального микрофона) с микрофоном | Чтобы записывать микрофоны |
 | Запись системного звука | Первая запись (или первое использование виртуального микрофона) со звуком Mac | Чтобы записывать звук других приложений |
+| Запись экрана | Первая запись с включённым Record slides | Чтобы делать снимки экрана для видео со слайдами |
 | Календари (полный доступ) | Первая запись | Чтобы прочитать название текущего события и назвать по нему запись. Dabber только читает события. Если отказать, записи называются по дате и времени |
 
 ## Установка
@@ -120,6 +124,7 @@ VIRTUAL MIC больше не пишет «Driver not installed». Если пи
   2026-09-24 14-00 Weekly sync.m4a   микс всех источников (стерео)
   computer audio.m4a                 звук Mac (стерео)
   mic - MacBook Air Microphone.m4a   по файлу на каждый микрофон (моно)
+  2026-09-24 14-00 Weekly sync.mp4   только с Record slides: микс с экраном в виде слайдов
   marks.txt                          только если были отметки
   session.json                       технические данные: источники, пропуски, перезапуски
 ```
@@ -139,6 +144,20 @@ VIRTUAL MIC больше не пишет «Driver not installed». Если пи
 проверены в QuickTime Player, Просмотре (Preview) и VLC (IINA и приложения на iPhone не проверялись). Те же отметки
 записываются в `marks.txt` строками вида `ЧЧ:ММ:СС  комментарий`.
 
+### Слайды
+
+Включите **Record slides** под списком источников до нажатия Record (во время записи переключить нельзя). Во время
+записи Dabber раз в 2 секунды снимает экран, на котором находится указатель мыши. Снимок сохраняется, только если
+экран изменился; мигающий текстовый курсор и часы в строке меню не считаются. Сам указатель на снимок не попадает.
+
+После Stop Dabber собирает `<название>.mp4` рядом с миксом: тот же звук, видео HEVC шириной не больше 1920 пикселей,
+те же главы. Каждый сохранённый снимок показывается до следующего; до первого снимка видео чёрное. После сборки
+снимки удаляются. Если видео собрать не удалось, меню пишет «Slides video failed: …», звуковые файлы готовы как
+обычно, а снимки остаются в папке `frames` внутри записи (файлы HEIC, названные по наносекундам от начала).
+
+В видео попадает всё, что было на этом экране: уведомления, чаты, пароли на экране. Для записей, где это важно,
+выключайте Record slides.
+
 ### Названия записей
 
 При нажатии Record Dabber ищет в календарях событие, которое идёт сейчас или начнётся в ближайшие 15 минут (события
@@ -200,6 +219,10 @@ scripts/install-app.sh
 
 - **Дорожка звука Mac пустая.** Откройте Системные настройки > Конфиденциальность и безопасность > Запись экрана и
   системного звука и разрешите Dabber. Без этого разрешения Dabber не может записать звук Mac.
+- **Предупреждение «Screen: no permission».** Record slides включён, но Dabber не разрешено снимать экран. Откройте
+  Системные настройки > Конфиденциальность и безопасность > Запись экрана и системного звука, разрешите Dabber в
+  верхнем списке (не в «Только запись системного звука»), затем закройте и снова запустите Dabber. Звук
+  записывается в любом случае.
 - **Предупреждение «… not connected — recording …» или «…: no signal for 10 s».** Первое значит, что включённого
   микрофона не было при старте и записывается другой. Второе — микрофон молчит 10 секунд, пока Mac играет звук:
   проверьте, что включён нужный микрофон, он не выключен, и Dabber разрешён в Конфиденциальность и безопасность >
```

- [ ] **Step 2: Run the tests**

Run: `scripts/test.sh; echo "exit=$?"`

Expected: `Test run with 259 tests in 2 suites passed`, `exit=0`.

- [ ] **Step 3: Commit**

```bash
git add "README.md" "README.ru.md"
git diff --cached --stat
git commit -m "docs: slides in the README"
```

### Task 11 (HUMAN): hardware, menu and player check

- [ ] **Step 1: Headless run with slides**

```bash
scripts/build-app.sh
scripts/run-headless.sh build/slides-check/slides.log --record --computer-audio --slides --seconds 30 --work "$PWD/build/slides-check/work" --out "$PWD/build/slides-check/out"
```

While it runs, switch between three different windows, then leave the screen still for 10 s. The first run shows the Screen Recording prompt and logs `screen: noPermission`: allow Dabber in System Settings > Privacy & Security > Screen & System Audio Recording (upper list), then run the command again. macOS may also ask from time to time to confirm that Dabber may keep recording the screen; that prompt comes from the system, not from Dabber.

Expected: `t=… | screen: on` lines, `FRAMES <n> bytes=<b>` with `n` about 3-6 and `b / n` about 100 KB or less, a `FINALIZED …` line without `slidesError`, last line ending in ` EXIT 0`.

- [ ] **Step 2: Check the file**

```bash
ffprobe -v error -show_entries stream=codec_name,codec_tag_string,width,height:format=duration -of compact build/slides-check/out/*/*.mp4
```

Expected: `hevc|hvc1` with the display's size scaled to at most 1920 wide, `aac`, duration about 30. Play it: the picture changes when you switched windows. No `frames` folder in `build/slides-check/out/*/`.

- [ ] **Step 3: Menu**

`scripts/install-app.sh`, open the menu: **Record slides** under the sources. Turn it on, record 1 minute: 20 s typing in a text editor, 20 s with a still screen and a blinking caret, 20 s switching windows. Check: the toggle is disabled while recording; no warning; after Stop the folder has `<name>.mp4`; in `session.json` the `frames` list grows while typing and switching but not during the still 20 s. If Dabber says "Screen: no permission" although Step 1 was allowed, allow `/Applications/Dabber.app` too (the grant is expected to be shared because the bundle ID and certificate are the same; this checks it).

- [ ] **Step 4: Report**

Tell the numbers: frames kept per phase of Step 3, average frame size, anything wrong in players. If the still phase kept frames, or real changes were missed, tune `Frames.pixelDelta` / `Frames.changedPixels` in `Sources/DabberCore/Slides/Frames.swift` and the `caretSizedChangesDoNotCountButContentDoes` test together.
