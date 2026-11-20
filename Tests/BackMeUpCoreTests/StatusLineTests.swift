import Foundation
import Testing
import BackMeUpCore

/// What the menu's two lines say: the last backup, and the next one.
@MainActor
@Suite("Menu status line")
struct StatusLineTests {
    static let networkDisk = DestinationInfo.configured(Destination(kind: .network, id: "network-id"))

    @Test func beforeAnyBackupHasRun() {
        let harness = SchedulerHarness()

        #expect(harness.statusLine == "No backups yet")
        #expect(harness.nextBackupLine == "Next backup: now")
    }

    @Test func refreshingTheMenuNeverStartsABackup() async {
        let harness = SchedulerHarness()
        harness.system.destinationInfo = Self.networkDisk
        harness.system.timeMachineStatus = .running

        await harness.scheduler.refreshStatus()

        #expect(harness.system.startedBackups.isEmpty)
        #expect(harness.statusLine == "Backing up now")
    }

    @Test func showsTimeMachineBackingUpByItself() async {
        let harness = SchedulerHarness()
        harness.system.destinationInfo = Self.networkDisk
        harness.system.timeMachineStatus = .running

        await harness.start()

        #expect(harness.statusLine == "Backing up now")
        #expect(harness.nextBackupLine == "")
    }

    @Test func olderBackupsShowTheirDate() async {
        let harness = SchedulerHarness()
        harness.system.destinationInfo = Self.networkDisk
        await harness.start() // finished 1 Jan 00:20
        harness.changeSettings { $0.backupInterval = BackupInterval(count: 1, unit: .weeks) }

        await harness.advance(minutes: 24 * 60)
        #expect(harness.statusLine == "Last backup: yesterday 00:20")

        await harness.advance(minutes: 24 * 60)
        #expect(harness.statusLine == "Last backup: 1 Jan 00:20")
        #expect(harness.nextBackupLine == "Next backup: 8 Jan 00:20")
    }
}
