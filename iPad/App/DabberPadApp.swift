import DabberCore
import DabberSpeech
import ReplayKit
import SwiftUI
import UniformTypeIdentifiers
import UserNotifications

@main
struct DabberPadApp: App {
    @State private var library = Library()

    var body: some Scene {
        WindowGroup {
            MainView(library: library)
                .onAppear {
                    library.launched()
                    UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
                }
        }
    }
}

struct MainView: View {
    @Bindable var library: Library
    @Environment(\.scenePhase) private var phase
    @AppStorage(Library.transcribeKey) private var transcribe = true
    @AppStorage(Library.cleanMicsKey) private var cleanMics = true
    @AppStorage(Library.calendarKey) private var calendar = true
    @State private var choosingFolder = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(spacing: 16) {
                        BroadcastButton().frame(width: 60, height: 60)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(library.recordingNow ? "Recording" : "Record").font(.headline)
                            Text(library.recordingNow
                                ? "Stop from the red indicator at the top or in Control Center. Then come back here."
                                : "Tap the button, turn Microphone on at the bottom of the sheet, then Start Broadcast. "
                                    + "Switch to your call: its sound, your microphone and the screen are recorded.")
                                .font(.callout).foregroundStyle(.secondary)
                        }
                    }
                    if let finishing = library.finishing {
                        HStack {
                            ProgressView()
                            Text("Finishing \(finishing)… Keep Dabber open.")
                        }
                    }
                    ForEach(library.notes, id: \.self) { note in
                        Label(note, systemImage: "exclamationmark.triangle").foregroundStyle(.orange).font(.callout)
                    }
                }
                Section("Settings") {
                    Toggle("Record slides", isOn: $library.slidesOn)
                    Toggle("Transcribe", isOn: $transcribe)
                        .onChange(of: transcribe) { _, on in if on { ParakeetSpeech.shared.prepare() } }
                    if transcribe, let line = speechLine { Text(line).font(.caption).foregroundStyle(.secondary) }
                    Toggle("Clean up microphone", isOn: $cleanMics)
                        .onChange(of: cleanMics) { _, on in if on { LocalVqeModel.shared.prepare() } }
                    Toggle("Name recordings from the calendar", isOn: $calendar)
                        .onChange(of: calendar) { _, on in if on { library.askForCalendar() } }
                    HStack {
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Save to")
                                Text(library.folderName).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                        } icon: {
                            Image(systemName: "folder")
                        }
                        Spacer()
                        if library.folder != nil {
                            Button("Reset") { library.resetFolder() }.buttonStyle(.borderless)
                        }
                        Button("Choose…") { choosingFolder = true }.buttonStyle(.borderless)
                    }
                    .fileImporter(isPresented: $choosingFolder, allowedContentTypes: [.folder]) { result in
                        if case .success(let url) = result { library.setFolder(url) }
                    }
                }
                Section {
                    if library.recordings.isEmpty { Text("None yet").foregroundStyle(.secondary) }
                    ForEach(library.recordings, id: \.self) { dir in
                        NavigationLink(dir.lastPathComponent) { RecordingView(dir: dir) }
                    }
                    .onDelete { offsets in
                        for i in offsets { library.delete(library.recordings[i]) }
                    }
                } header: {
                    Text("Recordings")
                } footer: {
                    Text(library.folder == nil
                        ? "Also in the Files app: On My iPad › Dabber › Recordings."
                        : "Also in the Files app, in \(library.folderName).")
                }
            }
            .navigationTitle("Dabber")
            .refreshable { library.refresh() }
        }
        .onChange(of: phase) { _, now in if now == .active { library.refresh() } }
        .task {
            // Notices the end of a broadcast while the app is open.
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                library.refresh()
            }
        }
    }

    private var speechLine: String? {
        switch ParakeetSpeech.shared.status {
        case .ready: "Speech model ready"
        case .downloading(let fraction?): "Downloading the speech model: \(Int(fraction * 100))%"
        case .downloading(nil): "Downloading the speech model…"
        case .preparing: "Preparing the speech model…"
        case .failed(let why, _): "Speech model failed: \(why)"
        case .idle: nil
        }
    }
}

/// The system button that opens the broadcast sheet with Dabber's extension chosen.
struct BroadcastButton: UIViewRepresentable {
    func makeUIView(context: Context) -> RPSystemBroadcastPickerView {
        let picker = RPSystemBroadcastPickerView(frame: CGRect(x: 0, y: 0, width: 60, height: 60))
        picker.preferredExtension = (Bundle.main.bundleIdentifier ?? "") + ".broadcast"
        picker.showsMicrophoneButton = true
        return picker
    }

    func updateUIView(_ view: RPSystemBroadcastPickerView, context: Context) {}
}

struct RecordingView: View {
    let dir: URL
    @State private var files: [URL] = []

    var body: some View {
        List {
            ForEach(files, id: \.self) { file in
                HStack {
                    Text(file.lastPathComponent)
                    Spacer()
                    ShareLink(item: file) { Image(systemName: "square.and.arrow.up") }
                        .buttonStyle(.borderless)
                }
            }
        }
        .navigationTitle(dir.lastPathComponent)
        .toolbar { ShareLink(items: files) { Label("Share all", systemImage: "square.and.arrow.up") } }
        .onAppear {
            files = ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
                .filter { !$0.hasDirectoryPath }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
        }
    }
}
