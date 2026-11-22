import Foundation
import Testing
import BackMeUpCore

/// The strip of dots under the menu's status line: which recent days were backed up.
@MainActor
@Suite("Backup strip")
struct BackupStripTests {
    static let networkDisk = DestinationInfo.configured(Destination(kind: .network, id: "network-id"))

    /// A network disk with no backups on it yet. The harness starts at Thu 1 Jan 2026 00:00 UTC.
    func harnessWithNetworkDisk(snapshots: [Date] = []) -> SchedulerHarness {
        let harness = SchedulerHarness()
        harness.system.destinationInfo = Self.networkDisk
        harness.system.preferences = TimeMachinePreferences(autoBackup: false, destinations: [
            .init(id: "network-id", encryption: .encrypted, result: 0, snapshotDates: snapshots),
        ])
        return harness
    }

    @Test func withADailyIntervalItShowsFourteenDaysEndingToday() async {
        let harness = harnessWithNetworkDisk()

        await harness.start() // backs up 00:00 to 00:20
        await harness.advance(minutes: 12 * 60)

        let strip = harness.scheduler.backupStrip
        #expect(strip.isShown)
        #expect(strip.slots.count == 14)
        #expect(strip.slots.first?.caption == "Fri 19 Dec: not backed up")
        #expect(strip.slots.last?.caption == "Thu 1 Jan: backed up 00:20")
        #expect(strip.slots.map(\.kind) == Array(repeating: .skipped, count: 13) + [.backedUp])
        #expect(strip.slots.map(\.isCurrent) == Array(repeating: false, count: 13) + [true])
        #expect(strip.summary == "Backed up 1 of the last 14 days")
    }

    @Test func aBackupTimeMachineMadeByItselfCounts() async {
        let harness = harnessWithNetworkDisk(snapshots: [
            Self.minutes(-2 * 24 * 60 + 9 * 60 + 14), // Tue 30 Dec 09:14
            Self.minutes(-1), // Wed 31 Dec 23:59, before midnight
        ])
        harness.system.nextBackup = .fails(result: 19)

        await harness.start()

        #expect(harness.system.startedBackups.count == 1)
        #expect(captions(harness).suffix(3) == [
            "Tue 30 Dec: backed up 09:14",
            "Wed 31 Dec: backed up 23:59",
            "Thu 1 Jan: not backed up",
        ])
        #expect(harness.scheduler.backupStrip.summary == "Backed up 2 of the last 14 days")
    }

    /// Time Machine thins old backups; BackMeUp's own record still counts them.
    @Test func aBackupOnlyBackMeUpRecordedCounts() async {
        let harness = harnessWithNetworkDisk()
        let finished = Self.minutes(-3 * 24 * 60 + 8 * 60) // Mon 29 Dec 08:00
        harness.system.storedHistory = BackupHistory(
            lastSuccess: finished,
            attempts: [BackupAttempt(started: finished.addingTimeInterval(-600), finished: finished, outcome: .succeeded)]
        )

        await harness.restart() // loads that history; a backup is due, so it backs up 00:00 to 00:20

        #expect(captions(harness).suffix(4) == [
            "Mon 29 Dec: backed up 08:00",
            "Tue 30 Dec: not backed up",
            "Wed 31 Dec: not backed up",
            "Thu 1 Jan: backed up 00:20",
        ])
    }

    @Test func backupsToAnotherDiskDoNotCount() async {
        let harness = SchedulerHarness()
        let usbDisk = Destination(kind: .local, id: "usb-id", name: "Old Disk", mountPoint: "/Volumes/Old Disk")
        let networkDisk = Destination(kind: .network, id: "network-id", name: "New Disk")
        harness.system.destinationInfo = .several([usbDisk, networkDisk])
        harness.system.preferences = TimeMachinePreferences(autoBackup: false, destinations: [
            .init(id: "usb-id", encryption: .notEncrypted, result: 0, snapshotDates: [Self.minutes(-24 * 60 + 60)]),
            .init(id: "network-id", encryption: .encrypted, result: 0, snapshotDates: [Self.minutes(-2 * 24 * 60 + 60)]),
        ])
        harness.system.nextBackup = .fails(result: 19)

        await harness.start()
        await harness.scheduler.chooseDisk(id: "network-id")

        #expect(captions(harness).suffix(2) == ["Wed 31 Dec: not backed up", "Thu 1 Jan: not backed up"])
        #expect(captions(harness).suffix(3).first == "Tue 30 Dec: backed up 01:00")
    }

    // MARK: When it shows

    @Test func hiddenUntilSetupAllowsBackupsOrABackupExists() async {
        let harness = harnessWithNetworkDisk()
        harness.system.preferences?.autoBackup = true // check 2 not done

        #expect(!harness.scheduler.backupStrip.isShown)
        await harness.start()
        #expect(harness.system.startedBackups.isEmpty)
        #expect(!harness.scheduler.backupStrip.isShown)

        // A backup Time Machine made by itself is on the disk.
        harness.system.preferences?.destinations[0].snapshotDates = [Self.minutes(-60)]
        await harness.scheduler.refreshStatus()
        #expect(harness.scheduler.backupStrip.isShown)
    }

    @Test func shownOnceSetupAllowsBackupsEvenWithNoBackupYet() async {
        let harness = harnessWithNetworkDisk()
        harness.system.nextBackup = .fails(result: 19)

        await harness.start()

        #expect(harness.scheduler.backupStrip.isShown)
        #expect(harness.scheduler.backupStrip.summary == "Backed up 0 of the last 14 days")
    }

    @Test func hiddenAfterUninstall() async {
        let harness = harnessWithNetworkDisk()
        await harness.start()
        #expect(harness.scheduler.backupStrip.isShown)

        harness.scheduler.uninstall()
        await harness.advance(minutes: 60)

        #expect(harness.scheduler.backupStrip == .hidden)
    }

    /// Minutes after the harness's start date, Thu 1 Jan 2026 00:00 UTC.
    static func minutes(_ minutes: Double) -> Date {
        SchedulerHarness.startDate.addingTimeInterval(minutes * 60)
    }

    func captions(_ harness: SchedulerHarness) -> [String] {
        harness.scheduler.backupStrip.slots.map(\.caption)
    }
}
