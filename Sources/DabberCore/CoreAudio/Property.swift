import CoreAudio

public struct CAError: Error, CustomStringConvertible {
    public let status: OSStatus
    public let op: String
    public var description: String { "\(op) failed: \(fourCC(status))" }
}

public func fourCC(_ value: OSStatus) -> String {
    let n = UInt32(bitPattern: value)
    let bytes = [24, 16, 8, 0].map { UInt8((n >> $0) & 0xFF) }
    guard bytes.allSatisfy({ $0 >= 32 && $0 < 127 }) else { return String(value) }
    return String(decoding: bytes, as: UTF8.self)
}

public func fourCC(_ selector: UInt32) -> String { fourCC(OSStatus(bitPattern: selector)) }

func check(_ status: OSStatus, _ op: String) throws {
    if status != noErr { throw CAError(status: status, op: op) }
}

public func address(
    _ selector: AudioObjectPropertySelector,
    scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
    element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain
) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
}

public func getValue<T: BitwiseCopyable>(_ object: AudioObjectID, _ addr: AudioObjectPropertyAddress, default initial: T) throws -> T {
    var a = addr
    var size = UInt32(MemoryLayout<T>.size)
    var value = initial
    try check(AudioObjectGetPropertyData(object, &a, 0, nil, &size, &value), "get \(fourCC(addr.mSelector))")
    return value
}

public func getArray<T: BitwiseCopyable>(_ object: AudioObjectID, _ addr: AudioObjectPropertyAddress, filler: T) throws -> [T] {
    var a = addr
    var size: UInt32 = 0
    try check(AudioObjectGetPropertyDataSize(object, &a, 0, nil, &size), "size \(fourCC(addr.mSelector))")
    var values = [T](repeating: filler, count: Int(size) / MemoryLayout<T>.stride)
    try check(AudioObjectGetPropertyData(object, &a, 0, nil, &size, &values), "get \(fourCC(addr.mSelector))")
    values.removeSubrange((Int(size) / MemoryLayout<T>.stride)...)
    return values
}

public func getString(_ object: AudioObjectID, _ addr: AudioObjectPropertyAddress) throws -> String {
    var a = addr
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    var value: Unmanaged<CFString>?
    try check(AudioObjectGetPropertyData(object, &a, 0, nil, &size, &value), "get \(fourCC(addr.mSelector))")
    return value.map { $0.takeRetainedValue() as String } ?? ""
}
