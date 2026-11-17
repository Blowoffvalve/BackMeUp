import Foundation
import Testing
import BackMeUpCore

/// What the menu says while a backup runs.
@MainActor
@Suite("Progress while backing up")
struct ProgressLineTests {
    static let networkDisk = DestinationInfo.configured(Destination(kind: .network, id: "network-id"))

    func harnessWithNetworkDisk() -> SchedulerHarness {
        let harness = SchedulerHarness()
        harness.system.destinationInfo = Self.networkDisk
        return harness
    }

    @Test func theFirstBackupShowsTimeMachinesProgressAndTimeLeft() async {
        let harness = harnessWithNetworkDisk()
        harness.system.nextBackup = .lasting(minutes: 600)
        harness.at(minutes: 5) { $0.backupProgress = BackupProgress(fraction: 0.352, timeRemaining: 3 * 3600 - 200) }

        await harness.start()
        #expect(harness.statusLine == "Backing up now")

        await harness.advance(minutes: 5)
        #expect(harness.statusLine == "First backup: 35%, about 3 hours left")
        #expect(harness.nextBackupLine == "")
    }

    @Test func laterBackupsShowProgressToo() async {
        let harness = harnessWithNetworkDisk()
        await harness.start() // the first backup succeeds
        harness.system.nextBackup = .lasting(minutes: 30)
        harness.system.backupProgress = BackupProgress(fraction: 0.5, timeRemaining: 20 * 60)

        await harness.backUpNow()
        await harness.advance(minutes: 1)

        #expect(harness.statusLine == "Backing up: 50%, about 20 minutes left")
    }

    nonisolated static let timesLeft: [(TimeInterval, String)] = [
        (30, "less than a minute left"),
        (60, "about 1 minute left"),
        (44 * 60 + 40, "about 45 minutes left"),
        (80 * 60, "about 1 hour left"),
        (47 * 3600, "about 47 hours left"),
        (60 * 3600, "about 3 days left"),
    ]

    @Test(arguments: timesLeft)
    func timeLeftIsRoundedToSomethingReadable(seconds: TimeInterval, expected: String) async {
        let harness = harnessWithNetworkDisk()
        harness.system.timeMachineStatus = .running
        harness.system.backupProgress = BackupProgress(fraction: 0.5, timeRemaining: seconds)

        await harness.scheduler.refreshStatus()

        #expect(harness.statusLine == "First backup: 50%, \(expected)")
    }

    @Test func withoutTimeMachinesEstimateTheTimeLeftComesFromTheRateSoFar() async {
        // macOS doesn't always report `TimeRemaining`.
        let harness = harnessWithNetworkDisk()
        harness.system.nextBackup = .lasting(minutes: 600)
        harness.at(minutes: 10) { $0.backupProgress = BackupProgress(fraction: 0.10) }
        harness.at(minutes: 40) { $0.backupProgress = BackupProgress(fraction: 0.20) }

        await harness.start()
        await harness.advance(minutes: 10)
        #expect(harness.statusLine == "First backup: 10%")

        await harness.advance(minutes: 30)
        #expect(harness.statusLine == "First backup: 20%, about 4 hours left") // 10% per half hour
    }

    @Test func aTimeMachineBackupBackMeUpDidNotStartShowsProgressToo() async {
        let harness = harnessWithNetworkDisk()
        harness.system.timeMachineStatus = .running
        harness.system.backupProgress = BackupProgress(fraction: 0.9, timeRemaining: 120)

        await harness.start()

        #expect(harness.system.startedBackups.isEmpty)
        #expect(harness.statusLine == "First backup: 90%, about 2 minutes left")
    }
}
