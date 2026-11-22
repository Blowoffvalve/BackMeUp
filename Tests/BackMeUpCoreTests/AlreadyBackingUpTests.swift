import Foundation
import Testing
@testable import BackMeUpCore

/// When Time Machine is already backing up to the chosen disk, BackMeUp's own backup isn't a
/// failure: `tmutil startbackup` gives up at once, and the `RESULT` it leaves is the previous
/// backup's.
@MainActor
@Suite("Already backing up")
struct AlreadyBackingUpTests {
    static let disk = DestinationInfo.configured(Destination(kind: .network, id: "network-id", serverHost: "backup-server"))

    /// A failed backup leaves `RESULT` 26 behind, as on the Mac where this was seen.
    func harnessAfterAFailure() async -> SchedulerHarness {
        let harness = SchedulerHarness()
        harness.system.destinationInfo = Self.disk
        harness.system.nextBackup = .fails(result: 26, minutes: 1)
        await harness.start()
        #expect(harness.scheduler.history.attempts.last?.outcome == .failed(.diskUnreachable(isNetworkDisk: true)))
        return harness
    }

    @Test func backUpNowWhileTimeMachineBacksUpToTheChosenDiskStartsNothingAndRecordsNothing() async {
        let harness = await harnessAfterAFailure()
        let attemptsBefore = harness.scheduler.history.attempts
        let notificationsBefore = harness.notifications
        let backupsBefore = harness.system.startedBackups
        harness.system.timeMachineStatus = .running(destinationID: "network-id")

        await harness.backUpNow()

        #expect(harness.system.startedBackups == backupsBefore)
        #expect(harness.scheduler.history.attempts == attemptsBefore)
        #expect(harness.notifications == notificationsBefore)
    }

    /// Time Machine's own backup starts between BackMeUp's check and its command.
    @Test func aBackupAlreadyInProgressIsNotAFailure() async {
        let harness = await harnessAfterAFailure()
        let attemptsBefore = harness.scheduler.history.attempts
        let notificationsBefore = harness.notifications
        harness.system.nextBackup = .alreadyInProgress

        await harness.backUpNow()

        #expect(harness.scheduler.history.attempts == attemptsBefore)
        #expect(harness.notifications == notificationsBefore)
        #expect(harness.system.logLines.last?.contains("already backing up") == true)
    }

    @Test func beforeTheFirstSuccessABackupAlreadyInProgressIsNotAFailureEither() async {
        let harness = SchedulerHarness()
        harness.system.destinationInfo = Self.disk
        harness.system.nextBackup = .alreadyInProgress

        await harness.start()

        #expect(harness.scheduler.history.attempts.isEmpty)
        #expect(harness.notifications.isEmpty)
    }
}
