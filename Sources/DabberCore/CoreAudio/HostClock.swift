import CoreAudio

public enum HostClock {
    public static func nowNanos() -> UInt64 { AudioConvertHostTimeToNanos(AudioGetCurrentHostTime()) }
    public static func nanos(hostTime: UInt64) -> UInt64 { AudioConvertHostTimeToNanos(hostTime) }
}
