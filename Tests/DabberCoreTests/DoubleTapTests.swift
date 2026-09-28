import Testing
@testable import DabberCore

private func run(_ events: [(DoubleTap.Key, Double)]) -> [Bool] {
    var tap = DoubleTap()
    return events.map { tap.handle($0.0, at: $0.1) }
}

@Test func twoQuickTapsFireOnTheSecondRelease() {
    #expect(run([(.down, 0), (.up, 0.08), (.down, 0.2), (.up, 0.28)]) == [false, false, false, true])
}

@Test func slowTapsAndLongPressesDoNotFire() {
    #expect(run([(.down, 0), (.up, 0.08), (.down, 0.5), (.up, 0.58)]).allSatisfy { !$0 })
    #expect(run([(.down, 0), (.up, 0.5), (.down, 0.6), (.up, 0.7)]).allSatisfy { !$0 })
}

@Test func anotherKeyInBetweenCancels() {
    #expect(run([(.down, 0), (.up, 0.08), (.other, 0.1), (.down, 0.2), (.up, 0.28)]).allSatisfy { !$0 })
    #expect(run([(.down, 0), (.other, 0.05), (.up, 0.08), (.down, 0.2), (.up, 0.28)]).allSatisfy { !$0 })
}

@Test func threeTapsFireOnceAndFourFireTwice() {
    let taps = (0..<4).flatMap { i in [(DoubleTap.Key.down, Double(i) * 0.2), (.up, Double(i) * 0.2 + 0.08)] }
    #expect(run(Array(taps.prefix(6))).filter { $0 }.count == 1)
    #expect(run(taps).filter { $0 }.count == 2)
}
