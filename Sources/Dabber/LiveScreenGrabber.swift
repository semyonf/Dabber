import AppKit
import DabberCore
import ScreenCaptureKit

enum GrabError: Error, CustomStringConvertible {
    case noDisplay

    var description: String { "no display to capture" }
}

struct LiveScreenGrabber: ScreenGrabber {
    func allowed() -> Bool { CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess() }

    func grab() async throws -> ScreenGrab {
        let id = await MainActor.run { Self.displayUnderCursor() }
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

    @MainActor private static func displayUnderCursor() -> CGDirectDisplayID? {
        let point = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(point, $0.frame, false) } ?? NSScreen.main
        return screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
    }
}
