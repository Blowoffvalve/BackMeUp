import Foundation
import Testing
import BackMeUpCore

/// The log: what happened, for the user or someone helping them, opened from Show Log.
@MainActor
@Suite("The log")
struct LogTests {
    static let networkDisk = DestinationInfo.configured(Destination(kind: .network, id: "network-id"))

    func harnessWithNetworkDisk() -> SchedulerHarness {
        let harness = SchedulerHarness()
        harness.system.destinationInfo = Self.networkDisk
        return harness
    }

    @Test func everyBackupAttemptIsLogged() async {
        let harness = harnessWithNetworkDisk()
        harness.system.nextBackup = .fails(result: 19)
        harness.at(minutes: 30) { $0.nextBackup = .succeeds }
        harness.at(minutes: 90) { $0.network = .none }

        await harness.start() // fails at 00:20
        await harness.advance(minutes: 24 * 60 + 90) // succeeds at 01:40; the next day's is skipped

        #expect(harness.system.logLines == [
            "Backup failed: Time Machine reported error 19",
            "Alert sent: Backup failed",
            "Backup succeeded",
            "Alert sent: Backups are working again",
            "Backup skipped: not on a chosen network",
        ])
    }

    @Test func networkNamesAndAddressesNeverReachTheLog() async {
        let harness = harnessWithNetworkDisk()
        harness.system.network = .router(address: "02:00:00:00:00:07", wifiName: "Example Café")

        await harness.start()

        #expect(harness.system.logLines == ["Backup skipped: not on a chosen network"])
    }

    /// Each change of Time Machine's stage name is logged, so real names, including ones the menu
    /// doesn't know, build up in the log. Nothing is logged while the stage stays the same.
    @Test func everyStageChangeIsLogged() async {
        let harness = harnessWithNetworkDisk()
        harness.system.nextBackup = .lasting(minutes: 60)
        harness.at(minutes: 10) { $0.startedBackupPhase = "MountingBackupVolForHealthCheck" }
        harness.at(minutes: 20) { $0.startedBackupPhase = "Copying" }
        harness.at(minutes: 40) { $0.startedBackupPhase = "SomeFutureStage" }

        await harness.start()
        await harness.advance(minutes: 120) // the backup ends at 01:00

        #expect(harness.system.logLines == [
            "Phase: none -> MountingBackupVolForHealthCheck",
            "Phase: MountingBackupVolForHealthCheck -> Copying",
            "Phase: Copying -> SomeFutureStage",
            "Backup succeeded",
            "Phase: SomeFutureStage -> none",
        ])
    }

    /// Stages of a backup Time Machine runs by itself are logged too.
    @Test func stagesOfTimeMachinesOwnBackupAreLogged() async {
        let harness = harnessWithNetworkDisk()
        await harness.start() // BackMeUp's first backup succeeds
        harness.at(minutes: 30) { $0.timeMachineStatus = .running(destinationID: "network-id", phase: "Starting") }
        harness.at(minutes: 40) { $0.timeMachineStatus = .running(destinationID: "network-id", phase: "ThinningPostBackup") }
        harness.at(minutes: 50) { $0.timeMachineStatus = .idle }

        await harness.advance(minutes: 60)

        #expect(harness.system.logLines == [
            "Backup succeeded",
            "Phase: none -> Starting",
            "Phase: Starting -> ThinningPostBackup",
            "Phase: ThinningPostBackup -> none",
        ])
    }

    @Test func showLogOpensTheLog() {
        let harness = SchedulerHarness()

        #expect(harness.scheduler.showLog())
        #expect(harness.system.logOpenings == 1)
    }

    @Test func showLogSaysWhenTheLogCannotBeOpened() {
        let harness = SchedulerHarness()
        harness.system.logOpens = false

        #expect(!harness.scheduler.showLog())
    }

    @Test func uninstallingDeletesTheLogAndLogsNothingMore() async {
        let harness = harnessWithNetworkDisk()
        harness.system.nextBackup = .fails(result: 19)
        await harness.start()
        #expect(!harness.system.logLines.isEmpty)

        harness.scheduler.uninstall()
        await harness.advance(minutes: 24 * 60)
        await harness.backUpNow()
        harness.quit()

        #expect(harness.system.logLines.isEmpty)
        #expect(harness.system.logDeletions >= 1)
    }
}
