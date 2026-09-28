import CoreAudio
import Foundation
import DabberCore

enum Headless {
    static func run(_ raw: [String]) -> Int32 {
        var args = raw
        var log = Log(path: nil)
        if let i = args.firstIndex(of: "--log"), i + 1 < args.count {
            log = Log(path: args[i + 1])
            args.removeSubrange(i...(i + 1))
        }
        let code: Int32
        do {
            code = try dispatch(args, log)
        } catch {
            log.line("ERROR \(error)")
            code = 1
        }
        log.line("EXIT \(code)")
        return code
    }

    static func dispatch(_ args: [String], _ log: Log) throws -> Int32 {
        switch args.first {
        case "--list-inputs":
            for d in try inputDevices() { log.line("\(d.uid)\t\(d.name)") }
            return 0
        case "--list-audio-processes":
            for p in try audioProcesses() {
                log.line("\(p.pid)\t\(p.isRunningOutput ? "OUT" : "-")\t\(p.bundleID)")
            }
            return 0
        case "--play-tone":
            guard args.count == 4, let seconds = Double(args[2]), let delay = Double(args[3]) else { return 64 }
            let device = args[1] == "default"
                ? try getValue(systemObject, address(kAudioHardwarePropertyDefaultOutputDevice), default: AudioObjectID(0))
                : try deviceID(uid: args[1])
            guard device != kAudioObjectUnknown else {
                log.line("no device with uid \(args[1])")
                return 2
            }
            let streams = try getArray(
                device, address(kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeOutput),
                filler: AudioObjectID(0))
            guard let stream = streams.first else {
                log.line("device has no output stream")
                return 2
            }
            let f = try getValue(stream, address(kAudioStreamPropertyVirtualFormat), default: AudioStreamBasicDescription())
            log.line("output format: \(f.mSampleRate) Hz \(f.mChannelsPerFrame) ch flags \(f.mFormatFlags)")
            let bufferFrames = try getValue(device, address(kAudioDevicePropertyBufferFrameSize), default: UInt32(0))
            log.line("buffer frames: \(bufferFrames)")
            let player = TonePlayer(
                tone: ToneGenerator(frequency: 440, amplitude: 0.25),
                startNanos: HostClock.nowNanos() + UInt64(delay * 1e9))
            let runner = try OutputIOProcRunner(device: device) { list, time in player.render(list, time) }
            Thread.sleep(forTimeInterval: seconds)
            runner.stop()
            log.line("TONE_START_NANOS \(player.toneStartNanos)")
            log.line(
                "rendered frames=\(player.framesRendered) discontinuities=\(player.discontinuities) "
                    + "unexpectedLayouts=\(player.unexpectedLayouts)")
            return 0
        case "--feed-probe":
            guard args.count == 3, let seconds = Double(args[2]) else { return 64 }
            let micUID = args[1] == "none" ? nil : args[1]
            let micBefore = try micUID.map { try nominalRate(deviceID(uid: $0)) }
            let aggregate = try FeedAggregate(micUID: micUID, tapExcluding: [])
            defer { aggregate.destroy() }
            let id = aggregate.aggregateID
            log.line("aggregate rate=\(try nominalRate(id)) buffer=\(try getValue(id, address(kAudioDevicePropertyBufferFrameSize), default: UInt32(0)))")
            log.line("aggregate inputs: \(streamFormats(id, kAudioObjectPropertyScopeInput))")
            log.line("aggregate outputs: \(streamFormats(id, kAudioObjectPropertyScopeOutput))")
            let probe = LayoutProbe()
            let runner = try DuplexIOProcRunner(device: id) { input, output, _ in probe.handle(input, output) }
            Thread.sleep(forTimeInterval: seconds)
            runner.stop()
            log.line("first cycle: \(probe.firstLayout)")
            log.line("cycles=\(probe.cycles) input dB: " + probe.decibels.map { String(format: "%.1f", $0) }.joined(separator: " "))
            if let micUID {
                log.line("mic rate before=\(micBefore ?? 0) after=\(try nominalRate(deviceID(uid: micUID)))")
            }
            return 0
        case "--scan-input":
            guard args.count == 3 || args.count == 4, let seconds = Double(args[2]) else { return 64 }
            let device = try deviceID(uid: args[1])
            guard device != kAudioObjectUnknown else {
                log.line("no device with uid \(args[1])")
                return 2
            }
            if args.count == 4 {
                guard var frames = UInt32(args[3]) else { return 64 }
                var a = address(kAudioDevicePropertyBufferFrameSize)
                let status = AudioObjectSetPropertyData(device, &a, 0, nil, UInt32(MemoryLayout<UInt32>.size), &frames)
                guard status == noErr else {
                    log.line("set buffer frame size failed: \(fourCC(status))")
                    return 1
                }
            }
            log.line("buffer frames: \(try getValue(device, address(kAudioDevicePropertyBufferFrameSize), default: UInt32(0)))")
            let probe = InputScan()
            let runner = try IOProcRunner(device: device) { list, time in probe.handle(list, time) }
            Thread.sleep(forTimeInterval: seconds)
            runner.stop()
            probe.scanner.finish()
            let s = probe.scanner
            log.line("SCAN_START_NANOS \(probe.firstNanos)")
            log.line(
                "SCAN frames=\(s.framesScanned) firstSignal=\(s.firstSignalFrame.map(String.init) ?? "none") "
                    + "zeroRuns=\(s.runCount) longest=\(s.longest) discontinuities=\(probe.discontinuities) "
                    + "unexpectedLayouts=\(probe.unexpectedLayouts)")
            for run in s.runs {
                log.line(String(format: "ZERO_RUN at=%.4f frames=%d", Double(run.startFrame) / 48_000, run.frames))
            }
            return 0
        case "--feed":
            var micUID: String?
            var computer = false
            var excluded: [String] = []
            var seconds = 0.0
            var i = 1
            while i < args.count {
                switch args[i] {
                case "--computer-audio":
                    computer = true
                case "--mic":
                    i += 1
                    guard i < args.count else { return 64 }
                    micUID = args[i]
                case "--exclude-bundle":
                    i += 1
                    guard i < args.count else { return 64 }
                    excluded.append(args[i])
                case "--seconds":
                    i += 1
                    guard i < args.count, let s = Double(args[i]) else { return 64 }
                    seconds = s
                default:
                    log.line("unknown option \(args[i])")
                    return 64
                }
                i += 1
            }
            guard seconds > 0 else { return 64 }
            let config = FeedConfig(
                micUID: micUID, computerAudio: computer,
                tapBundleIDs: ExclusionList.tapBundleIDs(apps: excluded, own: Bundle.main.bundleIdentifier))
            log.line("FEED config mic=\(micUID ?? "none") computer=\(computer) tap excludes \(config.tapBundleIDs)")
            var hooks = FeedHooks.live
            hooks.inUse = { _ in true }
            let engine = FeedEngine(hooks: hooks)
            engine.applyAndWait(config)
            log.line("FEED_START_NANOS \(HostClock.nowNanos())")
            var lastNotRunning = engine.status
            for t in 1...max(1, Int(seconds)) {
                Thread.sleep(forTimeInterval: 1)
                let status = engine.status
                if status != .running { lastNotRunning = status }
                log.line("t=\(t) \(status) \(String(format: "%.1f", engine.levelDb)) dB")
            }
            if let r = engine.renderer {
                log.line(
                    "FEED cycles=\(r.cycles) frames=\(r.framesRendered) discontinuities=\(r.discontinuities) "
                        + "unexpectedLayouts=\(r.unexpectedLayouts) skippedInputs=\(r.skippedInputs)")
            }
            engine.applyAndWait(nil)
            switch lastNotRunning {
            case .running, .micMissing: return 0
            case .driverMissing:
                log.line("driver missing: no device with uid \(FeedDevices.feedUID)")
                return 2
            default: return 1
            }
        case "--record":
            var specs: [SourceSpec] = []
            var excluded: [String] = []
            var seconds = 0.0
            var marks: [(at: Double, text: String)] = []
            var title: String?
            var slides = false
            var output = AppPaths.recordingsRoot
            var work = AppPaths.workRoot
            var i = 1
            let devices = try inputDevices()
            while i < args.count {
                switch args[i] {
                case "--computer-audio":
                    specs.append(SourceSpec(kind: .computer, uid: nil, name: "Computer audio"))
                case "--mic":
                    i += 1
                    guard i < args.count else { return 64 }
                    let uid = args[i]
                    guard let device = devices.first(where: { $0.uid == uid }) else {
                        log.line("no device with uid \(uid)")
                        return 2
                    }
                    specs.append(SourceSpec(kind: .mic, uid: uid, name: device.name))
                case "--exclude-bundle":
                    i += 1
                    guard i < args.count else { return 64 }
                    excluded.append(args[i])
                case "--seconds":
                    i += 1
                    guard i < args.count, let s = Double(args[i]) else { return 64 }
                    seconds = s
                case "--out":
                    i += 1
                    guard i < args.count else { return 64 }
                    output = URL(fileURLWithPath: args[i])
                case "--work":
                    i += 1
                    guard i < args.count else { return 64 }
                    work = URL(fileURLWithPath: args[i])
                case "--mark-at":
                    i += 1
                    guard i < args.count else { return 64 }
                    let parts = args[i].split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
                    guard let at = Double(parts[0]) else { return 64 }
                    marks.append((at, parts.count > 1 ? String(parts[1]) : ""))
                case "--slides":
                    slides = true
                case "--title":
                    i += 1
                    guard i < args.count else { return 64 }
                    title = args[i]
                default:
                    log.line("unknown option \(args[i])")
                    return 64
                }
                i += 1
            }
            guard !specs.isEmpty, seconds > 0 else { return 64 }
            specs = specs.map { s in
                s.kind == .computer
                    ? SourceSpec(kind: s.kind, uid: s.uid, name: s.name, excludedBundleIDs: excluded) : s
            }
            let recorder = SessionRecorder(root: work, appVersion: AppPaths.version)
            let dir = try recorder.start(specs: specs, slides: slides)
            log.line("SESSION \(dir.path)")
            let grabber = SlideRecorder(grabber: LiveScreenGrabber())
            if slides { grabber.start { try recorder.addFrame(atNanos: $0, data: $1) } }
            if let title {
                recorder.setTitle(title)
                log.line("TITLE \(title)")
            }
            var pending = marks.sorted { $0.at < $1.at }
            let end = Date().addingTimeInterval(seconds)
            while Date() < end {
                Thread.sleep(forTimeInterval: 1)
                let status = recorder.status()
                let parts = status.sources.map { s in
                    "\(s.spec.name): \(s.status) \(String(format: "%.1f", s.levelDb)) dB" + (s.silent ? " SILENT" : "")
                }
                log.line("t=\(Int(status.elapsedSeconds)) \(status.phase) | " + parts.joined(separator: " | ")
                    + (slides ? " | screen: \(grabber.status.map { "\($0)" } ?? "off")" : ""))
                if status.phase != .recording {
                    log.line("ERROR recording stopped: \(status.lastError ?? "unknown")")
                    break
                }
                while let mark = pending.first, status.elapsedSeconds >= mark.at {
                    pending.removeFirst()
                    let id = recorder.addMark(atNanos: HostClock.nowNanos()).last?.id ?? 0
                    if let m = recorder.setMarkText(id: id, mark.text).last {
                        log.line("MARK \(m.id) at=\(m.offsetNanos / 1_000_000) ms \(m.text)")
                    }
                }
            }
            grabber.stop()
            guard let stopped = recorder.stop() ?? recorder.lastSessionDir else { return 1 }
            log.line("STOPPED \(stopped.path)")
            if slides {
                let frames = (try? SessionManifest.load(from: stopped))?.frames ?? []
                let bytes = frames.compactMap { try? FileManager.default.attributesOfItem(atPath: stopped.appendingPathComponent($0.file).path)[.size] as? Int }
                log.line("FRAMES \(frames.count) bytes=\(bytes.reduce(0, +))")
            }
            let report = try Finalizer.run(stopped)
            log.line("FINALIZED total=\(report.totalFrames) gaps=\(report.gaps.count) resampled=\(report.resampled.count)"
                + (report.slidesError.map { " slidesError=\($0)" } ?? ""))
            let named = try Finalizer.rename(stopped)
            log.line("NAMED \(named.path)")
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            log.line("DELIVERED \(try Delivery.deliver(named, into: output).path)")
            return 0
        default:
            log.line("unknown command: \(args.joined(separator: " "))")
            return 64
        }
    }
}

final class Log: Sendable {
    private let handle: FileHandle
    private let lock = NSLock()

    init(path: String?) {
        if let path {
            FileManager.default.createFile(atPath: path, contents: nil)
            handle = FileHandle(forWritingAtPath: path) ?? .standardError
        } else {
            handle = .standardOutput
        }
    }

    func line(_ s: String) {
        lock.lock(); defer { lock.unlock() }
        handle.write((String(format: "%.3f ", Date().timeIntervalSince1970) + s + "\n").data(using: .utf8)!)
    }
}

func nominalRate(_ device: AudioObjectID) throws -> Double {
    try getValue(device, address(kAudioDevicePropertyNominalSampleRate), default: 0.0)
}

func streamFormats(_ device: AudioObjectID, _ scope: AudioObjectPropertyScope) -> String {
    let streams = (try? getArray(device, address(kAudioDevicePropertyStreams, scope: scope), filler: AudioObjectID(0))) ?? []
    return streams.map { stream in
        let f = (try? getValue(stream, address(kAudioStreamPropertyVirtualFormat), default: AudioStreamBasicDescription()))
            ?? AudioStreamBasicDescription()
        return "\(f.mSampleRate)Hz/\(f.mChannelsPerFrame)ch/flags\(f.mFormatFlags)"
    }.joined(separator: " ")
}

final class LayoutProbe: @unchecked Sendable {
    var cycles = 0
    var firstLayout = ""
    private var sums = [Double](repeating: 0, count: 8)
    private var counts = [Int](repeating: 0, count: 8)
    private var inputs = 0

    var decibels: [Double] {
        (0..<inputs).map { i in counts[i] > 0 && sums[i] > 0 ? 10 * log10(sums[i] / Double(counts[i])) : -160 }
    }

    func handle(_ input: UnsafePointer<AudioBufferList>, _ output: UnsafeMutablePointer<AudioBufferList>) {
        let ins = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        let outs = UnsafeMutableAudioBufferListPointer(output)
        if cycles == 0 {
            inputs = min(ins.count, 8)
            firstLayout = "in " + ins.map { "\($0.mNumberChannels)ch/\($0.mDataByteSize)B" }.joined(separator: " ")
                + " | out " + outs.map { "\($0.mNumberChannels)ch/\($0.mDataByteSize)B" }.joined(separator: " ")
        }
        cycles += 1
        for (i, b) in ins.enumerated() where i < inputs {
            guard let d = b.mData?.assumingMemoryBound(to: Float.self) else { continue }
            let n = Int(b.mDataByteSize) / MemoryLayout<Float>.size
            for k in 0..<n { sums[i] += Double(d[k] * d[k]) }
            counts[i] += n
        }
        for b in outs { if let d = b.mData { memset(d, 0, Int(b.mDataByteSize)) } }
    }
}

final class InputScan: @unchecked Sendable {
    var scanner = ZeroRunScanner(minFrames: 16)
    var firstNanos: UInt64 = 0
    var discontinuities = 0
    var unexpectedLayouts = 0
    private var nextSampleTime = -1.0

    func handle(_ list: UnsafePointer<AudioBufferList>, _ time: UnsafePointer<AudioTimeStamp>) {
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: list))
        guard buffers.count == 1, let data = buffers[0].mData, buffers[0].mNumberChannels > 0 else {
            unexpectedLayouts += 1
            return
        }
        let channels = Int(buffers[0].mNumberChannels)
        let count = Int(buffers[0].mDataByteSize) / MemoryLayout<Float>.size
        let t = time.pointee
        if firstNanos == 0 { firstNanos = HostClock.nanos(hostTime: t.mHostTime) }
        if nextSampleTime >= 0, t.mSampleTime != nextSampleTime { discontinuities += 1 }
        nextSampleTime = t.mSampleTime + Double(count / channels)
        scanner.scan(UnsafeBufferPointer(start: data.assumingMemoryBound(to: Float.self), count: count), channels: channels)
    }
}
