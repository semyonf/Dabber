import AppKit
import DabberCore
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

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            RecordingSection(model: model)
            Divider()
            VirtualMicSection(model: feed)
            Divider()
            Button("Quit") { NSApplication.shared.terminate(nil) }
                .buttonStyle(.borderless)
        }
        .padding(12)
        .frame(width: 300)
        .onAppear { model.menuOpened() }
        .onDisappear { model.menuClosed() }
    }
}

struct SectionHeader: View {
    let title: String

    var body: some View {
        Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
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
                    .fill(warn ? Color.orange : Color.accentColor)
                    .frame(width: 70 * max(0, min(1, (db + 60) / 60)))
            }
            .frame(width: 70, height: 6)
            .transaction { $0.animation = nil }
    }
}

struct RecordingSection: View {
    let model: RecorderModel
    @AppStorage(AppDelegate.cleanMicsKey) var cleanMics = true

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                SectionHeader(title: "RECORDING")
                Spacer()
                Button(model.recordTitle) { Task { await model.startStop() } }
                    .disabled(!model.canStartStop)
                Text(model.elapsed).monospacedDigit().foregroundStyle(.secondary)
            }
            if let finishing = model.finishing {
                Text(finishing).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            ForEach(model.rows) { row in
                HStack {
                    Toggle(row.title, isOn: Binding(get: { row.enabled }, set: { _ in model.toggle(row.id) }))
                        .disabled(model.isRecording)
                    Spacer()
                    if row.showsLevel { LevelBar(db: row.levelDb, warn: row.silent) }
                }
            }
            Picker("Backup mic:", selection: Binding(get: { model.backupSelection ?? "" }, set: { model.setBackup($0.isEmpty ? nil : $0) })) {
                Text("None").tag("")
                ForEach(model.backupChoices) { choice in Text(choice.title).tag(choice.id) }
            }
            Toggle("Record slides", isOn: Binding(get: { model.slidesOn }, set: { _ in model.toggleSlides() }))
                .disabled(model.isRecording)
            if model.slidesOn { ScreenTargetRow(model: model) }
            Toggle("Transcribe", isOn: Binding(get: { model.transcribeOn }, set: { _ in model.toggleTranscribe() }))
            if let line = model.speechStatusText {
                Text(line).font(.caption).foregroundStyle(speechFailed ? .orange : .secondary)
            }
            Toggle("Clean up microphones", isOn: $cleanMics)
                .help("After Stop, remove the echo of Mac audio and steady background noise from the microphone tracks")
            if model.isRecording {
                HStack {
                    Text("Name").font(.caption).foregroundStyle(.secondary)
                    TextField("Title (optional)", text: Binding(get: { model.title }, set: { model.setTitle($0) }))
                }
                MarksView(model: model)
            }
            if let warning = model.warning {
                Label(warning, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
            }
            if let error = model.errorText {
                Text(error).font(.caption).foregroundStyle(.red)
            }
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
                if let dir = model.lastSessionDir { NSWorkspace.shared.activateFileViewerSelecting([dir]) }
            }
            .buttonStyle(.borderless)
            .disabled(model.lastSessionDir == nil)
        }
    }

    private var speechFailed: Bool {
        if case .failed = model.speechStatus { true } else { false }
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

/// What the slides show: the whole screen, one window or an area. Can be changed while recording.
struct ScreenTargetRow: View {
    let model: RecorderModel
    @State private var windows: [WindowTarget] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Show:").font(.caption).foregroundStyle(.secondary)
                Menu(model.screenTarget.title) {
                    Button("Whole screen") { model.setScreenTarget(.screen) }
                    Button("Area…") { pickArea() }
                    Section("Window") {
                        if windows.isEmpty { Text("No windows found") }
                        ForEach(windows, id: \.id) { window in
                            Button(ScreenTarget.window(window).title) { model.setScreenTarget(.window(window)) }
                        }
                    }
                }
                .menuStyle(.borderlessButton)
                .lineLimit(1)
            }
            if case .area(let area) = model.screenTarget {
                Toggle("Area follows when you switch desktops", isOn: Binding(
                    get: { area.followsDesktops },
                    set: {
                        var changed = area
                        changed.followsDesktops = $0
                        model.setScreenTarget(.area(changed))
                    }))
                    .help("Off: the area keeps showing the desktop where it was chosen, even while you are on another one")
            }
        }
        .padding(.leading, 20)
        .task { windows = await LiveScreenGrabber.windows() }
    }

    private func pickArea() {
        var follows = true
        if case .area(let area) = model.screenTarget { follows = area.followsDesktops }
        let model = self.model
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

struct MarksView: View {
    let model: RecorderModel

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button("Mark") { model.mark() }
                .disabled(!model.canMark)
            if let hint = model.hotkeyHint {
                Text(hint).font(.caption).foregroundStyle(.secondary)
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
            HStack {
                SectionHeader(title: "VIRTUAL MIC")
                Spacer()
                Toggle("", isOn: Binding(get: { model.isOn }, set: { model.setOn($0) }))
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .labelsHidden()
                    .disabled(!model.isOn && !model.canTurnOn)
            }
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
