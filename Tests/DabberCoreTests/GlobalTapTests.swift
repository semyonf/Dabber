import CoreAudio
import Testing
@testable import DabberCore

@Test func tapWithoutBundleIDsExcludesOnlyProcesses() {
    let d = GlobalTap.description(excludingProcesses: [42], bundleIDs: [])
    #expect(d.isExclusive)
    #expect(d.processes == [42])
    #expect(d.bundleIDs.isEmpty)
}

@Test func tapExcludesBundleIDsWithProcessRestore() {
    let d = GlobalTap.description(excludingProcesses: [42], bundleIDs: ["com.apple.Safari", "com.apple.WebKit.GPU"])
    #expect(d.isExclusive)
    #expect(d.processes == [42])
    #expect(d.bundleIDs == ["com.apple.Safari", "com.apple.WebKit.GPU"])
    #expect(d.isProcessRestoreEnabled)
}

@Test func audioProcessesIncludeThisProcess() throws {
    #expect(try audioProcesses().contains { $0.pid == getpid() })
}
