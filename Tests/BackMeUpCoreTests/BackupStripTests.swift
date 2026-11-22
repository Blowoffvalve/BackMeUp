import Foundation
import Testing
import BackMeUpCore

/// The strip of dots under the menu's status line: which recent days were backed up.
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
        #expect(strip.slots.first?.caption == "Fri 19 Dec: missed")
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
            "Thu 1 Jan: nothing yet",
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
            "Tue 30 Dec: missed",
            "Wed 31 Dec: missed",
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

        #expect(captions(harness).suffix(2) == ["Wed 31 Dec: missed", "Thu 1 Jan: nothing yet"])
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
        #expect(strip.slots.first?.caption == "Wed 31 Dec 04:00: missed")
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
        #expect(strip.slots.first?.caption == "\(firstWeek): missed")
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
        ].map { "\($0): missed" } + ["Sun 25 Oct 06:00: nothing yet"])
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
        ].map { "\($0): missed" } + [
            "Sun 29 Mar: backed up 23:30",
            "Mon 30 Mar: missed",
            "Tue 31 Mar: missed",
            "Wed 1 Apr: nothing yet",
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
            "Sun 28 Dec: missed",
            "Mon 29 Dec: backed up 09:00",
            "Tue 30 Dec: nothing due",
            "Wed 31 Dec: nothing due",
            "Thu 1 Jan: missed",
            "Fri 2 Jan: nothing yet",
        ])
        #expect(harness.scheduler.backupStrip.slots.suffix(5).map(\.kind) == [
            .backedUp, .nothingDue, .nothingDue, .skipped, .nothingYet,
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
            "Wed 31 Dec: missed",
            "Thu 1 Jan: nothing yet",
        ])
    }

    /// The current slot isn't missed while a backup is still due later in it.
    @Test func theCurrentSlotSaysNothingYetUntilABackupLands() async {
        let harness = harnessWithNetworkDisk(snapshots: [
            Self.minutes(-15 * 60), // Wed 31 Dec 09:00
        ])
        harness.system.nextBackup = .fails(result: 19)

        await harness.start() // fails 00:00 to 00:20
        #expect(harness.scheduler.backupStrip.slots.last?.caption == "Thu 1 Jan: nothing yet")
        #expect(harness.scheduler.backupStrip.slots.last?.kind == .nothingYet)
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
            "Tue 30 Dec: missed",
            "Wed 31 Dec: missed",
            "Thu 1 Jan: nothing yet",
        ])

        harness.changeSettings { $0.backupInterval = BackupInterval(count: 3, unit: .days) }
        #expect(captions(harness).suffix(3) == [
            "Tue 30 Dec: nothing due",
            "Wed 31 Dec: nothing due",
            "Thu 1 Jan: nothing yet",
        ])

        harness.changeSettings { $0.backupInterval = BackupInterval(count: 4, unit: .hours) }
        #expect(captions(harness).suffix(1) == ["Thu 1 Jan 00:00: nothing yet"])
        #expect(harness.scheduler.backupStrip.slots.last?.kind == .nothingYet)
        #expect(harness.scheduler.backupStrip.slots.last?.isCurrent == true)
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
