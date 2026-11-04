import AppKit

/// Dims every display; dragging on one of them chooses a rectangle there, Esc cancels. Hands back the display and the
/// rectangle in points from that display's top left corner.
@MainActor
final class AreaPicker {
    typealias Picked = (display: UInt32, rect: CGRect)

    private static var current: AreaPicker?
    private var windows: [NSWindow] = []
    private let done: @MainActor (Picked?) -> Void

    private init(done: @escaping @MainActor (Picked?) -> Void) {
        self.done = done
    }

    static func pick(_ done: @escaping @MainActor (Picked?) -> Void) {
        current?.finish(nil)
        let picker = AreaPicker(done: done)
        current = picker
        picker.show()
    }

    private func show() {
        let mouse = NSEvent.mouseLocation
        for screen in NSScreen.screens {
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { continue }
            let display = number.uint32Value
            let window = OverlayWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.level = .screenSaver
            window.isOpaque = false
            window.backgroundColor = .clear
            window.hasShadow = false
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            let view = SelectionView(frame: CGRect(origin: .zero, size: screen.frame.size))
            view.onDone = { [weak self] rect in self?.finish(rect.map { (display, $0) }) }
            window.contentView = view
            window.setFrame(screen.frame, display: true)
            window.orderFrontRegardless()
            windows.append(window)
            if screen.frame.contains(mouse) {
                window.makeKey()
                window.makeFirstResponder(view)
            }
        }
        NSApp.activate()
        if windows.isEmpty { finish(nil) }
    }

    private func finish(_ picked: Picked?) {
        guard Self.current === self else { return }
        Self.current = nil
        for window in windows { window.orderOut(nil) }
        windows = []
        done(picked)
    }
}

private final class OverlayWindow: NSWindow {
    override var canBecomeKey: Bool { true }
}

private final class SelectionView: NSView {
    /// The chosen rectangle from the top left corner, or nil when cancelled.
    var onDone: ((CGRect?) -> Void)?
    private var start: CGPoint?
    private var selection: CGRect?
    private static let minSide: CGFloat = 40

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        window?.makeKey()
        window?.makeFirstResponder(self)
        start = point(event)
        selection = nil
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start else { return }
        let p = point(event)
        selection = CGRect(x: min(start.x, p.x), y: min(start.y, p.y), width: abs(p.x - start.x), height: abs(p.y - start.y))
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        mouseDragged(with: event)
        start = nil
        guard let selection = selection?.integral, selection.width >= Self.minSide, selection.height >= Self.minSide else {
            self.selection = nil
            needsDisplay = true
            return
        }
        onDone?(CGRect(x: selection.minX, y: bounds.height - selection.maxY, width: selection.width, height: selection.height))
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onDone?(nil) } else { super.keyDown(with: event) }
    }

    override func cancelOperation(_ sender: Any?) { onDone?(nil) }

    private func point(_ event: NSEvent) -> CGPoint {
        let p = convert(event.locationInWindow, from: nil)
        return CGPoint(x: min(max(p.x, 0), bounds.width), y: min(max(p.y, 0), bounds.height))
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.35).setFill()
        bounds.fill()
        let hint = selection.map { "\(Int($0.width))×\(Int($0.height))" }
            ?? "Drag to choose the area for slides · Esc to cancel"
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 15, weight: .medium), .foregroundColor: NSColor.white,
        ]
        let size = (hint as NSString).size(withAttributes: attributes)
        if let selection {
            NSColor.clear.setFill()
            selection.fill(using: .copy)
            NSColor.white.setStroke()
            let border = NSBezierPath(rect: selection.insetBy(dx: 0.5, dy: 0.5))
            border.lineWidth = 1
            border.stroke()
            (hint as NSString).draw(at: CGPoint(x: selection.minX, y: max(selection.minY - size.height - 6, 4)), withAttributes: attributes)
        } else {
            (hint as NSString).draw(
                at: CGPoint(x: (bounds.width - size.width) / 2, y: bounds.height * 0.75), withAttributes: attributes)
        }
    }
}
