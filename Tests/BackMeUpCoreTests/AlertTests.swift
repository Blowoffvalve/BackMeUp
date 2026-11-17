import Foundation
import Testing
import BackMeUpCore

/// Notifications when backups fail or are overdue, and when they work again.
@MainActor
@Suite("Alerts")
struct AlertTests {
    static let networkDisk = DestinationInfo.configured(Destination(kind: .network, id: "network-id"))

    func harnessWithNetworkDisk() -> SchedulerHarness {
        let harness = SchedulerHarness()
        harness.system.destinationInfo = Self.networkDisk
        return harness
    }

    @Test func oneFailedBackupSendsAFailureAlert() async {
        let harness = harnessWithNetworkDisk()
        harness.system.nextBackup = .fails(result: 19)

        await harness.start()

        #expect(harness.notifications == [
            Alert(kind: .failed, title: "Backup failed", body: "1 backup didn't finish. Time Machine reported error 19."),
        ])
    }

    @Test func aLastingFailureIsAlertedAtMostOnceEvery24Hours() async {
        let harness = harnessWithNetworkDisk()
        harness.system.nextBackup = .fails(result: 19)

        await harness.start() // fails at 00:20, then retried every 80 minutes
        await harness.advance(minutes: 2800)

        #expect(harness.system.notifications.map(\.date) == [harness.minutes(20), harness.minutes(20 + 24 * 60)])
        #expect(harness.notifications.last?.body == "19 backups didn't finish. Time Machine reported error 19.")
    }

    @Test func theFirstSuccessAfterAnAlertSaysBackupsAreWorkingAgain() async {
        let harness = harnessWithNetworkDisk()
        harness.system.nextBackup = .fails(result: 19)
        harness.at(minutes: 30) { $0.nextBackup = .succeeds }

        await harness.start() // fails at 00:20
        await harness.advance(minutes: 3 * 24 * 60) // retry succeeds at 01:40, then daily backups

        #expect(harness.notifications.map(\.kind) == [.failed, .workingAgain])
        #expect(harness.notifications.last == Alert(
            kind: .workingAgain,
            title: "Backups are working again",
            body: "Last backup: today 01:40"
        ))
        #expect(harness.system.notifications.last?.date == harness.minutes(100))
    }

    @Test func aNewProblemAfterRecoveryIsAlertedStraightAway() async {
        let harness = harnessWithNetworkDisk()
        harness.system.nextBackup = .fails(result: 19)
        harness.at(minutes: 30) { $0.nextBackup = .succeeds }
        harness.at(minutes: 120) { $0.nextBackup = .fails(exitCode: 1) }

        await harness.start() // fails at 00:20, succeeds at 01:40
        await harness.advance(minutes: 24 * 60 + 100) // the next day's backup fails at 02:00

        #expect(harness.notifications.map(\.kind) == [.failed, .workingAgain, .failed])
        #expect(harness.notifications.last?.body == "1 backup didn't finish. Time Machine stopped with code 1.")
    }

    @Test func theFailureAlertWaitsForTheChosenNumberOfFailuresInARow() async {
        let harness = harnessWithNetworkDisk()
        harness.changeSettings { $0.alerts.failuresInARow = 3 }
        harness.system.nextBackup = .fails(result: 22)

        await harness.start() // fails at 00:20, 01:40 and 03:00 (started at 02:40)
        await harness.advance(minutes: 139)
        #expect(harness.notifications.isEmpty)

        await harness.advance(minutes: 1)
        #expect(harness.system.notifications.map(\.date) == [harness.minutes(180)])
        #expect(harness.notifications == [
            Alert(kind: .failed, title: "Backups failed", body: "3 backups didn't finish. Time Machine reported error 22."),
        ])
    }

    @Test func aSuccessBeforeAnyAlertSendsNothing() async {
        let harness = harnessWithNetworkDisk()
        harness.changeSettings { $0.alerts.failuresInARow = 2 }
        harness.system.nextBackup = .fails(result: 22)
        harness.at(minutes: 30) { $0.nextBackup = .succeeds }

        await harness.start()
        await harness.advance(minutes: 24 * 60)

        #expect(harness.notifications.isEmpty)
    }

    // MARK: Overdue

    static let pluggedInLocalDisk = DestinationInfo.configured(
        Destination(kind: .local, id: "local-id", mountPoint: "/Volumes/Backup Disk")
    )
    static let unpluggedLocalDisk = DestinationInfo.configured(Destination(kind: .local, id: "local-id"))

    /// Backs up at launch (Thursday 1 January, 00:00 to 00:20), then the disk is unplugged, so
    /// every backup from Friday 00:20 is skipped, retried hourly.
    func harnessWithDiskUnpluggedAfterFirstBackup() async -> SchedulerHarness {
        let harness = SchedulerHarness()
        harness.system.destinationInfo = Self.pluggedInLocalDisk
        harness.at(minutes: 30) { $0.destinationInfo = Self.unpluggedLocalDisk }
        await harness.start()
        return harness
    }

    @Test func skipsAloneSendNoAlertBeforeBackupsAreOverdue() async {
        let harness = await harnessWithDiskUnpluggedAfterFirstBackup()

        await harness.advance(minutes: 3 * 24 * 60 - 1)

        #expect(harness.notifications.isEmpty)
    }

    @Test func daysOfSkipsSendAnOverdueAlertNamingTheSkipReason() async {
        let harness = await harnessWithDiskUnpluggedAfterFirstBackup()

        await harness.advance(minutes: 3 * 24 * 60)

        #expect(harness.notifications == [Alert(
            kind: .overdue,
            title: "Backups skipped",
            body: "No backup for 3 days. The backup disk hasn't been connected since Friday."
        )])
        #expect(harness.system.notifications.map(\.date) == [harness.minutes(20 + 3 * 24 * 60)])
    }

    @Test func theOverdueAlertRepeatsDailyWhileBackupsAreSkipped() async {
        let harness = await harnessWithDiskUnpluggedAfterFirstBackup()

        await harness.advance(minutes: 5 * 24 * 60)

        #expect(harness.notifications.map(\.body) == [
            "No backup for 3 days. The backup disk hasn't been connected since Friday.",
            "No backup for 4 days. The backup disk hasn't been connected since Friday.",
            "No backup for 5 days. The backup disk hasn't been connected since Friday.",
        ])
    }

    @Test func theOverdueDaysCanBeChanged() async {
        let harness = await harnessWithDiskUnpluggedAfterFirstBackup()
        harness.changeSettings { $0.alerts.daysWithoutBackup = 2 }

        await harness.advance(minutes: 2 * 24 * 60)

        #expect(harness.notifications.map(\.body) == [
            "No backup for 2 days. The backup disk hasn't been connected since yesterday.",
        ])
    }

    @Test func theOverdueAlertNamesTheMostCommonSkipReason() async {
        let harness = await harnessWithDiskUnpluggedAfterFirstBackup()
        // The disk is plugged in again on Saturday evening, but Time Machine's disk is then removed.
        harness.at(minutes: 2 * 24 * 60 + 18 * 60) { $0.destinationInfo = .notSetUp }

        await harness.advance(minutes: 3 * 24 * 60)

        #expect(harness.notifications.map(\.body) == [
            "No backup for 3 days. The backup disk hasn't been connected since Friday.",
        ])
    }

    @Test func overdueWithNoBackupEverCountsFromFirstLaunch() async {
        let harness = SchedulerHarness()
        harness.system.destinationInfo = .notSetUp

        await harness.start()
        await harness.advance(minutes: 3 * 24 * 60)

        #expect(harness.notifications == [Alert(
            kind: .overdue,
            title: "Backups skipped",
            body: "No backup for 3 days. Time Machine has no backup disk set up."
        )])
    }

    @Test func overdueAfterFailuresBelowTheThresholdSaysTheyFailed() async {
        let harness = harnessWithNetworkDisk()
        harness.changeSettings { $0.alerts.failuresInARow = 100 }
        harness.system.nextBackup = .fails(result: 22)

        await harness.start() // fails every 80 minutes, from 00:20
        await harness.advance(minutes: 3 * 24 * 60) // overdue at 00:00 on day 4, after 54 failures

        #expect(harness.notifications.map(\.kind) == [.overdue])
        #expect(harness.notifications.first?.title == "Backups failed")
        #expect(harness.notifications.first?.body == "No backup for 3 days. 54 backups didn't finish. Time Machine reported error 22.")
    }

    @Test func aSuccessAfterAnOverdueAlertSaysBackupsAreWorkingAgain() async {
        let harness = await harnessWithDiskUnpluggedAfterFirstBackup()
        harness.at(minutes: 3 * 24 * 60 + 12 * 60) { $0.destinationInfo = Self.pluggedInLocalDisk }

        await harness.advance(minutes: 5 * 24 * 60)

        #expect(harness.notifications.map(\.kind) == [.overdue, .workingAgain])
    }

    nonisolated static let networkSkips: [(NetworkReading, String)] = [
        (.router(address: "02:00:00:00:00:02", wifiName: "Cafe"), "Your Mac hasn't been on a chosen network since Friday."),
        (.none, "Your Mac hasn't been on a chosen network since Friday."),
        (.routerAddressUnknown, "BackMeUp hasn't been able to identify your Mac's network since Friday."),
    ]

    @Test(arguments: networkSkips)
    func daysAwayFromAChosenNetworkNameTheNetwork(network: NetworkReading, sentence: String) async {
        let harness = harnessWithNetworkDisk()
        harness.at(minutes: 30) { $0.network = network }

        await harness.start() // backs up at home, Thursday 00:00 to 00:20
        await harness.advance(minutes: 3 * 24 * 60)

        #expect(harness.notifications == [Alert(
            kind: .overdue,
            title: "Backups skipped",
            body: "No backup for 3 days. \(sentence)"
        )])
    }

    @Test func daysOnBatteryWithBatteryBackupsOffNameTheBattery() async {
        let harness = harnessWithNetworkDisk()
        harness.changeSettings { $0.allowBackupsOnBattery = false }
        harness.at(minutes: 30) { $0.powerSource = .battery }

        await harness.start() // backs up on power, Thursday 00:00 to 00:20
        await harness.advance(minutes: 3 * 24 * 60)

        #expect(harness.notifications == [Alert(
            kind: .overdue,
            title: "Backups skipped",
            body: "No backup for 3 days. Your Mac has been on battery each time a backup was due since Friday."
        )])
    }

    // MARK: The first backup

    @Test func aPausedFirstBackupSendsNoAlert() async {
        let harness = harnessWithNetworkDisk()
        harness.system.nextBackup = .fails(exitCode: 1, result: nil) // interrupted, no error result

        await harness.start()
        await harness.advance(minutes: 24 * 60)

        #expect(harness.notifications.isEmpty)
        #expect(!harness.scheduler.hasProblem)
    }

    @Test func aFirstBackupPausedForDaysIsOverdue() async {
        let harness = harnessWithNetworkDisk()
        harness.system.nextBackup = .fails(exitCode: 1, result: nil)

        await harness.start()
        await harness.advance(minutes: 3 * 24 * 60)

        #expect(harness.notifications == [Alert(
            kind: .overdue,
            title: "First backup not finished",
            body: "No backup for 3 days. The first backup keeps stopping before it finishes."
        )])
    }

    // MARK: Menu bar icon

    @Test func theIconShowsAProblemAfterAFailureAndClearsOnRecovery() async {
        let harness = harnessWithNetworkDisk()
        harness.system.nextBackup = .fails(result: 19)
        harness.at(minutes: 30) { $0.nextBackup = .succeeds }

        await harness.start()
        #expect(harness.scheduler.hasProblem)

        await harness.advance(minutes: 90) // the retry succeeds at 01:40
        #expect(!harness.scheduler.hasProblem)
    }

    @Test func theIconShowsNoProblemForSkipsUntilBackupsAreOverdue() async {
        let harness = await harnessWithDiskUnpluggedAfterFirstBackup()

        await harness.advance(minutes: 3 * 24 * 60 - 1)
        #expect(!harness.scheduler.hasProblem)

        await harness.advance(minutes: 1)
        #expect(harness.scheduler.hasProblem)
    }

    @Test func theIconShowsNoProblemForFailuresBelowTheThreshold() async {
        let harness = harnessWithNetworkDisk()
        harness.changeSettings { $0.alerts.failuresInARow = 2 }
        harness.system.nextBackup = .fails(result: 22)

        await harness.start()

        #expect(!harness.scheduler.hasProblem)
    }

    @Test func alertsAreNotRepeatedAfterARestart() async {
        let harness = harnessWithNetworkDisk()
        harness.system.nextBackup = .fails(result: 19)

        await harness.start()
        await harness.restart()
        await harness.advance(minutes: 60)

        #expect(harness.notifications.count == 1)
    }
}
