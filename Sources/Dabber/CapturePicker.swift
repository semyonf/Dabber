import AppKit
import DabberCore
import SwiftUI

/// The window for choosing what the slides show, like the share window of call apps: a grid of the screen, an area
/// and every window with a picture of it. Click to select, double-click or "Use" to take it.
@MainActor
enum CapturePicker {
    private static var panel: NSPanel?

    static func show(model: RecorderModel) {
        panel?.close()
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 780, height: 560),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        panel.title = "Choose what the slides show"
        panel.isReleasedWhenClosed = false
        panel.level = .floating
        panel.minSize = NSSize(width: 520, height: 400)
        panel.contentView = NSHostingView(rootView: CapturePickerView(current: model.screenTarget) { choice in
            Self.panel?.close()
            Self.panel = nil
            guard let choice else { return }
            if !model.slidesOn, !model.isRecording { model.toggleSlides() }
            switch choice {
            case .screen: model.setScreenTarget(.screen)
            case .window(let window): model.setScreenTarget(.window(window))
            case .area: pickArea(model: model)
            }
        })
        panel.center()
        NSApp.activate()
        panel.makeKeyAndOrderFront(nil)
        self.panel = panel
    }

    /// Dims the screens for dragging a rectangle; keeps the "follows desktops" choice of the previous area.
    static func pickArea(model: RecorderModel) {
        var follows = true
        if case .area(let area) = model.screenTarget { follows = area.followsDesktops }
        AreaPicker.pick { picked in
            guard let picked else { return }
            Task {
                let windows = await LiveScreenGrabber.desktopWindows(display: picked.display)
                model.setScreenTarget(.area(AreaTarget(
                    display: picked.display, x: picked.rect.minX, y: picked.rect.minY,
                    width: picked.rect.width, height: picked.rect.height, followsDesktops: follows, windows: windows)))
            }
        }
    }
}

enum CaptureChoice: Hashable {
    case screen
    case area
    case window(WindowTarget)
}

struct CapturePickerView: View {
    let current: ScreenTarget
    let done: (CaptureChoice?) -> Void

    /// The view is the root of its panel and is made once, so it can own its state without `@State`, whose macro
    /// plugin the Command Line Tools do not have.
    private let state = CapturePickerState()

    private let columns = [GridItem(.adaptive(minimum: 170, maximum: 240), spacing: 16)]

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    group("Screen") {
                        tile(.screen, title: "Whole screen", subtitle: "The display with the pointer",
                             picture: state.screen?.image, icon: nil, symbol: "display")
                        tile(.area, title: "Area…", subtitle: "Drag a rectangle on any display",
                             picture: nil, icon: nil, symbol: "rectangle.dashed")
                    }
                    group("Windows") {
                        ForEach(state.windows) { window in
                            tile(.window(window.target), title: window.target.app,
                                 subtitle: window.target.title + (window.onScreen ? "" : " · other desktop"),
                                 picture: state.pictures[window.id]?.image,
                                 icon: NSRunningApplication(processIdentifier: window.pid)?.icon, symbol: "macwindow")
                        }
                    }
                    if state.loaded && state.windows.isEmpty {
                        Text("No windows found. Dabber needs Screen Recording permission in System Settings > Privacy & Security.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }
                .padding(20)
            }
            Divider()
            HStack {
                Text(hint).font(.callout).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { done(nil) }.keyboardShortcut(.cancelAction)
                Button(state.selection == .area ? "Choose area" : "Use") { done(state.selection) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(state.selection == nil)
            }
            .padding(14)
        }
        .frame(minWidth: 520, minHeight: 400)
        .task { await load() }
    }

    private var hint: String {
        switch state.selection {
        case .window: "Recorded even when covered or on another desktop; not when minimized."
        case .area: "The screens dim: drag a rectangle, Esc cancels."
        case .screen: "Whatever the display with the pointer shows."
        case nil: "Choose what the slides show."
        }
    }

    @ViewBuilder
    private func group<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.headline)
            LazyVGrid(columns: columns, alignment: .leading, spacing: 16) { content() }
        }
    }

    private func tile(
        _ choice: CaptureChoice, title: String, subtitle: String, picture: CGImage?, icon: NSImage?, symbol: String
    ) -> some View {
        let selected = state.selection == choice
        return VStack(alignment: .leading, spacing: 6) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.quaternary.opacity(0.6))
                if let picture {
                    Image(decorative: picture, scale: 1).resizable().aspectRatio(contentMode: .fit).padding(6)
                } else {
                    Image(systemName: symbol).font(.system(size: 30)).foregroundStyle(.secondary)
                }
            }
            .frame(height: 112)
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(selected ? Color.accentColor : Color.secondary.opacity(0.2), lineWidth: selected ? 3 : 1))
            HStack(spacing: 5) {
                if let icon { Image(nsImage: icon).resizable().frame(width: 16, height: 16) }
                Text(title).font(.callout.weight(.medium)).lineLimit(1)
            }
            Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { done(choice) }
        .onTapGesture { state.selection = choice }
        .help(subtitle)
    }

    private func load() async {
        switch current {
        case .screen: state.selection = .screen
        case .area: state.selection = .area
        case .window(let window): state.selection = .window(window)
        }
        state.windows = await LiveScreenGrabber.windows()
        state.loaded = true
        state.screen = await LiveScreenGrabber.screenThumbnail()
        for await (id, picture) in LiveScreenGrabber.thumbnails(of: state.windows.map(\.id)) {
            state.pictures[id] = picture
        }
    }
}

@MainActor @Observable
final class CapturePickerState {
    var selection: CaptureChoice?
    var windows: [LiveScreenGrabber.WindowChoice] = []
    var pictures: [UInt32: LiveScreenGrabber.Picture] = [:]
    var screen: LiveScreenGrabber.Picture?
    var loaded = false
}
