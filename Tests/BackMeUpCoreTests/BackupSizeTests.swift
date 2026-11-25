import Foundation
import Testing
import BackMeUpCore

/// How much each finished backup copied, on its dot in the strip.
@MainActor
@Suite("Backup sizes")
struct BackupSizeTests {
    static let networkDisk = DestinationInfo.configured(Destination(kind: .network, id: "network-id"))

    /// A network disk with these backups on it. The harness starts at Thu 1 Jan 2026 00:00 UTC.
    func harnessWithNetworkDisk(snapshots: [Date] = []) -> SchedulerHarness {
        let harness = SchedulerHarness()
        harness.system.destinationInfo = Self.networkDisk
        harness.system.preferences = TimeMachinePreferences(autoBackup: false, destinations: [
            .init(id: "network-id", encryption: .encrypted, result: 0, snapshotDates: snapshots),
        ])
        return harness
    }

    /// Scripts the next backup BackMeUp starts to copy `bytes` in total and end as `outcome`
    /// after 30 minutes.
    func scriptBackup(_ harness: SchedulerHarness, totalBytes: Int64,
                      exitCode: Int32? = 0, result: Int? = 0) {
        harness.system.nextBackup = .lasting(minutes: 30, exitCode: exitCode, result: result)
        harness.system.startedBackupPhase = "Copying"
        harness.system.backupProgress = BackupProgress(fraction: 0.5, totalBytes: totalBytes)
    }

    var today: (SchedulerHarness) -> BackupStrip.Slot? { { $0.scheduler.backupStrip.slots.last } }

    @Test func afterABackupFinishesItsDotSaysHowMuchItCopied() async {
        let harness = harnessWithNetworkDisk()
        scriptBackup(harness, totalBytes: 3_200_000_000)

        await harness.start() // backs up 00:00 to 00:30
        await harness.advance(minutes: 60)

        #expect(today(harness)?.caption == "Thu 1 Jan: backed up 00:30, 3.2 GB copied")
        #expect(today(harness)?.accessibilityLabel == "Thursday 1 January: backed up 00:30, 3.2 GB copied")
    }
}
