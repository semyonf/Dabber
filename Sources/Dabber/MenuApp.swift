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
    @State private var virtualMicOpen = false

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
                        systemImage: model.isRecording ? "stop.fill" : "record.circle")
                        .frame(minWidth: 96)
                }
                .buttonStyle(.borderedProminent)
                .tint(model.isRecording ? .gray : .red)
                .controlSize(.large)
                .disabled(!model.canStartStop)
                VStack(alignment: .leading, spacing: 1) {
                    Text(model.isRecording ? model.elapsed : "Dabber")
                        .font(.title2.weight(.semibold)).monospacedDigit()
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
                .disabled(model.isRecording)
                .help(model.isRecording ? "Slides can be switched on or off only before Record" : "A screenshot every 2 s when the picture changes, made into a video after Stop")
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
            Button("Quit") { NSApplication.shared.terminate(nil) }
        }
        .buttonStyle(.borderless)
        .font(.caption)
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

/// The last lines of the live transcript, refreshed every second, newest at the bottom.
struct LiveTranscriptView: View {
    static let shown = 30

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            let lines = Array(LiveTranscriber.shared.lines.suffix(Self.shown))
            VStack(alignment: .leading, spacing: 4) {
                Label("Live transcript", systemImage: "text.bubble").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                if lines.isEmpty {
                    Text(LiveTranscriber.shared.status.map { "Live transcript \($0)" }
                        ?? "Listening… a line appears about 8 s after it is said.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    ScrollViewReader { proxy in
                        ScrollView {
                            VStack(alignment: .leading, spacing: 4) {
                                ForEach(lines) { line in
                                    Text("\(Text(line.speaker).bold().foregroundStyle(line.speaker == Transcript.me ? Color.accentColor : Color.purple)) \(line.text)")
                                        .font(.callout)
                                        .fixedSize(horizontal: false, vertical: true)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .id(line.id)
                                }
                            }
                        }
                        .frame(maxHeight: 180)
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
            .padding(10)
            .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
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
