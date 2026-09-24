import CoreAudio
import Foundation

public final class PropertyWatcher: @unchecked Sendable {
    public typealias Handler = @Sendable (AudioObjectID, AudioObjectPropertySelector) -> Void

    private var registrations: [(AudioObjectID, AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []
    private let queue = DispatchQueue(label: "dabber.listeners")

    public init(objects: [(AudioObjectID, [AudioObjectPropertySelector])], handler: @escaping Handler) throws {
        for (object, selectors) in objects {
            for selector in selectors {
                let block: AudioObjectPropertyListenerBlock = { count, addresses in
                    for i in 0..<Int(count) { handler(object, addresses[i].mSelector) }
                }
                var addr = address(selector)
                let status = AudioObjectAddPropertyListenerBlock(object, &addr, queue, block)
                if status != noErr {
                    remove()
                    throw CAError(status: status, op: "add listener \(fourCC(selector)) on \(object)")
                }
                registrations.append((object, addr, block))
            }
        }
    }

    public func remove() {
        for (object, addr, block) in registrations {
            var a = addr
            AudioObjectRemovePropertyListenerBlock(object, &a, queue, block)
        }
        registrations.removeAll()
    }
}
