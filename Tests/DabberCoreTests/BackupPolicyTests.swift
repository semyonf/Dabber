import Testing
@testable import DabberCore

@Test func aLostOrFailedMicTurnsTheBackupOn() {
    #expect(BackupPolicy.active([.running, .waitingForDevice], was: false))
    #expect(BackupPolicy.active([.failed("x")], was: false))
    #expect(BackupPolicy.active([.restarting("nsrt"), .waitingForDevice], was: false))
}

@Test func runningMicsTurnTheBackupOff() {
    #expect(!BackupPolicy.active([.running, .running], was: true))
    #expect(!BackupPolicy.active([], was: true))
}

@Test func restartingOrStoppedMicsKeepTheBackupAsItIs() {
    #expect(!BackupPolicy.active([.restarting("nsrt"), .running], was: false))
    #expect(BackupPolicy.active([.restarting("nsrt"), .running], was: true))
    #expect(BackupPolicy.active([.stopped], was: true))
    #expect(!BackupPolicy.active([.stopped], was: false))
}
