import Testing
import CoreAudio
@testable import DabberCore

struct Boom: Error {}

@Test func deviceFailingMidReadIsSkipped() {
    let ids: [AudioObjectID] = [1, 2, 3]
    let devices = collectInputDevices(ids: ids) { id in
        if id == 2 { throw Boom() }
        if id == 3 { return nil }
        return InputDevice(id: id, uid: "u\(id)", name: "n\(id)")
    }
    #expect(devices == [InputDevice(id: 1, uid: "u1", name: "n1")])
}

@Test func dabbersOwnAggregatesAreSkipped() {
    let uids: [AudioObjectID: String] = [1: "mic", 2: "local.dabber.feed.x", 3: "local.dabber.tap.y"]
    let devices = collectInputDevices(ids: [1, 2, 3]) { id in InputDevice(id: id, uid: uids[id]!, name: "n\(id)") }
    #expect(devices.map(\.uid) == ["mic"])
}
