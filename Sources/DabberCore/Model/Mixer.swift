public enum Mixer {
    public static func mixToStereo(mono: [[Float]], stereo: [[Float]], backup: [[Float]] = []) -> [Float] {
        let frames = max((mono + backup).map(\.count).max() ?? 0, stereo.map { $0.count / 2 }.max() ?? 0)
        var out = [Float](repeating: 0, count: frames * 2)
        let gain = 1 / Float(max(1, mono.count + stereo.count))
        for track in mono + backup {
            for (i, s) in track.enumerated() {
                out[2 * i] += gain * s
                out[2 * i + 1] += gain * s
            }
        }
        for track in stereo {
            for (i, s) in track.prefix(track.count / 2 * 2).enumerated() { out[i] += gain * s }
        }
        for i in out.indices { out[i] = min(1, max(-1, out[i])) }
        return out
    }
}
