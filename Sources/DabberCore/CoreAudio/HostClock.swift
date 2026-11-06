#if os(macOS)
import CoreAudio

public enum HostClock {
    public static func nowNanos() -> UInt64 { AudioConvertHostTimeToNanos(AudioGetCurrentHostTime()) }
    public static func nanos(hostTime: UInt64) -> UInt64 { AudioConvertHostTimeToNanos(hostTime) }
}
#else
import Darwin

/// The same clock as on the Mac: mach absolute time, which is also the host time clock of Core Media timestamps.
public enum HostClock {
    private static let timebase: (numer: UInt64, denom: UInt64) = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return (UInt64(info.numer), UInt64(max(info.denom, 1)))
    }()

    public static func nowNanos() -> UInt64 { nanos(hostTime: mach_absolute_time()) }

    public static func nanos(hostTime: UInt64) -> UInt64 {
        let (numer, denom) = timebase
        return hostTime / denom * numer + hostTime % denom * numer / denom
    }
}
#endif
