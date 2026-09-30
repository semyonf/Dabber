import Testing
@testable import DabberCore

@Test func aLostOrFailedMicTurnsTheBackupOn() {
    #expect(BackupPolicy.active([.running, .waitingForDevice], was: false, calmFor: 0))
    #expect(BackupPolicy.active([.failed("x")], was: false, calmFor: 0))
    #expect(BackupPolicy.active([.restarting("nsrt"), .waitingForDevice], was: false, calmFor: 0))
}

@Test func micsRunningForAWhileTurnTheBackupOff() {
    #expect(!BackupPolicy.active([.running, .running], was: true, calmFor: 2.5))
    #expect(!BackupPolicy.active([], was: true, calmFor: 2.5))
    #expect(!BackupPolicy.active([.running], was: false, calmFor: 0))
}

@Test func micsThatJustCameBackKeepTheBackupOn() {
    #expect(BackupPolicy.active([.running, .running], was: true, calmFor: 0))
    #expect(BackupPolicy.active([.running], was: true, calmFor: 2.4))
}

@Test func restartingOrStoppedMicsKeepTheBackupAsItIs() {
    #expect(!BackupPolicy.active([.restarting("nsrt"), .running], was: false, calmFor: 0))
    #expect(BackupPolicy.active([.restarting("nsrt"), .running], was: true, calmFor: 0))
    #expect(BackupPolicy.active([.stopped], was: true, calmFor: 0))
    #expect(!BackupPolicy.active([.stopped], was: false, calmFor: 0))
}
