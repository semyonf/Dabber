import AVFoundation
import ReplayKit
import SwiftUI

@main
struct SpikeApp: App {
    var body: some Scene {
        WindowGroup { ContentView() }
    }
}

struct ContentView: View {
    @State private var sessions: [URL] = []
    @Environment(\.scenePhase) private var phase

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(spacing: 16) {
                        BroadcastButton().frame(width: 56, height: 56)
                        Text("Tap, turn the microphone on at the bottom of the sheet, then Start Broadcast. "
                            + "Make a call in another app, then stop from the red status bar or Control Center.")
                            .font(.callout)
                    }
                }
                Section("Recordings") {
                    if sessions.isEmpty { Text("None yet").foregroundStyle(.secondary) }
                    ForEach(sessions, id: \.self) { dir in
                        NavigationLink(dir.lastPathComponent) { SessionView(dir: dir) }
                    }
                    .onDelete { offsets in
                        for i in offsets { try? FileManager.default.removeItem(at: sessions[i]) }
                        reload()
                    }
                }
                if Store.root == nil {
                    Text(StoreError.noGroup(Store.groupID).localizedDescription).foregroundStyle(.red)
                }
            }
            .navigationTitle("Dabber Spike")
            .refreshable { reload() }
        }
        .onAppear { reload() }
        .onChange(of: phase) { _, now in if now == .active { reload() } }
    }

    private func reload() { sessions = Store.sessions() }
}

/// The system button that opens the broadcast sheet with this app's extension chosen.
struct BroadcastButton: UIViewRepresentable {
    func makeUIView(context: Context) -> RPSystemBroadcastPickerView {
        let picker = RPSystemBroadcastPickerView(frame: CGRect(x: 0, y: 0, width: 56, height: 56))
        picker.preferredExtension = (Bundle.main.bundleIdentifier ?? "") + ".broadcast"
        picker.showsMicrophoneButton = true
        return picker
    }

    func updateUIView(_ view: RPSystemBroadcastPickerView, context: Context) {}
}

struct SessionView: View {
    let dir: URL
    @State private var summary: SessionSummary?
    @State private var player: AVAudioPlayer?
    @State private var playing: String?
    @State private var error: String?

    var body: some View {
        List {
            if let summary {
                Section("Broadcast") {
                    row("Length", summary.finished.map { String(format: "%.0f s", $0.timeIntervalSince(summary.started)) }
                        ?? "not finished (extension stopped or killed)")
                    row("Screen frames", "\(summary.videoFrames) received, \(summary.savedFrames) saved")
                }
                ForEach(summary.tracks, id: \.name) { track in
                    Section(track.name == "app" ? "App audio (the other side)" : "Microphone") {
                        row("Format", track.formats.joined(separator: " → "))
                        row("Length", String(format: "%.1f s in %d buffers", track.seconds, track.buffers))
                        row("Gaps", track.gaps == 0 ? "none" : String(format: "%d, %.1f s in all", track.gaps, track.gapSeconds))
                        row("Loudest second", track.loudest.map { "\($0) dBFS" } ?? "—")
                        row("Silent seconds", "\(track.silentSeconds) of \(track.levels.count) (below -60 dBFS)")
                        Text(sparkline(track.levels)).font(.system(.caption, design: .monospaced)).lineLimit(nil)
                        ForEach(track.segments, id: \.self) { file in
                            Button(playing == file ? "■ Stop \(file)" : "▶︎ Play \(file)") { toggle(file) }
                        }
                    }
                }
                if summary.tracks.isEmpty {
                    Text("No audio arrived at all.").foregroundStyle(.red)
                }
                Section("Events") {
                    ForEach(summary.events, id: \.self) { Text($0).font(.caption.monospaced()) }
                }
            } else {
                Text("No summary.json in this recording.").foregroundStyle(.secondary)
            }
            if let error { Text(error).foregroundStyle(.red) }
        }
        .navigationTitle(dir.lastPathComponent)
        .toolbar {
            ShareLink(items: files()) { Label("Export", systemImage: "square.and.arrow.up") }
        }
        .onAppear { load() }
        .onDisappear { player?.stop() }
    }

    private func row(_ title: String, _ value: String) -> some View {
        LabeledContent(title, value: value)
    }

    /// One character per second: how loud it was.
    private func sparkline(_ levels: [Int]) -> String {
        let marks = Array("▁▂▃▄▅▆▇█")
        return String(levels.map { db in
            db <= -60 ? "·" : marks[min(marks.count - 1, max(0, (db + 60) * marks.count / 60))]
        })
    }

    private func load() {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        summary = (try? Data(contentsOf: dir.appendingPathComponent(Store.summaryFile)))
            .flatMap { try? decoder.decode(SessionSummary.self, from: $0) }
    }

    /// The audio, summary and log; the screenshots stay on the iPad (there can be thousands).
    private func files() -> [URL] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return names.sorted().filter { $0 != "frames" }.map { dir.appendingPathComponent($0) }
    }

    private func toggle(_ file: String) {
        if playing == file {
            player?.stop()
            playing = nil
            return
        }
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback)
            try AVAudioSession.sharedInstance().setActive(true)
            let next = try AVAudioPlayer(contentsOf: dir.appendingPathComponent(file))
            next.play()
            player = next
            playing = file
            error = nil
        } catch {
            self.error = "\(file): \(error.localizedDescription)"
        }
    }
}
