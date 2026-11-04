import CoreGraphics
import DabberCore
import Foundation
import ScreenCaptureKit
import Synchronization

enum GrabError: Error, CustomStringConvertible {
    case noDisplay
    case windowClosed(String)
    case draw

    var description: String {
        switch self {
        case .noDisplay: return "no display to capture"
        case .windowClosed(let app): return "the chosen \(app) window is closed"
        case .draw: return "could not draw the area"
        }
    }
}

final class LiveScreenGrabber: ScreenGrabber {
    /// The windows of the desktop a pinned area belongs to, carried from one screenshot to the next.
    private let pinned = Mutex<(area: AreaTarget, windows: Set<UInt32>)?>(nil)

    func allowed() -> Bool { CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess() }

    func grab(_ target: ScreenTarget) async throws -> ScreenGrab {
        switch target {
        case .screen: return try await grabScreen()
        case .window(let window): return try await grabWindow(window)
        case .area(let area): return try await area.followsDesktops ? grabArea(area) : grabDesktop(area)
        }
    }

    private func grabScreen() async throws -> ScreenGrab {
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

    /// A window is captured by itself, so it does not matter what covers it or which desktop is shown.
    private func grabWindow(_ target: WindowTarget) async throws -> ScreenGrab {
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false)
        guard let window = content.windows.first(where: { $0.windowID == target.id }) else {
            throw GrabError.windowClosed(target.app)
        }
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let scale = Double(filter.pointPixelScale)
        let size = Frames.fitSize(
            width: max(2, Int(filter.contentRect.width * scale)), height: max(2, Int(filter.contentRect.height * scale)))
        let config = SCStreamConfiguration()
        config.width = size.width
        config.height = size.height
        config.showsCursor = false
        config.ignoreShadowsSingleWindow = true
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        return ScreenGrab(image: image, display: target.id)
    }

    /// Part of whatever the display shows now.
    private func grabArea(_ area: AreaTarget) async throws -> ScreenGrab {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == area.display }) else { throw GrabError.noDisplay }
        let rect = Self.rect(area).intersection(CGRect(x: 0, y: 0, width: display.width, height: display.height))
        guard !rect.isNull, rect.width >= 2, rect.height >= 2 else { throw GrabError.noDisplay }
        let scale = Self.scale(display)
        let size = Frames.fitSize(width: Int(rect.width * scale), height: Int(rect.height * scale))
        let config = SCStreamConfiguration()
        config.sourceRect = rect
        config.width = size.width
        config.height = size.height
        config.showsCursor = false
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        return ScreenGrab(image: image, display: area.display)
    }

    /// The area as it looks on the desktop where it was chosen: every window of that desktop is captured by itself
    /// and drawn where it stands, back to front, over a dark background (the wallpaper is not drawn).
    private func grabDesktop(_ area: AreaTarget) async throws -> ScreenGrab {
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false)
        guard let display = content.displays.first(where: { $0.displayID == area.display }) else { throw GrabError.noDisplay }
        let local = Self.rect(area)
        let bounds = local.offsetBy(dx: display.frame.minX, dy: display.frame.minY)
        let own = Bundle.main.bundleIdentifier
        let candidates = content.windows.filter {
            $0.windowLayer == 0 && $0.owningApplication?.bundleIdentifier != own && $0.frame.intersects(display.frame)
        }
        let onScreen = Set(candidates.filter(\.isOnScreen).map(\.windowID))
        let existing = Set(content.windows.map(\.windowID))
        let members = pinned.withLock { state in
            let known = state.flatMap { $0.area == area ? $0.windows : nil } ?? Set(area.windows)
            let next = DesktopWindows.update(known, onScreen: onScreen, existing: existing)
            state = (area, next)
            return next
        }
        let order = Self.frontToBack()
        let drawn = candidates
            .filter { members.contains($0.windowID) && $0.frame.intersects(bounds) }
            .sorted { (order[$0.windowID] ?? .max) > (order[$1.windowID] ?? .max) }
        let size = Frames.fitSize(width: Int(local.width * Self.scale(display)), height: Int(local.height * Self.scale(display)))
        let k = Double(size.width) / local.width
        guard let ctx = CGContext(
            data: nil, width: size.width, height: size.height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { throw GrabError.draw }
        ctx.setFillColor(CGColor(gray: 0.12, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: size.width, height: size.height))
        ctx.interpolationQuality = .high
        for window in drawn {
            let filter = SCContentFilter(desktopIndependentWindow: window)
            let config = SCStreamConfiguration()
            config.width = max(2, Int(window.frame.width * k))
            config.height = max(2, Int(window.frame.height * k))
            config.showsCursor = false
            config.ignoreShadowsSingleWindow = true
            // A window that cannot be captured (minimized, closing) is left out of this screenshot only.
            guard let image = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
            else { continue }
            let top = (window.frame.minY - bounds.minY) * k
            ctx.draw(image, in: CGRect(
                x: (window.frame.minX - bounds.minX) * k, y: Double(size.height) - top - window.frame.height * k,
                width: window.frame.width * k, height: window.frame.height * k))
        }
        guard let image = ctx.makeImage() else { throw GrabError.draw }
        return ScreenGrab(image: image, display: area.display)
    }

    /// Windows to choose from in the menu: ordinary titled windows of other apps, on any desktop.
    static func windows() async -> [WindowTarget] {
        guard let content = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false)
        else { return [] }
        let own = Bundle.main.bundleIdentifier
        return content.windows
            .filter {
                $0.windowLayer == 0 && $0.frame.width >= 100 && $0.frame.height >= 100 && !($0.title ?? "").isEmpty
                    && $0.owningApplication != nil && $0.owningApplication?.bundleIdentifier != own
            }
            .map { WindowTarget(id: $0.windowID, app: $0.owningApplication?.applicationName ?? "", title: $0.title ?? "") }
            .sorted { ($0.app, $0.title) < ($1.app, $1.title) }
    }

    /// The windows of the desktop now shown on a display: what a pinned area starts from.
    static func desktopWindows(display id: UInt32) async -> [UInt32] {
        guard let content = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true),
              let display = content.displays.first(where: { $0.displayID == id })
        else { return [] }
        let own = Bundle.main.bundleIdentifier
        return content.windows
            .filter { $0.windowLayer == 0 && $0.owningApplication?.bundleIdentifier != own && $0.frame.intersects(display.frame) }
            .map(\.windowID)
    }

    private static func rect(_ area: AreaTarget) -> CGRect {
        CGRect(x: area.x, y: area.y, width: area.width, height: area.height)
    }

    /// Pixels per point of a display.
    private static func scale(_ display: SCDisplay) -> Double {
        let mode = CGDisplayCopyDisplayMode(display.displayID)
        return Double(mode?.pixelWidth ?? display.width) / Double(max(display.width, 1))
    }

    /// Stacking order of all windows, 0 for the frontmost.
    private static func frontToBack() -> [UInt32: Int] {
        let list = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? []
        var order: [UInt32: Int] = [:]
        for (i, info) in list.enumerated() {
            if let id = (info[kCGWindowNumber as String] as? NSNumber)?.uint32Value, order[id] == nil { order[id] = i }
        }
        return order
    }

    private static func displayUnderCursor() -> CGDirectDisplayID? {
        guard let point = CGEvent(source: nil)?.location else { return nil }
        var id = CGDirectDisplayID(0)
        var count: UInt32 = 0
        return CGGetDisplaysWithPoint(point, 1, &id, &count) == .success && count > 0 ? id : nil
    }
}
