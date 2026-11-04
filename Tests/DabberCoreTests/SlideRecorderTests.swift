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
    private var asked: [ScreenTarget] = []
    var grabCount: Int { lock.withLock { grabs } }
    var targets: [ScreenTarget] { lock.withLock { asked } }

    init(permitted: Bool = true, _ queue: [Result<ScreenGrab, GrabFailed>]) {
        self.permitted = permitted
        self.queue = queue
    }

    func allowed() -> Bool { permitted }

    func grab(_ target: ScreenTarget) async throws -> ScreenGrab {
        let next = lock.withLock {
            grabs += 1
            asked.append(target)
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

@Test func slidesStoreOnlyChangedScreens() async {
    let white = ScreenGrab(image: screen(), display: 1)
    let black = ScreenGrab(image: screen(gray: 0), display: 1)
    let grabber = FakeGrabber([.success(white), .success(white), .success(black), .success(black)])
    let slides = SlideRecorder(grabber: grabber, interval: .milliseconds(5), clock: ticking())
    let store = Store()
    slides.start { store.add($0, $1) }
    #expect(await eventually { store.count == 2 })
    #expect(slides.status == .on)
    try? await Task.sleep(for: .seconds(0.1))
    slides.stop()
    #expect(store.count == 2)
    #expect(store.times == [1, 3])
    #expect(slides.status == nil)
}

@Test func slidesWithoutPermissionSayWhyAndDoNothing() async {
    let slides = SlideRecorder(grabber: FakeGrabber(permitted: false, [.success(ScreenGrab(image: screen(), display: 1))]), interval: .milliseconds(5))
    let store = Store()
    slides.start { store.add($0, $1) }
    #expect(slides.status == .noPermission)
    try? await Task.sleep(for: .seconds(0.05))
    #expect(store.count == 0)
}

@Test func aFailedGrabIsReportedAndTheNextSuccessClearsIt() async {
    let grabber = FakeGrabber([.failure(GrabFailed()), .failure(GrabFailed()), .success(ScreenGrab(image: screen(), display: 1))])
    let slides = SlideRecorder(grabber: grabber, interval: .milliseconds(500))
    let store = Store()
    slides.start { store.add($0, $1) }
    #expect(await eventually { slides.status == .failed("grab failed") })
    #expect(await eventually { store.count == 1 && slides.status == .on })
    slides.stop()
}

@Test func stoppedSlidesStopGrabbing() async {
    let grabber = FakeGrabber([.success(ScreenGrab(image: screen(), display: 1)), .success(ScreenGrab(image: screen(), display: 2))])
    let slides = SlideRecorder(grabber: grabber, interval: .milliseconds(5))
    let store = Store()
    slides.start { store.add($0, $1) }
    #expect(await eventually { store.count == 2 })
    slides.stop()
    try? await Task.sleep(for: .seconds(0.02))
    let grabs = grabber.grabCount
    try? await Task.sleep(for: .seconds(0.05))
    #expect(grabber.grabCount == grabs)
    #expect(store.count == 2)
    #expect(slides.status == nil)
}

@Test func aFailedStoreIsRetriedWithTheSameScreen() async {
    let slides = SlideRecorder(grabber: FakeGrabber([.success(ScreenGrab(image: screen(), display: 1))]), interval: .milliseconds(5))
    let store = Store()
    let once = FailOnce()
    slides.start { at, data in
        try once.check()
        return store.add(at, data)
    }
    #expect(await eventually { store.count == 1 })
    slides.stop()
}

@Test func slidesFollowTheTargetChangedDuringRecording() async {
    let grabber = FakeGrabber([.success(ScreenGrab(image: screen(), display: 1))])
    let slides = SlideRecorder(grabber: grabber, interval: .milliseconds(5))
    slides.start { _, _ in true }
    #expect(await eventually { grabber.targets.contains(.screen) })
    let window = ScreenTarget.window(WindowTarget(id: 42, app: "Safari", title: "Slides"))
    slides.target = window
    #expect(await eventually { grabber.targets.last == window })
    slides.stop()
}

@Test func screenTargetSurvivesSaving() {
    let area = ScreenTarget.area(AreaTarget(
        display: 3, x: 10, y: 20, width: 800, height: 600, followsDesktops: false, windows: [7, 9]))
    #expect(ScreenTarget.decode(area.encoded()) == area)
    #expect(ScreenTarget.decode(nil) == .screen)
    #expect(ScreenTarget.decode(Data("junk".utf8)) == .screen)
    #expect(area.title == "Area 800×600")
    #expect(ScreenTarget.window(WindowTarget(id: 1, app: "Zoom", title: "")).title == "Zoom")
    #expect(ScreenTarget.window(WindowTarget(id: 1, app: "Activity Monitor", title: "Activity Monitor")).title == "Activity Monitor")
    #expect(ScreenTarget.window(WindowTarget(id: 1, app: "Safari", title: "Docs")).title == "Safari — Docs")
}

@Test func pinnedDesktopKeepsItsWindowsWhileAnotherDesktopIsShown() {
    // Another desktop is shown: none of the known windows is on screen; a closed one leaves.
    #expect(DesktopWindows.update([1, 2, 3], onScreen: [8, 9], existing: [1, 2, 8, 9]) == [1, 2])
    // Back on that desktop: a new window joins, a window moved away leaves.
    #expect(DesktopWindows.update([1, 2, 3], onScreen: [1, 2, 4], existing: [1, 2, 3, 4]) == [1, 2, 4])
    // Only one of three known windows is on screen (for example one shown on all desktops): not that desktop.
    #expect(DesktopWindows.update([1, 2, 3], onScreen: [3, 8], existing: [1, 2, 3, 8]) == [1, 2, 3])
    // An empty desktop stays empty.
    #expect(DesktopWindows.update([], onScreen: [8], existing: [8]) == [])
}
