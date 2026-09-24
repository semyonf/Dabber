import Testing
@testable import DabberCore

@Test func stateMachineFollowsIdleRecordingStopping() {
    var m = SessionState()
    #expect(m.phase == .idle)
    #expect(m.start() == true)
    #expect(m.start() == false)
    #expect(m.phase == .recording)
    #expect(m.stop() == true)
    #expect(m.stop() == false)
    #expect(m.phase == .stopping)
    m.finished()
    #expect(m.phase == .idle)
    #expect(m.stop() == false)
}

@Test func silenceWarningNeedsTenSecondsOfQuietMicWithComputerSignal() {
    var r = SilenceRule()
    #expect(r.update(micDb: -70, computerDb: -20, now: 0) == false)
    #expect(r.update(micDb: -70, computerDb: -20, now: 9.9) == false)
    #expect(r.update(micDb: -70, computerDb: -20, now: 10) == true)
    #expect(r.update(micDb: -30, computerDb: -20, now: 11) == false)
    #expect(r.update(micDb: -70, computerDb: -20, now: 12) == false)
}

@Test func quietComputerAudioResetsTheSilenceWindow() {
    var r = SilenceRule()
    _ = r.update(micDb: -70, computerDb: -20, now: 0)
    #expect(r.update(micDb: -70, computerDb: -80, now: 5) == false)
    #expect(r.update(micDb: -70, computerDb: -20, now: 14) == false)
    #expect(r.update(micDb: -70, computerDb: -20, now: 24) == true)
}
