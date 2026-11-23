import Testing
import BackMeUpCore

@Suite("Parsing tmutil status -X")
struct StatusParserTests {
    @Test func idleMac() throws {
        #expect(TimeMachineStatus(statusOutput: try fixture("status-idle.plist")) == .idle)
    }

    @Test(arguments: [
        ("status-running-mounting.plist", "MountingDiskImage"),
        ("status-running-copying.plist", "Copying"),
        ("status-running-thinning-post-backup.plist", "ThinningPostBackup"),
    ])
    func runningBackupNamesItsDiskAndPhase(fixtureName: String, phase: String) throws {
        #expect(TimeMachineStatus(statusOutput: try fixture(fixtureName)) == .running(destinationID: "00000000-0000-0000-0000-000000000001", phase: phase))
    }

    @Test func thinningIsCleaningUp() throws {
        #expect(TimeMachineStatus(statusOutput: try fixture("status-running-thinning-post-backup.plist")).isCleaningUp)
        #expect(!TimeMachineStatus(statusOutput: try fixture("status-running-copying.plist")).isCleaningUp)
        #expect(!TimeMachineStatus.idle.isCleaningUp)
    }

    /// Each stage name lands in the group the menu words. Names are matched by how they start.
    @Test(arguments: [
        ("status-running-starting.plist", BackupStage.gettingReady),
        ("status-running-mounting.plist", .gettingReady),
        ("status-running-mounting-backup-vol.plist", .gettingReady),
        ("status-running-health-check.plist", .gettingReady),
        ("status-running-calculating-changes.plist", .gettingReady),
        ("status-running-finding-changes.plist", .gettingReady),
        ("status-running-preparing-source-volumes.plist", .gettingReady),
        ("status-running-copying.plist", .copying),
        ("status-running-time-remaining.plist", .copying),
        ("status-running-thinning-pre-backup.plist", .cleaningUp),
        ("status-running-thinning-post-backup.plist", .cleaningUp),
        ("status-running-unknown-phase.plist", .unknown),
        ("status-running-no-phase.plist", .unknown),
        ("status-idle.plist", .unknown),
    ])
    func stageNamesFallIntoGroups(fixtureName: String, stage: BackupStage) throws {
        #expect(TimeMachineStatus(statusOutput: try fixture(fixtureName)).stage == stage)
    }

    @Test func aRunningBackupWithoutADestinationIDStillCounts() {
        let output = "<plist version=\"1.0\"><dict><key>Running</key><true/></dict></plist>"
        #expect(TimeMachineStatus(statusOutput: output) == .running(destinationID: nil))
    }

    @Test(arguments: [
        "",
        "tmutil: status requires Full Disk Access",
        "<plist version=\"1.0\"><dict><key>ClientID</key><string>com.apple.backupd</string></dict></plist>",
    ])
    func outputWeCannotReadIsUnknown(output: String) {
        #expect(TimeMachineStatus(statusOutput: output) == .unknown)
    }
}
