import AppKit
import DabberCore
import DabberSpeech
import SwiftUI

struct MenuApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate

    var body: some Scene {
        MenuBarExtra {
            MenuContent(model: AppDelegate.model, feed: AppDelegate.feed)
        } label: {
            Image(systemName: icon)
        }
        .menuBarExtraStyle(.window)
    }

    @MainActor private var icon: String {
        let model = AppDelegate.model
        if model.warning != nil || AppDelegate.feed.hasProblem { return "exclamationmark.triangle.fill" }
        return model.isRecording ? "record.circle.fill" : "waveform"
    }
}

struct MenuContent: View {
    let model: RecorderModel
    let feed: FeedModel
    /// Kept between launches; `@AppStorage` instead of `@State`, whose macro plugin the Command Line Tools lack.
    @AppStorage("virtualMicOpen") private var virtualMicOpen = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            RecordHeader(model: model)
            if model.isRecording { RecordingNow(model: model) }
            Card(title: "Sources", systemImage: "waveform") { SourcesCard(model: model) }
            Card(title: "Slides", systemImage: "rectangle.on.rectangle") { SlidesCard(model: model) }
            Card(title: "After Stop", systemImage: "wand.and.stars") { AfterStopCard(model: model) }
            Card(title: "Virtual mic", systemImage: "mic.badge.plus", collapsed: !virtualMicOpen, toggle: { virtualMicOpen.toggle() }) {
                VirtualMicSection(model: feed)
            }
            FooterRow(model: model)
        }
        .padding(12)
        .frame(width: 340)
        .onAppear { model.menuOpened() }
        .onDisappear { model.menuClosed() }
    }
}

/// A rounded group with a small header; optionally folds away.
struct Card<Content: View>: View {
    let title: String
    let systemImage: String
    var collapsed = false
    var toggle: (() -> Void)?
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: systemImage).foregroundStyle(.secondary).frame(width: 16)
                Text(title).font(.subheadline.weight(.semibold))
                Spacer()
                if toggle != nil {
                    Image(systemName: collapsed ? "chevron.down" : "chevron.up").foregroundStyle(.secondary)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { toggle?() }
            if !collapsed { content }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

struct LevelBar: View {
    let db: Double
    var warn = false

    var body: some View {
        Capsule()
            .fill(.quaternary)
            .overlay(alignment: .leading) {
                Capsule()
                    .fill(warn ? Color.orange : Color.green)
                    .frame(width: 70 * max(0, min(1, (db + 60) / 60)))
            }
            .frame(width: 70, height: 6)
            .transaction { $0.animation = nil }
    }
}

/// The big Record / Stop button, the time, and what needs attention.
struct RecordHeader: View {
    let model: RecorderModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Button { Task { await model.startStop() } } label: {
                    Label(
                        model.isRecording ? "Stop" : "Record",
                        systemImage: model.isRecording ? "stop.fill" : "circle.fill")
                }
                .buttonStyle(RecordButtonStyle(recording: model.isRecording))
                .disabled(!model.canStartStop)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        if model.isRecording {
                            Image(systemName: "circle.fill")
                                .font(.system(size: 9))
                                .foregroundStyle(RecordButtonStyle.red)
                                .symbolEffect(.pulse, options: .repeating)
                        }
                        Text(model.isRecording ? model.elapsed : "Dabber")
                            .font(.title2.weight(.semibold)).monospacedDigit()
                    }
                    Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
                Spacer()
            }
            if let warning = model.warning { Notice(text: warning, color: .orange) }
            if let error = model.errorText { Notice(text: error, color: .red) }
        }
    }

    private var subtitle: String {
        if let finishing = model.finishing { return finishing }
        if model.stopping || model.recordTitle.hasPrefix("Finalizing") { return model.recordTitle }
        return model.isRecording ? "Recording" : "Ready to record"
    }
}

/// A solid, saturated button: the menu's translucent background washes out the system tint, so the colours are
/// drawn here. Red to record; while recording, a deep red with a white square to stop.
struct RecordButtonStyle: ButtonStyle {
    static let red = Color(red: 1.0, green: 0.23, blue: 0.19)
    static let deepRed = Color(red: 0.78, green: 0.06, blue: 0.08)

    let recording: Bool
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 18)
            .padding(.vertical, 9)
            .frame(minWidth: 118)
            .background(
                Capsule().fill(LinearGradient(
                    colors: recording ? [Self.deepRed, Color(red: 0.55, green: 0.03, blue: 0.05)]
                        : [Color(red: 1.0, green: 0.36, blue: 0.30), Self.red],
                    startPoint: .top, endPoint: .bottom)))
            .overlay(Capsule().strokeBorder(.white.opacity(0.28), lineWidth: 1))
            .shadow(color: Self.red.opacity(enabled ? 0.5 : 0), radius: configuration.isPressed ? 2 : 7, y: 2)
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .opacity(enabled ? 1 : 0.45)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

struct Notice: View {
    let text: String
    let color: Color

    var body: some View {
        Label(text, systemImage: "exclamationmark.triangle.fill")
            .font(.caption)
            .foregroundStyle(color)
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

/// Only while recording: the name, marks and the live transcript.
struct RecordingNow: View {
    let model: RecorderModel
    @AppStorage(AppDelegate.liveKey) private var live = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Name (optional)", text: Binding(get: { model.title }, set: { model.setTitle($0) }))
                .textFieldStyle(.roundedBorder)
            MarksView(model: model)
            if live { LiveTranscriptView() }
        }
    }
}

struct SourcesCard: View {
    let model: RecorderModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(model.rows) { row in
                HStack(spacing: 8) {
                    Image(systemName: row.id == RecorderModel.computerID ? "speaker.wave.2" : "mic")
                        .foregroundStyle(row.connected ? Color.secondary : Color.orange)
                        .frame(width: 16)
                    Toggle(row.title, isOn: Binding(get: { row.enabled }, set: { _ in model.toggle(row.id) }))
                        .disabled(model.isRecording)
                    Spacer()
                    if row.showsLevel { LevelBar(db: row.levelDb, warn: row.silent) }
                }
            }
            Divider()
            Picker("Backup mic", selection: Binding(get: { model.backupSelection ?? "" }, set: { model.setBackup($0.isEmpty ? nil : $0) })) {
                Text("None").tag("")
                ForEach(model.backupChoices) { choice in Text(choice.title).tag(choice.id) }
            }
            .font(.callout)
        }
    }
}

/// Slides on or off (only before Record) and what they show (any time), chosen in `CapturePicker`.
struct SlidesCard: View {
    let model: RecorderModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Record slides", isOn: Binding(get: { model.slidesOn }, set: { _ in model.toggleSlides() }))
                .toggleStyle(.switch)
                .controlSize(.small)
                .help("A screenshot every 2 s when the picture changes, made into a video after Stop. Can be switched on or off during a recording too")
            if model.slidesOn {
                HStack(spacing: 8) {
                    Image(systemName: symbol).foregroundStyle(.secondary).frame(width: 16)
                    Text(model.screenTarget.title).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button("Choose…") { CapturePicker.show(model: model) }
                }
                if case .area(let area) = model.screenTarget {
                    Toggle("Area follows when you switch desktops", isOn: Binding(
                        get: { area.followsDesktops },
                        set: {
                            var changed = area
                            changed.followsDesktops = $0
                            model.setScreenTarget(.area(changed))
                        }))
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .help("Off: the area keeps showing the desktop where it was chosen, even while you are on another one")
                }
            }
        }
    }

    private var symbol: String {
        switch model.screenTarget {
        case .screen: "display"
        case .window: "macwindow"
        case .area: "rectangle.dashed"
        }
    }
}

struct AfterStopCard: View {
    let model: RecorderModel
    @AppStorage(AppDelegate.cleanMicsKey) private var cleanMics = true
    @AppStorage(AppDelegate.liveKey) private var live = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle("Clean up microphones", isOn: $cleanMics)
                .help("Remove the echo of Mac audio, background noise and room echo from the microphone tracks")
                .onChange(of: cleanMics) { _, on in if on { LocalVqeModel.shared.prepare() } }
            Toggle("Transcribe", isOn: Binding(get: { model.transcribeOn }, set: { _ in model.toggleTranscribe() }))
            if let line = model.speechStatusText {
                Text(line).font(.caption).foregroundStyle(speechFailed ? .orange : .secondary).padding(.leading, 20)
            }
            Toggle("Live transcript while recording", isOn: $live)
                .help("Show the last lines in this menu, about 8 s late. The transcript saved after Stop is made again from the whole recording.")
                .onChange(of: live) { _, on in
                    if !on { AppDelegate.setLive(false) } else if model.isRecording { AppDelegate.setLive(true) }
                }
        }
        .toggleStyle(.switch)
        .controlSize(.small)
    }

    private var speechFailed: Bool {
        if case .failed = model.speechStatus { true } else { false }
    }
}

struct FooterRow: View {
    let model: RecorderModel

    var body: some View {
        HStack(spacing: 10) {
            Button { chooseFolder() } label: {
                Label(FileManager.default.displayName(atPath: model.outputFolder.path), systemImage: "folder")
                    .lineLimit(1).truncationMode(.middle)
            }
            .help("Where recordings go: click to change")
            Button { if let dir = model.lastSessionDir { NSWorkspace.shared.activateFileViewerSelecting([dir]) } } label: {
                Label("Last recording", systemImage: "arrow.up.forward.square")
            }
            .disabled(model.lastSessionDir == nil)
            Spacer()
            Button("About") { showAbout() }
                .help("Version and code name")
            Button("Quit") { NSApplication.shared.terminate(nil) }
        }
        .buttonStyle(.borderless)
        .font(.caption)
    }

    /// The standard About window, with the code name in the version line: "Version 1.0.0 “Screaming Ant”". The build
    /// number is not shown: Dabber is built from source, with no App Store or updater to read it, so nobody tracks it.
    private func showAbout() {
        let info = Bundle.main.infoDictionary
        let number = info?["CFBundleShortVersionString"] as? String ?? "dev"
        let name = AppPaths.codename.map { " “\($0)”" } ?? ""
        NSApp.activate()
        NSApp.orderFrontStandardAboutPanel(options: [.applicationVersion: number + name, .version: ""])
    }

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
}

/// The live transcript, refreshed every second, newest at the bottom. In the menu by default; the pin button moves
/// it to `LiveTranscriptPanel`, a large translucent panel over all windows, and back.
struct LiveTranscriptView: View {
    /// True inside the floating panel.
    var floating = false
    @AppStorage(LiveTranscriptPanel.pinnedKey) private var pinned = false

    var body: some View {
        if pinned && !floating {
            HStack {
                Label("Live transcript is pinned on screen", systemImage: "pin.fill").font(.caption)
                Spacer()
                Button("Bring back") { LiveTranscriptPanel.unpin() }.buttonStyle(.borderless).font(.caption)
            }
            .foregroundStyle(.secondary)
            .padding(10)
            .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        } else {
            transcript
        }
    }

    private var transcript: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            let lines = Array(LiveTranscriber.shared.lines.suffix(100))
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label("Live transcript", systemImage: "text.bubble")
                        .font(floating ? .headline : .caption.weight(.semibold))
                        .foregroundStyle(floating ? .primary : .secondary)
                    Spacer()
                    Button { floating ? LiveTranscriptPanel.unpin() : LiveTranscriptPanel.pin() } label: {
                        Image(systemName: floating ? "pin.slash" : "pin")
                    }
                    .buttonStyle(.borderless)
                    .help(floating ? "Put the transcript back into the menu" : "Pin the transcript on screen: a large panel you can move anywhere")
                }
                if lines.isEmpty {
                    Text(LiveTranscriber.shared.status.map { "Live transcript \($0)" }
                        ?? "Listening… a line appears about 8 s after it is said.")
                        .font(.caption).foregroundStyle(.secondary)
                    if floating { Spacer() }
                } else if !floating {
                    // In the menu: the last lines without a scroll view. The menu window takes its content's ideal
                    // height, and a ScrollView with only a maximum height has an ideal height of zero there, so the
                    // lines were hidden. The whole history is in the pinned panel.
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(lines.suffix(6)) { line in row(line) }
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    if let status = LiveTranscriber.shared.status {
                        Text("Live transcript \(status)").font(.caption).foregroundStyle(.orange)
                    }
                } else {
                    ScrollViewReader { proxy in
                        ScrollView {
                            VStack(alignment: .leading, spacing: 12) {
                                ForEach(lines) { line in row(line).id(line.id) }
                            }
                            .padding(.trailing, 6)
                        }
                        .frame(maxHeight: .infinity)
                        .onAppear { proxy.scrollTo(lines.last?.id, anchor: .bottom) }
                        .onChange(of: lines.last?.id) { _, last in
                            withAnimation { proxy.scrollTo(last, anchor: .bottom) }
                        }
                    }
                    if let status = LiveTranscriber.shared.status {
                        Text("Live transcript \(status)").font(.caption).foregroundStyle(.orange)
                    }
                }
            }
            .textSelection(.enabled)
            .padding(floating ? 16 : 10)
            .frame(maxWidth: .infinity, maxHeight: floating ? .infinity : nil, alignment: .topLeading)
            .background(floating ? AnyShapeStyle(.clear) : AnyShapeStyle(.quaternary.opacity(0.45)),
                        in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }

    private func row(_ line: LiveTranscriber.Line) -> some View {
        let color = line.speaker == Transcript.me ? Color.accentColor : Color.purple
        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(line.speaker).font(.caption.weight(.bold)).foregroundStyle(color)
                Text(line.at, style: .time).font(.caption2).foregroundStyle(.tertiary)
            }
            Text(line.text)
                .font(floating ? .title3 : .callout)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The pinned live transcript: a large translucent panel over all windows, on every desktop and over full-screen
/// apps, moved by dragging anywhere on it and resized from its edges. Closing it or its pin button puts the transcript
/// back into the menu. Whether it is pinned is remembered, so a pinned transcript opens with the next recording.
@MainActor
enum LiveTranscriptPanel {
    static let pinnedKey = "liveTranscriptPinned"
    private static var panel: NSPanel?
    private static let closer = Closer()

    static var pinned: Bool { UserDefaults.standard.bool(forKey: pinnedKey) }

    static func pin() {
        UserDefaults.standard.set(true, forKey: pinnedKey)
        show()
    }

    static func unpin() {
        UserDefaults.standard.set(false, forKey: pinnedKey)
        let closing = panel
        panel = nil
        closing?.delegate = nil
        closing?.close()
    }

    /// The panel's own close button: it is closing already.
    fileprivate static func closed() {
        UserDefaults.standard.set(false, forKey: pinnedKey)
        panel = nil
    }

    /// Opens the panel if the transcript is pinned (for the start of a recording).
    static func showIfPinned() {
        if pinned { show() }
    }

    private static func show() {
        if let panel {
            panel.orderFrontRegardless()
            return
        }
        let size = NSSize(width: 460, height: 560)
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .resizable, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered, defer: false)
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isReleasedWhenClosed = false
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isMovableByWindowBackground = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.alphaValue = 0.92
        panel.minSize = NSSize(width: 300, height: 220)
        panel.setFrameAutosaveName("LiveTranscriptPanel")
        panel.delegate = closer
        let content = NSVisualEffectView()
        content.material = .hudWindow
        content.blendingMode = .behindWindow
        content.state = .active
        content.wantsLayer = true
        content.layer?.cornerRadius = 14
        let hosting = NSHostingView(rootView: LiveTranscriptView(floating: true).padding(.top, 12))
        hosting.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            hosting.topAnchor.constraint(equalTo: content.topAnchor),
            hosting.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
        panel.contentView = content
        if !panel.setFrameUsingName("LiveTranscriptPanel") {
            let visible = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame ?? .zero
            panel.setFrame(NSRect(
                x: visible.maxX - size.width - 16, y: visible.maxY - size.height - 16,
                width: size.width, height: size.height), display: false)
        }
        panel.orderFrontRegardless()
        self.panel = panel
    }

    /// The close button unpins.
    private final class Closer: NSObject, NSWindowDelegate {
        func windowWillClose(_ notification: Notification) {
            MainActor.assumeIsolated { LiveTranscriptPanel.closed() }
        }
    }
}

struct MarksView: View {
    let model: RecorderModel

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Button { model.mark() } label: { Label("Mark", systemImage: "bookmark") }
                    .disabled(!model.canMark)
                if let hint = model.hotkeyHint {
                    Text(hint).font(.caption).foregroundStyle(.secondary)
                }
            }
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
    let model: FeedModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle("On", isOn: Binding(get: { model.isOn }, set: { model.setOn($0) }))
                .toggleStyle(.switch)
                .controlSize(.small)
                .disabled(!model.isOn && !model.canTurnOn)
            Text("In calls/OBS pick \"Dabber Mic\"").font(.caption).foregroundStyle(.secondary)
            if model.showsStatus {
                HStack {
                    Text("Status: \(model.statusText)").font(.caption)
                    Spacer()
                    if model.showsLevel { LevelBar(db: model.levelDb) }
                }
            }
            if model.showsDetails {
                Toggle("Mac audio", isOn: Binding(get: { model.settings.computerAudio }, set: { model.setComputerAudio($0) }))
                if model.settings.computerAudio { exclusions }
                Picker("Microphone:", selection: Binding(get: { model.settings.micUID ?? "" }, set: { model.selectMic($0.isEmpty ? nil : $0) })) {
                    Text("None").tag("")
                    ForEach(model.micChoices) { choice in
                        Text(choice.connected ? choice.name : "\(choice.name) (not connected)").tag(choice.id)
                    }
                }
            }
        }
    }

    private var exclusions: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("except:").font(.caption).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                ForEach(model.excluded) { app in
                    HStack(spacing: 2) {
                        Text(app.name).font(.caption)
                        Button { model.include(app.bundleID) } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless)
                    }
                }
            }
            Spacer()
            Menu("+ app") {
                ForEach(model.candidates) { app in
                    Button(app.name) { model.exclude(app.bundleID) }
                }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .disabled(model.candidates.isEmpty)
        }
        .padding(.leading, 20)
    }
}
