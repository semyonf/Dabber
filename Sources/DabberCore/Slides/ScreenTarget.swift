import Foundation

/// What the slides show.
public enum ScreenTarget: Codable, Equatable, Sendable {
    /// The display with the mouse pointer, whole.
    case screen
    /// One window, wherever it is: behind other windows or on another desktop (Space).
    case window(WindowTarget)
    /// A rectangle of one display.
    case area(AreaTarget)

    public var title: String {
        switch self {
        case .screen: return "Whole screen"
        case .window(let w): return w.title.isEmpty ? w.app : "\(w.app) — \(w.title)"
        case .area(let a): return "Area \(Int(a.width))×\(Int(a.height))"
        }
    }

    public static func decode(_ data: Data?) -> ScreenTarget {
        data.flatMap { try? JSONDecoder().decode(ScreenTarget.self, from: $0) } ?? .screen
    }

    public func encoded() -> Data { (try? JSONEncoder().encode(self)) ?? Data() }
}

public struct WindowTarget: Codable, Equatable, Sendable {
    /// `CGWindowID`: stays the same while the window exists.
    public let id: UInt32
    public let app: String
    public let title: String

    public init(id: UInt32, app: String, title: String) {
        self.id = id
        self.app = app
        self.title = title
    }
}

/// A rectangle in points, from the top left corner of the display.
public struct AreaTarget: Codable, Equatable, Sendable {
    public let display: UInt32
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double
    /// On: whatever the display shows there, so the area goes along when you swipe to another desktop.
    /// Off: the desktop on which the area was chosen, even while another desktop is shown.
    public var followsDesktops: Bool
    /// Windows of the desktop on which the area was chosen (what "off" starts from).
    public let windows: [UInt32]

    public init(
        display: UInt32, x: Double, y: Double, width: Double, height: Double, followsDesktops: Bool, windows: [UInt32]
    ) {
        self.display = display
        self.x = x
        self.y = y
        self.width = width
        self.height = height
        self.followsDesktops = followsDesktops
        self.windows = windows
    }
}

/// Which windows make up the desktop an area is pinned to. macOS tells apps which windows are on screen, not which
/// desktop a window belongs to. So while most of the known windows are on screen, that desktop is the one shown,
/// and its windows are taken again from what is on screen: new windows join, closed ones leave. While another desktop
/// is shown, the known windows stay as they are, minus the ones that no longer exist.
public enum DesktopWindows {
    public static func update(_ known: Set<UInt32>, onScreen: Set<UInt32>, existing: Set<UInt32>) -> Set<UInt32> {
        let alive = known.intersection(existing)
        let shown = alive.intersection(onScreen)
        guard !alive.isEmpty, shown.count * 2 > alive.count else { return alive }
        return onScreen
    }
}
