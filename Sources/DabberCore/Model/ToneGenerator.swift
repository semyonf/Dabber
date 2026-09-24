import Foundation

public struct ToneGenerator: Sendable {
    public let frequency: Double
    public let amplitude: Float
    private let step: Double
    private var phase = 0.0

    public init(frequency: Double, amplitude: Float, rate: Double = Double(Timeline.rate)) {
        self.frequency = frequency
        self.amplitude = amplitude
        step = 2 * Double.pi * frequency / rate
    }

    public mutating func fill(_ out: UnsafeMutableBufferPointer<Float>, channels: Int) {
        for frame in 0..<(out.count / channels) {
            let sample = amplitude * Float(sin(phase))
            for c in 0..<channels { out[frame * channels + c] = sample }
            phase += step
            if phase >= 2 * Double.pi { phase -= 2 * Double.pi }
        }
    }
}
