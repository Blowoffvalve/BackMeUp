import Foundation
import Testing
import BackMeUpCore

/// When backups start, what counts as success, retries, skips and Back Up Now.
@MainActor
@Suite("Scheduled backups")
struct SchedulerTests {
    static let networkDisk = DestinationInfo.configured(Destination(kind: .network, id: "network-id"))
    static let unpluggedLocalDisk = DestinationInfo.configured(Destination(kind: .local, id: "local-id"))
    static let pluggedInLocalDisk = DestinationInfo.configured(
        Destination(kind: .local, id: "local-id", mountPoint: "/Volumes/Backup Disk")
    )

    func harnessWithNetworkDisk() -> SchedulerHarness {
        let harness = SchedulerHarness()
        harness.system.destinationInfo = Self.networkDisk
        return harness
    }

    /// A Mac whose first backup, started at launch, succeeded and took 20 minutes.
    func harnessAfterFirstBackup() async -> SchedulerHarness {
        let harness = harnessWithNetworkDisk()
        await harness.start()
        return harness
    }

    // MARK: Due or not due

    @Test func firstLaunchWithNoBackupsStartsOneStraightAway() async {
        let harness = harnessWithNetworkDisk()

        await harness.start()

        #expect(harness.system.startedBackups == [harness.startDate])
    }

    @Test func theNextBackupIsDueOneDayAfterTheLastSuccess() async {
        let harness = await harnessAfterFirstBackup() // finished at 00:20

        await harness.advance(minutes: 24 * 60) // to 00:20 the next day
        #expect(harness.system.startedBackups == [harness.minutes(0), harness.minutes(24 * 60 + 20)])
    }

    @Test func nothingStartsBeforeTheBackupIsDue() async {
        let harness = await harnessAfterFirstBackup()

        await harness.advance(minutes: 24 * 60 - 1) // to 00:19 the next day

        #expect(harness.system.startedBackups == [harness.minutes(0)])
    }

    nonisolated static let intervals: [(BackupInterval, Double)] = [
        (BackupInterval(count: 6, unit: .hours), 6 * 60),
        (BackupInterval(count: 2, unit: .days), 2 * 24 * 60),
        (BackupInterval(count: 1, unit: .weeks), 7 * 24 * 60),
    ]

    @Test(arguments: intervals)
    func theBackupIntervalCanBeHoursDaysOrWeeks(interval: BackupInterval, minutesAfterSuccess: Double) async {
        let harness = await harnessAfterFirstBackup()
        harness.changeSettings { $0.backupInterval = interval }

        await harness.advance(minutes: minutesAfterSuccess - 1)
        #expect(harness.system.startedBackups.count == 1)

        await harness.advance(minutes: 1)
        #expect(harness.system.startedBackups.last == harness.minutes(20 + minutesAfterSuccess))
    }

    @Test func aBackupTimeMachineIsAlreadyRunningIsNotStartedAgain() async {
        let harness = harnessWithNetworkDisk()
        harness.system.timeMachineStatus = .running
        harness.at(minutes: 30) { $0.timeMachineStatus = .idle }

        await harness.start()
        await harness.advance(minutes: 29)
        #expect(harness.system.startedBackups.isEmpty)

        await harness.advance(minutes: 1)
        #expect(harness.system.startedBackups == [harness.minutes(30)])
    }

    // MARK: Success and failure

    @Test func aSuccessIsRecordedAndShown() async {
        let harness = await harnessAfterFirstBackup()

        #expect(harness.statusLine == "Last backup: today 00:20")
        #expect(harness.nextBackupLine == "Next backup: tomorrow 00:20")
    }

    nonisolated static let failures: [(FakeSystem.ScriptedBackup, String)] = [
        (.fails(exitCode: 0, result: 19), "Last backup failed: Time Machine reported error 19"),
        (.fails(exitCode: 0, result: nil), "Last backup failed: couldn't read Time Machine's result"),
        (.fails(exitCode: 1, result: 0), "Last backup failed: Time Machine stopped with code 1"),
        (.fails(exitCode: nil), "Last backup failed: couldn't start Time Machine"),
    ]

    @Test(arguments: failures)
    func anythingButExit0AndResult0IsAFailure(backup: FakeSystem.ScriptedBackup, expected: String) async {
        let harness = harnessWithNetworkDisk()
        harness.system.nextBackup = backup

        await harness.start()

        #expect(harness.statusLine == expected)
        #expect(harness.scheduler.history.lastSuccess == nil)
    }

    @Test func unreadablePreferencesAfterABackupAreAFailure() async {
        let harness = harnessWithNetworkDisk()
        harness.system.nextBackup.preferencesUnreadableAfterwards = true

        await harness.start()

        #expect(harness.statusLine == "Last backup failed: couldn't read Time Machine's result")
    }

    @Test func aFailureIsRetriedAfterTheRetryInterval() async {
        let harness = harnessWithNetworkDisk()
        harness.system.nextBackup = .fails(result: 19) // finishes at 00:20
        harness.at(minutes: 21) { $0.nextBackup = .succeeds }

        await harness.start()
        #expect(harness.nextBackupLine == "Next try: today 01:20")

        await harness.advance(minutes: 59)
        #expect(harness.system.startedBackups == [harness.minutes(0)])

        await harness.advance(minutes: 1)
        #expect(harness.system.startedBackups == [harness.minutes(0), harness.minutes(80)])
        #expect(harness.statusLine == "Last backup: today 01:40")
    }

    @Test func theRetryIntervalCanBeChanged() async {
        let harness = harnessWithNetworkDisk()
        harness.changeSettings { $0.retryMinutes = 30 }
        harness.system.nextBackup = .fails(result: 19)

        await harness.start()
        await harness.advance(minutes: 50)

        #expect(harness.system.startedBackups == [harness.minutes(0), harness.minutes(50)])
    }

    @Test func retriesAreAtLeast15MinutesApart() async {
        let harness = harnessWithNetworkDisk()
        harness.changeSettings { $0.retryMinutes = 1 }
        harness.system.nextBackup = .fails(exitCode: 1, minutes: 0)

        await harness.start()
        await harness.advance(minutes: 14)
        #expect(harness.system.startedBackups.count == 1)

        await harness.advance(minutes: 1)
        #expect(harness.system.startedBackups.count == 2)
        #expect(harness.scheduler.settings.retryMinutes == 15)
    }

    @Test func theDefaultsAreOneDayAndOneHour() {
        let harness = SchedulerHarness()

        #expect(harness.scheduler.settings == BackupSettings(
            backupInterval: BackupInterval(count: 1, unit: .days),
            retryMinutes: 60
        ))
    }

    // MARK: Skipping

    @Test func anUnpluggedLocalDiskIsSkippedWithAReason() async {
        let harness = SchedulerHarness()
        harness.system.destinationInfo = Self.unpluggedLocalDisk

        await harness.start()

        #expect(harness.system.startedBackups.isEmpty)
        #expect(harness.statusLine == "Backup skipped: backup disk not connected")
        #expect(harness.nextBackupLine == "Next try: today 01:00")
        #expect(harness.scheduler.skipReason == .diskNotConnected)
    }

    @Test func aSkippedBackupRunsOnceTheDiskIsBack() async {
        let harness = SchedulerHarness()
        harness.system.destinationInfo = Self.unpluggedLocalDisk
        harness.at(minutes: 30) { $0.destinationInfo = Self.pluggedInLocalDisk }

        await harness.start()
        await harness.advance(minutes: 60)

        #expect(harness.system.startedBackups == [harness.minutes(60)])
        #expect(harness.statusLine == "Last backup: today 01:20")
        #expect(harness.scheduler.skipReason == nil)
    }

    @Test func noDiskSetUpIsSkippedWithAReason() async {
        let harness = SchedulerHarness()
        harness.system.destinationInfo = .notSetUp

        await harness.start()

        #expect(harness.system.startedBackups.isEmpty)
        #expect(harness.statusLine == "Backup skipped: no Time Machine disk set up")
        #expect(harness.scheduler.skipReason == .noDiskSetUp)
    }

    @Test func aNetworkDiskThatIsNotMountedIsStillTried() async {
        // Time Machine mounts network disks itself, so an unmounted one isn't "not connected".
        let harness = harnessWithNetworkDisk()

        await harness.start()

        #expect(harness.system.startedBackups.count == 1)
    }

    // MARK: Back Up Now

    @Test func backUpNowStartsABackupEvenWhenNoneIsDue() async {
        let harness = await harnessAfterFirstBackup()
        await harness.advance(minutes: 60)

        await harness.backUpNow()

        #expect(harness.system.startedBackups == [harness.minutes(0), harness.minutes(80)])
        #expect(harness.statusLine == "Last backup: today 01:40")
        #expect(harness.nextBackupLine == "Next backup: tomorrow 01:40")
    }

    @Test func backUpNowWithTheDiskUnpluggedIsSkipped() async {
        let harness = SchedulerHarness()
        harness.system.destinationInfo = Self.pluggedInLocalDisk
        await harness.start()
        harness.system.destinationInfo = Self.unpluggedLocalDisk

        await harness.backUpNow()

        #expect(harness.system.startedBackups.count == 1)
        #expect(harness.statusLine == "Backup skipped: backup disk not connected")
    }

    // MARK: Surviving restarts

    @Test func theLastSuccessSurvivesARestart() async {
        let harness = await harnessAfterFirstBackup()
        await harness.advance(minutes: 60)

        await harness.restart()

        #expect(harness.system.startedBackups.count == 1)
        #expect(harness.statusLine == "Last backup: today 00:20")
        #expect(harness.nextBackupLine == "Next backup: tomorrow 00:20")
    }

    @Test func theAttemptHistorySurvivesARestart() async {
        let harness = harnessWithNetworkDisk()
        harness.system.nextBackup = .fails(result: 19)
        await harness.start()

        await harness.restart()

        #expect(harness.scheduler.history.attempts.map(\.outcome) == [.failed(.result(19))])
        #expect(harness.statusLine == "Last backup failed: Time Machine reported error 19")
        #expect(harness.system.startedBackups.count == 1) // still waiting for the retry
    }

    @Test func settingsSurviveARestart() async {
        let harness = SchedulerHarness()
        harness.changeSettings { $0.backupInterval = BackupInterval(count: 3, unit: .weeks) }

        await harness.restart()

        #expect(harness.scheduler.settings.backupInterval == BackupInterval(count: 3, unit: .weeks))
    }
}
