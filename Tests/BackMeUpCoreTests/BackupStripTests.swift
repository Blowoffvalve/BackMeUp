import Foundation
import Testing
import BackMeUpCore

/// The strip of dots under the menu's status line: which recent hours, days or weeks were backed up.
@MainActor
@Suite("Backup strip")
struct BackupStripTests {
    static let networkDisk = DestinationInfo.configured(Destination(kind: .network, id: "network-id"))

    /// A network disk with no backups on it yet. The harness starts at Thu 1 Jan 2026 00:00 UTC.
    func harnessWithNetworkDisk(snapshots: [Date] = [], calendar: Calendar = SchedulerHarness.utcCalendar,
                                startingAt start: Date = SchedulerHarness.startDate) -> SchedulerHarness {
        let harness = SchedulerHarness(startingAt: start, calendar: calendar)
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
        #expect(strip.slots.first?.caption == "Fri 19 Dec: before BackMeUp was set up")
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
            "Thu 1 Jan: failed, Time Machine reported error 19",
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
            "Tue 30 Dec: before BackMeUp was set up",
            "Wed 31 Dec: before BackMeUp was set up",
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

        #expect(captions(harness).suffix(2) == ["Wed 31 Dec: before BackMeUp was set up", "Thu 1 Jan: nothing yet"])
        #expect(captions(harness).suffix(3).first == "Tue 30 Dec: backed up 01:00")
    }

    // MARK: Slot unit

    @Test func withAnIntervalInHoursEachSlotIsAnHourEvenEverySixHours() async {
        let harness = harnessWithNetworkDisk()
        harness.system.storedSettings = BackupSettings(backupInterval: .init(count: 6, unit: .hours), retryMinutes: 60)
        await harness.restart() // backs up 00:00 to 00:20

        await harness.advance(minutes: 3 * 60 + 30)

        let strip = harness.scheduler.backupStrip
        #expect(strip.slots.count == 24)
        #expect(strip.slots.first?.caption == "Wed 31 Dec 04:00: before BackMeUp was set up")
        #expect(captions(harness).suffix(4) == [
            "Thu 1 Jan 00:00: backed up 00:20",
            "Thu 1 Jan 01:00: nothing due",
            "Thu 1 Jan 02:00: nothing due",
            "Thu 1 Jan 03:00: nothing due",
        ])
        #expect(strip.slots.last?.isCurrent == true)
        #expect(strip.summary == "Backed up 1 of the last 24 hours")
    }

    /// Weeks start on the region's first weekday: Monday in the UK, Sunday in the US.
    @Test(arguments: [
        ("en_GB", "week of 13 Oct", "week of 29 Dec"),
        ("en_US", "week of 12 Oct", "week of 28 Dec"),
    ])
    func withAnIntervalInWeeksEachSlotIsAWeekFromTheRegionsFirstWeekday(
        region: String, firstWeek: String, thisWeek: String
    ) async {
        var calendar = SchedulerHarness.utcCalendar
        calendar.locale = Locale(identifier: region)
        let saturday = Self.minutes(-5 * 24 * 60 + 9 * 60 + 14) // Sat 27 Dec 09:14
        let harness = harnessWithNetworkDisk(snapshots: [saturday], calendar: calendar)
        harness.system.storedSettings = BackupSettings(backupInterval: .init(count: 2, unit: .weeks), retryMinutes: 60)
        harness.system.nextBackup = .fails(result: 19)

        await harness.restart()

        let strip = harness.scheduler.backupStrip
        #expect(strip.slots.count == 12)
        #expect(strip.slots.first?.caption == "\(firstWeek): before BackMeUp was set up")
        #expect(strip.slots.last?.caption == "\(thisWeek): nothing due")
        #expect(strip.slots.last?.isCurrent == true)
        #expect(captions(harness).suffix(2).first?.hasSuffix(": backed up Sat 27 Dec 09:14") == true)
        #expect(strip.summary == "Backed up 1 of the last 12 weeks")
    }

    /// The UK's clocks go back an hour at 02:00 on Sun 25 Oct 2026, so 01:00 comes twice.
    @Test func hourSlotsKeepEveryHourWhenTheClocksGoBack() async {
        let harness = harnessWithNetworkDisk(calendar: Self.london, startingAt: Self.utc("2026-10-25T06:30:00Z"))
        harness.system.storedSettings = BackupSettings(backupInterval: .init(count: 1, unit: .hours), retryMinutes: 60)
        harness.system.nextBackup = .fails(result: 19)

        await harness.restart()

        let slots = harness.scheduler.backupStrip.slots
        #expect(slots.count == 24)
        #expect(slots.first?.start == Self.utc("2026-10-24T07:00:00Z"))
        #expect(zip(slots, slots.dropFirst()).allSatisfy { $1.start.timeIntervalSince($0.start) == 3600 })
        #expect(captions(harness).suffix(8) == [
            "Sun 25 Oct 00:00", "Sun 25 Oct 01:00", "Sun 25 Oct 01:00", "Sun 25 Oct 02:00",
            "Sun 25 Oct 03:00", "Sun 25 Oct 04:00", "Sun 25 Oct 05:00",
        ].map { "\($0): before BackMeUp was set up" } + ["Sun 25 Oct 06:00: failed, Time Machine reported error 19"])
    }

    /// The UK's clocks go forward an hour at 01:00 on Sun 29 Mar 2026, making that day 23 hours.
    @Test func daySlotsKeepEveryDayWhenTheClocksGoForward() async {
        let lateOnTheShortDay = Self.utc("2026-03-29T22:30:00Z") // 23:30 in the UK
        let harness = harnessWithNetworkDisk(snapshots: [lateOnTheShortDay], calendar: Self.london,
                                             startingAt: Self.utc("2026-04-01T12:00:00Z"))
        harness.system.nextBackup = .fails(result: 19)

        await harness.restart()

        #expect(captions(harness) == [
            "Thu 19 Mar", "Fri 20 Mar", "Sat 21 Mar", "Sun 22 Mar", "Mon 23 Mar", "Tue 24 Mar", "Wed 25 Mar",
            "Thu 26 Mar", "Fri 27 Mar", "Sat 28 Mar",
        ].map { "\($0): before BackMeUp was set up" } + [
            "Sun 29 Mar: backed up 23:30",
            "Mon 30 Mar: before BackMeUp was set up",
            "Tue 31 Mar: before BackMeUp was set up",
            "Wed 1 Apr: failed, Time Machine reported error 19",
        ])
    }

    @Test func changingTheIntervalSwitchesTheStripStraightAway() async {
        let harness = harnessWithNetworkDisk()
        await harness.start() // backs up 00:00 to 00:20
        #expect(harness.scheduler.backupStrip.slots.count == 14)

        harness.changeSettings { $0.backupInterval = .init(count: 3, unit: .hours) }
        #expect(harness.scheduler.backupStrip.slots.count == 24)
        #expect(harness.scheduler.backupStrip.slots.last?.caption == "Thu 1 Jan 00:00: backed up 00:20")
        #expect(harness.scheduler.backupStrip.summary == "Backed up 1 of the last 24 hours")

        harness.changeSettings { $0.backupInterval = .init(count: 1, unit: .weeks) }
        #expect(harness.scheduler.backupStrip.slots.last?.caption == "week of 28 Dec: backed up Thu 1 Jan 00:20")
        #expect(harness.scheduler.backupStrip.summary == "Backed up 1 of the last 12 weeks")
    }

    // MARK: Nothing due versus missed

    /// Every 3 days with a backup on Monday: Tuesday and Wednesday had nothing due, and Thursday
    /// is missed once it passes without a backup.
    @Test func everyThreeDaysTheDaysBetweenBackupsHadNothingDue() async {
        let harness = harnessWithNetworkDisk(snapshots: [
            Self.minutes(-3 * 24 * 60 + 9 * 60), // Mon 29 Dec 09:00
        ])
        harness.changeSettings { $0.backupInterval = BackupInterval(count: 3, unit: .days) }
        harness.system.nextBackup = .fails(result: 19)

        await harness.start()
        await harness.advance(minutes: 24 * 60 + 60) // Fri 2 Jan 01:00

        #expect(captions(harness).suffix(6) == [
            "Sun 28 Dec: before BackMeUp was set up",
            "Mon 29 Dec: backed up 09:00",
            "Tue 30 Dec: nothing due",
            "Wed 31 Dec: nothing due",
            "Thu 1 Jan: failed, Time Machine reported error 19",
            "Fri 2 Jan: failed, Time Machine reported error 19",
        ])
        #expect(harness.scheduler.backupStrip.slots.suffix(5).map(\.kind) == [
            .backedUp, .nothingDue, .nothingDue, .failed, .failed,
        ])
        #expect(harness.scheduler.backupStrip.summary == "Backed up 1 of the last 14 days")
    }

    @Test func everyDayADayWithoutABackupAfterOneWithABackupIsMissed() async {
        let harness = harnessWithNetworkDisk(snapshots: [
            Self.minutes(-2 * 24 * 60 + 23 * 60), // Tue 30 Dec 23:00
        ])
        harness.system.nextBackup = .fails(result: 19)

        await harness.start()

        #expect(captions(harness).suffix(3) == [
            "Tue 30 Dec: backed up 23:00",
            "Wed 31 Dec: before BackMeUp was set up",
            "Thu 1 Jan: failed, Time Machine reported error 19",
        ])
    }

    /// The current slot isn't missed while a backup is still due later in it, even if one was
    /// skipped.
    @Test func theCurrentSlotSaysNothingYetUntilABackupLands() async {
        let harness = harnessWithNetworkDisk(snapshots: [
            Self.minutes(-15 * 60), // Wed 31 Dec 09:00
        ])
        harness.system.network = .none

        await harness.start() // skipped: not on a network
        #expect(harness.system.startedBackups.isEmpty)
        #expect(harness.scheduler.backupStrip.slots.last?.caption == "Thu 1 Jan: nothing yet")
        #expect(harness.scheduler.backupStrip.slots.last?.kind == .nothingYet)
        #expect(harness.scheduler.backupStrip.summary == "Backed up 1 of the last 14 days")

        harness.at(minutes: 30) { $0.network = FakeSystem.home }
        await harness.advance(minutes: 2 * 60)

        #expect(harness.scheduler.backupStrip.slots.last?.caption.hasPrefix("Thu 1 Jan: backed up ") == true)
        #expect(harness.scheduler.backupStrip.slots.last?.kind == .backedUp)
        #expect(harness.scheduler.backupStrip.summary == "Backed up 2 of the last 14 days")
    }

    /// A failure shows in the current slot straight away, not only once the slot has passed.
    @Test func aFailureInTheCurrentSlotShowsStraightAway() async {
        let harness = harnessWithNetworkDisk(snapshots: [
            Self.minutes(-15 * 60), // Wed 31 Dec 09:00
        ])
        harness.system.nextBackup = .fails(result: 19)

        await harness.start() // fails 00:00 to 00:20
        #expect(harness.scheduler.backupStrip.slots.last?.caption == "Thu 1 Jan: failed, Time Machine reported error 19")
        #expect(harness.scheduler.backupStrip.slots.last?.accessibilityLabel
            == "Thursday 1 January: failed, Time Machine reported error 19")
        #expect(harness.scheduler.backupStrip.slots.last?.kind == .failed)
        #expect(harness.scheduler.backupStrip.summary == "Backed up 1 of the last 14 days")

        harness.system.nextBackup = .succeeds
        await harness.advance(minutes: 2 * 60) // retries 01:20 to 01:40

        #expect(harness.scheduler.backupStrip.slots.last?.caption == "Thu 1 Jan: backed up 01:40")
        #expect(harness.scheduler.backupStrip.slots.last?.kind == .backedUp)
        #expect(harness.scheduler.backupStrip.summary == "Backed up 2 of the last 14 days")
    }

    @Test func changingTheIntervalRejudgesPastSlots() async {
        let harness = harnessWithNetworkDisk(snapshots: [
            Self.minutes(-3 * 24 * 60 + 9 * 60), // Mon 29 Dec 09:00
        ])
        harness.system.nextBackup = .fails(result: 19)

        await harness.start()
        #expect(captions(harness).suffix(4) == [
            "Mon 29 Dec: backed up 09:00",
            "Tue 30 Dec: before BackMeUp was set up",
            "Wed 31 Dec: before BackMeUp was set up",
            "Thu 1 Jan: failed, Time Machine reported error 19",
        ])

        harness.changeSettings { $0.backupInterval = BackupInterval(count: 3, unit: .days) }
        #expect(captions(harness).suffix(3) == [
            "Tue 30 Dec: nothing due",
            "Wed 31 Dec: nothing due",
            "Thu 1 Jan: failed, Time Machine reported error 19",
        ])

        harness.changeSettings { $0.backupInterval = BackupInterval(count: 4, unit: .hours) }
        #expect(captions(harness).suffix(1) == ["Thu 1 Jan 00:00: failed, Time Machine reported error 19"])
        #expect(harness.scheduler.backupStrip.slots.last?.kind == .failed)
        #expect(harness.scheduler.backupStrip.slots.last?.isCurrent == true)

        // A week slot ends a week after it starts, so with a weekly interval a backup is due in
        // every week slot without one: the recent backup counts for this week, and the failure
        // after it doesn't make the week a failed one.
        harness.changeSettings { $0.backupInterval = BackupInterval(count: 1, unit: .weeks) }
        #expect(captions(harness).suffix(1) == ["week of 28 Dec: backed up Mon 29 Dec 09:00"])
        #expect(harness.scheduler.backupStrip.slots.last?.kind == .backedUp)
        #expect(harness.scheduler.backupStrip.slots.last?.isCurrent == true)
    }

    // MARK: VoiceOver

    @Test func voiceOverReadsEachDotsCaptionWrittenOutInFullAndTheSummaryForTheStrip() async {
        let harness = harnessWithNetworkDisk(snapshots: [
            Self.minutes(-2 * 24 * 60 + 9 * 60 + 14), // Tue 30 Dec 09:14
        ])
        harness.system.nextBackup = .fails(result: 19)

        await harness.start()

        let strip = harness.scheduler.backupStrip
        #expect(strip.accessibilityLabel == "Backed up 1 of the last 14 days")
        #expect(strip.slots.map(\.accessibilityLabel).first == "Friday 19 December: before BackMeUp was set up")
        #expect(strip.slots.map(\.accessibilityLabel).suffix(3) == [
            "Tuesday 30 December: backed up 09:14",
            "Wednesday 31 December: before BackMeUp was set up",
            "Thursday 1 January: failed, Time Machine reported error 19",
        ])
    }

    @Test func voiceOverWritesOutHourAndWeekSlotsInFullToo() async {
        let harness = harnessWithNetworkDisk()
        await harness.start() // backs up 00:00 to 00:20

        harness.changeSettings { $0.backupInterval = .init(count: 3, unit: .hours) }
        #expect(harness.scheduler.backupStrip.slots.last?.accessibilityLabel == "Thursday 1 January 00:00: backed up 00:20")

        harness.changeSettings { $0.backupInterval = .init(count: 1, unit: .weeks) }
        #expect(harness.scheduler.backupStrip.slots.last?.accessibilityLabel
            == "week of 28 December: backed up Thursday 1 January 00:20")
        #expect(harness.scheduler.backupStrip.accessibilityLabel == "Backed up 1 of the last 12 weeks")
    }

    // MARK: Why a slot was missed

    /// A network disk whose history BackMeUp has kept since Fri 12 Dec, before the strip begins,
    /// with these attempts.
    func harnessWithHistory(_ attempts: [BackupAttempt], snapshots: [Date] = []) async -> SchedulerHarness {
        let harness = harnessWithNetworkDisk(snapshots: snapshots)
        var history = BackupHistory(attempts: attempts)
        history.monitoringSince = Self.minutes(-20 * 24 * 60)
        harness.system.storedHistory = history
        harness.system.nextBackup = .fails(result: 19)
        await harness.restart()
        return harness
    }

    /// An attempt `day` days before the harness's start, at `hour`.
    static func attempt(day: Double, hour: Double, _ outcome: BackupAttempt.Outcome) -> BackupAttempt {
        let started = minutes(-day * 24 * 60 + hour * 60)
        return BackupAttempt(started: started, finished: started.addingTimeInterval(60), outcome: outcome)
    }

    func slot(_ harness: SchedulerHarness, daysAgo: Int) -> BackupStrip.Slot {
        let slots = harness.scheduler.backupStrip.slots
        return slots[slots.count - 1 - daysAgo]
    }

    @Test func aSlotWithAFailureShowsARedCrossNamingIt() async {
        let harness = await harnessWithHistory([
            Self.attempt(day: 1, hour: 9, .failed(.diskUnreachable(isNetworkDisk: true))),
        ])

        #expect(slot(harness, daysAgo: 1).kind == .failed)
        #expect(slot(harness, daysAgo: 1).caption == "Wed 31 Dec: failed, the backup disk couldn't be reached")
    }

    @Test func theLatestFailureInASlotIsNamed() async {
        let harness = await harnessWithHistory([
            Self.attempt(day: 1, hour: 9, .failed(.diskUnreachable(isNetworkDisk: true))),
            Self.attempt(day: 1, hour: 11, .failed(.result(19))),
            Self.attempt(day: 1, hour: 10, .failed(.couldNotStart)),
        ].sorted { $0.started < $1.started })

        #expect(slot(harness, daysAgo: 1).caption == "Wed 31 Dec: failed, Time Machine reported error 19")
    }

    @Test func aFailureBeatsASkip() async {
        let harness = await harnessWithHistory([
            Self.attempt(day: 1, hour: 9, .skipped(.onBattery)),
            Self.attempt(day: 1, hour: 10, .failed(.result(19))),
            Self.attempt(day: 1, hour: 11, .skipped(.onBattery)),
        ])

        #expect(slot(harness, daysAgo: 1).kind == .failed)
        #expect(slot(harness, daysAgo: 1).caption == "Wed 31 Dec: failed, Time Machine reported error 19")
    }

    @Test func aSuccessBeatsAFailure() async {
        let harness = await harnessWithHistory([
            Self.attempt(day: 1, hour: 9, .failed(.result(19))),
            Self.attempt(day: 1, hour: 10, .succeeded),
        ])

        #expect(slot(harness, daysAgo: 1).kind == .backedUp)
        #expect(slot(harness, daysAgo: 1).caption == "Wed 31 Dec: backed up 10:01")
    }

    @Test func aSkippedSlotNamesItsMostCommonSkipReason() async {
        let harness = await harnessWithHistory([
            Self.attempt(day: 2, hour: 8, .skipped(.notOnChosenNetwork)),
            Self.attempt(day: 2, hour: 9, .skipped(.onBattery)),
            Self.attempt(day: 2, hour: 10, .skipped(.onBattery)),
            Self.attempt(day: 2, hour: 11, .skipped(.notOnChosenNetwork)),
            Self.attempt(day: 2, hour: 12, .skipped(.onBattery)),
        ])

        #expect(slot(harness, daysAgo: 2).kind == .skipped)
        #expect(slot(harness, daysAgo: 2).caption == "Tue 30 Dec: skipped, on battery")
    }

    @Test func aPausedFirstBackupSaysItCarriesOn() async {
        let harness = await harnessWithHistory([
            Self.attempt(day: 1, hour: 9, .paused),
        ])

        #expect(slot(harness, daysAgo: 1).kind == .skipped)
        #expect(slot(harness, daysAgo: 1).caption == "Wed 31 Dec: first backup paused, carries on next time")
    }

    @Test func aMissedSlotWithNoAttemptsSaysThereIsNoRecord() async {
        let harness = await harnessWithHistory([])

        #expect(slot(harness, daysAgo: 1).kind == .skipped)
        #expect(slot(harness, daysAgo: 1).caption
            == "Wed 31 Dec: missed: no record (Mac asleep, off, or BackMeUp not running)")
    }

    /// BackMeUp first ran on Sat 27 Dec: the slots that ended before then aren't blamed on it.
    @Test func slotsBeforeBackMeUpWasSetUpSaySo() async {
        let harness = harnessWithNetworkDisk()
        var history = BackupHistory()
        history.monitoringSince = Self.minutes(-5 * 24 * 60 + 15 * 60) // Sat 27 Dec 15:00
        harness.system.storedHistory = history
        harness.system.nextBackup = .fails(result: 19)
        await harness.restart()

        #expect(slot(harness, daysAgo: 6).caption == "Fri 26 Dec: before BackMeUp was set up")
        #expect(slot(harness, daysAgo: 6).kind == .skipped)
        #expect(slot(harness, daysAgo: 4).caption
            == "Sun 28 Dec: missed: no record (Mac asleep, off, or BackMeUp not running)")
    }

    @Test func theCurrentSlotShowsProgressWhileBackingUp() async {
        let harness = harnessWithNetworkDisk(snapshots: [Self.minutes(-15 * 60)])
        harness.system.nextBackup = .lasting(minutes: 600)
        harness.system.startedBackupPhase = "Copying"
        harness.at(minutes: 5) { $0.backupProgress = BackupProgress(fraction: 0.352, timeRemaining: 3 * 3600) }

        await harness.start()
        #expect(harness.scheduler.backupStrip.slots.last?.caption == "Thu 1 Jan: backing up")
        #expect(harness.scheduler.backupStrip.slots.last?.accessibilityLabel == "Thursday 1 January: backing up")

        await harness.advance(minutes: 5)
        #expect(harness.statusLine.contains("35.2%"))
        #expect(harness.scheduler.backupStrip.slots.last?.caption == "Thu 1 Jan: backing up: 35.2%")
        #expect(harness.scheduler.backupStrip.slots.last?.isCurrent == true)
        #expect(harness.scheduler.backupStrip.slots.last?.accessibilityLabel == "Thursday 1 January: backing up: 35.2%")
    }

    // MARK: How long reasons are kept

    /// A weekly network disk in the UK whose history BackMeUp has kept since well before the strip
    /// begins, with these attempts. Restarting records one more: a failed backup.
    func harnessWithWeeklyHistory(_ attempts: [BackupAttempt]) async -> SchedulerHarness {
        var calendar = SchedulerHarness.utcCalendar
        calendar.locale = Locale(identifier: "en_GB")
        let harness = harnessWithNetworkDisk(calendar: calendar)
        harness.system.storedSettings = BackupSettings(backupInterval: .init(count: 1, unit: .weeks), retryMinutes: 60)
        var history = BackupHistory(attempts: attempts)
        history.monitoringSince = Self.minutes(-120 * 24 * 60)
        harness.system.storedHistory = history
        harness.system.nextBackup = .fails(result: 19)
        await harness.restart()
        return harness
    }

    /// Hourly skips while away, every hour for the last 20 days.
    static let hourlySkips = (1...480).reversed().map { hour in
        let started = minutes(-Double(hour) * 60)
        return BackupAttempt(started: started, finished: started, outcome: .skipped(.notOnChosenNetwork))
    }

    @Test func theOldestMissedWeekStillSaysWhyAfterHundredsOfLaterAttempts() async {
        let harness = await harnessWithWeeklyHistory(
            [Self.attempt(day: 80, hour: 9, .failed(.couldNotStart))] + Self.hourlySkips // Mon 13 Oct 09:00
        )

        let first = harness.scheduler.backupStrip.slots.first
        #expect(first?.kind == .failed)
        #expect(first?.caption == "week of 13 Oct: failed, couldn't start Time Machine")
    }

    @Test func attemptsOlderThanTwelveWeeksAreDroppedButStillCountedSinceTheLastSuccess() async {
        let harness = await harnessWithWeeklyHistory([
            Self.attempt(day: 85, hour: 9, .failed(.couldNotStart)), // Wed 8 Oct, over 12 weeks ago
            Self.attempt(day: 83, hour: 9, .skipped(.onBattery)), // Fri 10 Oct, within them
        ])

        let saved = harness.system.storedHistory
        #expect(saved?.attempts.map(\.started) == [
            Self.minutes(-83 * 24 * 60 + 9 * 60),
            Self.minutes(0),
        ])
        #expect(saved?.sinceLastSuccess.failures == 2)
        #expect(saved?.sinceLastSuccess.skipCount == 1)
        #expect(harness.scheduler.backupStrip.slots.first?.caption == "week of 13 Oct: missed: no record (Mac asleep, off, or BackMeUp not running)")
    }

    @Test func neverMoreThanThreeThousandAttemptsAreKeptAndTheOldestGoFirst() async {
        let everyHalfHour = (2...3101).reversed().map { halfHour in // the last 64 days or so, up to an hour ago
            let started = Self.minutes(-Double(halfHour) * 30)
            return BackupAttempt(started: started, finished: started, outcome: .skipped(.onBattery))
        }

        let harness = await harnessWithWeeklyHistory(everyHalfHour)

        let saved = harness.system.storedHistory
        #expect(saved?.attempts.count == 3000)
        #expect(saved?.attempts.first?.started == Self.minutes(-3000 * 30)) // the 101 oldest dropped
        #expect(saved?.attempts.last?.started == Self.minutes(0))
        #expect(saved?.sinceLastSuccess.skipCount == 3100)
    }

    // MARK: Saved history

    @Test func historySavedByThisVersionLoadsUnchanged() async throws {
        let harness = harnessWithNetworkDisk()
        harness.system.nextBackup = .fails(result: 19)
        harness.at(minutes: 60) { $0.network = .none }
        harness.at(minutes: 120) {
            $0.network = FakeSystem.home
            $0.nextBackup = .succeeds
        }
        await harness.start()
        await harness.advance(minutes: 4 * 60)
        let history = try #require(harness.system.storedHistory)
        #expect(history.attempts.map(\.outcome) == [
            .failed(.result(19)), .skipped(.notOnChosenNetwork), .succeeded,
        ])
        let strip = harness.scheduler.backupStrip

        // As the real app saves and loads it.
        let saved = try JSONEncoder().encode(history)
        harness.system.storedHistory = try JSONDecoder().decode(BackupHistory.self, from: saved)
        await harness.restart()

        #expect(harness.system.storedHistory == history)
        #expect(harness.scheduler.backupStrip == strip)
        #expect(harness.scheduler.backupStrip.slots.last?.kind == .backedUp)
    }

    // MARK: Privacy

    /// Every kind of slot, and a backup in progress: none names the network, server or disk.
    @Test func noCaptionNamesTheNetworkServerOrDisk() async {
        let disk = Destination(kind: .network, id: "network-id", name: "Private Disk Name",
                               mountPoint: "/Volumes/Private Disk Name", serverHost: "private-server-host")
        let harness = SchedulerHarness()
        harness.system.destinationInfo = .configured(disk)
        harness.system.preferences = TimeMachinePreferences(autoBackup: false, destinations: [
            .init(id: "network-id", encryption: .encrypted, result: 0, snapshotDates: []),
        ])
        harness.system.storedSettings = BackupSettings(backupInterval: .init(count: 2, unit: .days), retryMinutes: 60)
        var history = BackupHistory(attempts: [
            Self.attempt(day: 6, hour: 9, .succeeded), // Fri 26 Dec; nothing due on the 27th
            Self.attempt(day: 4, hour: 9, .failed(.diskUnreachable(isNetworkDisk: true))),
            Self.attempt(day: 3, hour: 9, .skipped(.notOnChosenNetwork)),
            Self.attempt(day: 2, hour: 9, .skipped(.diskNotReachable)),
            Self.attempt(day: 1, hour: 9, .paused),
        ])
        history.monitoringSince = Self.minutes(-20 * 24 * 60)
        harness.system.storedHistory = history
        harness.system.network = .none
        var strips: [BackupStrip] = []

        await harness.restart() // skipped: no network
        strips.append(harness.scheduler.backupStrip)
        harness.system.network = FakeSystem.home
        harness.system.nextBackup = .lasting(minutes: 600)
        harness.at(minutes: 70) { $0.backupProgress = BackupProgress(fraction: 0.5) }
        await harness.advance(minutes: 75) // backing up
        strips.append(harness.scheduler.backupStrip)

        let kinds = Set(strips.flatMap { $0.slots.map(\.kind) }.map { "\($0)" })
        #expect(kinds == ["backedUp", "failed", "skipped", "nothingDue", "nothingYet"])
        #expect(strips.last?.slots.last?.caption.contains("backing up: 50") == true)
        let texts = strips.flatMap { strip in
            [strip.summary, strip.accessibilityLabel] + strip.slots.flatMap { [$0.caption, $0.accessibilityLabel] }
        }
        for name in ["Home", FakeSystem.homeRouter, "Private Disk Name", "/Volumes", "private-server-host"] {
            #expect(!texts.contains { $0.localizedCaseInsensitiveContains(name) }, "\(name)")
        }
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

    static var london: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/London")!
        return calendar
    }

    static func utc(_ string: String) -> Date {
        ISO8601DateFormatter().date(from: string)!
    }

    func captions(_ harness: SchedulerHarness) -> [String] {
        harness.scheduler.backupStrip.slots.map(\.caption)
    }
}
