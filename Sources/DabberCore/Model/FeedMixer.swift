public enum FeedMixer {
    public static func add(
        _ input: UnsafeBufferPointer<Float>, channels: Int, gain: Float, into out: UnsafeMutableBufferPointer<Float>
    ) {
        let frames = min(out.count / 2, input.count / channels)
        for f in 0..<frames {
            let left = gain * finite(input[f * channels])
            out[2 * f] += left
            out[2 * f + 1] += channels == 2 ? gain * finite(input[f * 2 + 1]) : left
        }
    }

    private static func finite(_ x: Float) -> Float { x.isFinite ? x : 0 }

    public static func clamp(_ out: UnsafeMutableBufferPointer<Float>) {
        for i in out.indices { out[i] = min(1, max(-1, out[i])) }
    }
}
