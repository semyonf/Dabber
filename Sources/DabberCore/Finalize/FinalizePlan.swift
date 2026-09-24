public struct FinalizePlan: Equatable, Sendable {
    public static let resampleThresholdMillis: Double = 50

    public let file: String
    public let segment: Segment
    public let resample: Bool
    public let driftMillis: Double

    public static func make(_ records: [SegmentRecord], fileFrames: [Int]) -> [FinalizePlan] {
        zip(records, fileFrames).compactMap { record, frames in
            guard record.startNanos > 0, frames > 0 else { return nil }
            let measured = Segment(startNanos: record.startNanos, frames: frames, endNanos: record.endNanos)
            let drift = Timeline.driftMillis(measured)
            guard abs(drift) > resampleThresholdMillis, let end = record.endNanos else {
                return FinalizePlan(file: record.file, segment: measured, resample: false, driftMillis: drift)
            }
            let expected = Timeline.frames(nanos: Int64(end) - Int64(record.startNanos))
            return FinalizePlan(
                file: record.file, segment: Segment(startNanos: record.startNanos, frames: expected, endNanos: end),
                resample: true, driftMillis: drift)
        }
    }
}
