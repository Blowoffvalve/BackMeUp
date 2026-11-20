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
