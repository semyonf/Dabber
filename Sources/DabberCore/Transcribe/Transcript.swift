import Foundation

public struct SpokenWord: Equatable, Sendable {
    public let startMillis: Int
    public let endMillis: Int
    public let text: String
    public let confidence: Double

    public init(startMillis: Int, endMillis: Int, text: String, confidence: Double = 1) {
        self.startMillis = startMillis
        self.endMillis = endMillis
        self.text = text
        self.confidence = confidence
    }
}

/// Turns one audio file into timed words. Blocking: Finalizer runs in a detached task, off the main thread.
public typealias SpeechToText = @Sendable (URL) throws -> [SpokenWord]

public struct TranscriptLine: Equatable, Sendable {
    public let startMillis: Int
    public let endMillis: Int
    public let speaker: String
    public let text: String

    public init(startMillis: Int, endMillis: Int, speaker: String, text: String) {
        self.startMillis = startMillis
        self.endMillis = endMillis
        self.speaker = speaker
        self.text = text
    }
}

public enum Transcript {
    public static let me = "Я"
    public static let others = "Собеседники"
    static let textFile = "transcript.txt"
    static let srtFile = "transcript.srt"
    static let pauseMillis = 1_000
    static let maxChars = 84
    static let minSentenceMillis = 1_000
    /// A line whose mean word confidence is lower is dropped: on near-silence the model invents phrases at 0.5-0.56
    /// (measured in docs/superpowers/plans/2026-10-04-dabber-parakeet-subtitles.md, Task 6b). It was 0.7 until a real
    /// two-word reply («так попробуем.») scored 0.67; on two meeting mixes only 2 of 465 lines fall below 0.6.
    static let minConfidence = 0.6

    public static func lines(_ words: [SpokenWord], speaker: String) -> [TranscriptLine] {
        var out: [TranscriptLine] = []
        var current: TranscriptLine?
        var sum = 0.0
        var count = 0
        func emit(_ line: TranscriptLine) {
            if sum / Double(count) >= minConfidence { out.append(line) }
        }
        for w in words {
            let word = w.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !word.isEmpty else { continue }
            if let c = current, w.startMillis - c.endMillis < pauseMillis, c.text.count + 1 + word.count <= maxChars {
                current = TranscriptLine(startMillis: c.startMillis, endMillis: max(c.endMillis, w.endMillis), speaker: speaker, text: c.text + " " + word)
                sum += w.confidence
                count += 1
            } else {
                if let c = current { emit(c) }
                current = TranscriptLine(startMillis: w.startMillis, endMillis: max(w.endMillis, w.startMillis + 1), speaker: speaker, text: word)
                sum = w.confidence
                count = 1
            }
            if let c = current, c.endMillis - c.startMillis >= minSentenceMillis, let last = word.last, ".?!".contains(last) {
                emit(c)
                current = nil
            }
        }
        if let c = current { emit(c) }
        return out
    }

    static func merge(_ tracks: [[TranscriptLine]]) -> [TranscriptLine] {
        let all = tracks.flatMap { $0 }
        return all.indices.sorted { (all[$0].startMillis, $0) < (all[$1].startMillis, $1) }.map { all[$0] }
    }

    static func text(_ lines: [TranscriptLine], marks: [Mark]) -> String {
        var pending = Chapters.marks(marks, durationMillis: Int.max)[...]
        var out = ""
        for line in lines {
            while let mark = pending.first, mark.startMillis <= line.startMillis {
                out += "— \(mark.title) —\n"
                pending.removeFirst()
            }
            out += "[\(clock(line.startMillis))] \(line.speaker): \(line.text)\n"
        }
        for mark in pending { out += "— \(mark.title) —\n" }
        return out
    }

    static func srt(_ lines: [TranscriptLine]) -> String {
        lines.enumerated().map { i, line in
            "\(i + 1)\n\(timecode(line.startMillis)) --> \(timecode(line.endMillis))\n\(line.speaker): \(line.text)\n\n"
        }.joined()
    }

    private static func clock(_ millis: Int) -> String {
        let s = millis / 1000
        return String(format: "%02d:%02d:%02d", s / 3600, s % 3600 / 60, s % 60)
    }

    private static func timecode(_ millis: Int) -> String {
        clock(millis) + String(format: ",%03d", millis % 1000)
    }
}
