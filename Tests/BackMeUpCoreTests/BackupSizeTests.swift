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

    /// Scripts the next backup BackMeUp starts to copy `totalBytes` in total and end with
    /// `exitCode` and `result` after 30 minutes.
    func scriptBackup(_ harness: SchedulerHarness, totalBytes: Int64,
                      exitCode: Int32? = 0, result: Int? = 0) {
        harness.system.nextBackup = .lasting(minutes: 30, exitCode: exitCode, result: result)
        harness.system.startedBackupPhase = "Copying"
        harness.system.backupProgress = BackupProgress(fraction: 0.5, totalBytes: totalBytes)
    }

    func today(_ harness: SchedulerHarness) -> BackupStrip.Slot? {
        harness.scheduler.backupStrip.slots.last
    }

    @Test func afterABackupFinishesItsDotSaysHowMuchItCopied() async {
        let harness = harnessWithNetworkDisk()
        scriptBackup(harness, totalBytes: 3_200_000_000)

        await harness.start() // backs up 00:00 to 00:30
        await harness.advance(minutes: 60)

        #expect(today(harness)?.caption == "Thu 1 Jan: backed up 00:30, 3.2 GB copied")
        #expect(today(harness)?.accessibilityLabel == "Thursday 1 January: backed up 00:30, 3.2 GB copied")
    }

    @Test func aBackupDatedByTimeMachineLongBeforeItFinishedShowsItsSizeOnBothDots() async {
        // Time Machine may date a backup when it began, not when it finished: on a long backup
        // its date and BackMeUp's finish time can be in different slots.
        let harness = harnessWithNetworkDisk()
        harness.changeSettings { $0.backupInterval = .init(count: 1, unit: .hours) }
        scriptBackup(harness, totalBytes: 3_200_000_000)
        harness.system.nextBackup = .lasting(minutes: 90)
        harness.system.nextBackup.snapshotMinutesAfterStart = 1

        await harness.start() // backs up 00:00 to 01:30, dated 00:01 by Time Machine
        await harness.advance(minutes: 100)

        #expect(captions(harness).suffix(2) == [
            "Thu 1 Jan 00:00: backed up 00:01, 3.2 GB copied",
            "Thu 1 Jan 01:00: backed up 01:30, 3.2 GB copied",
        ])
    }

    @Test func aBackupMinutesBeforeOneWithASizeDoesNotTakeIt() async {
        // A backup made while BackMeUp wasn't open, three minutes before BackMeUp's own began.
        let harness = harnessWithNetworkDisk(snapshots: [Self.minutes(-3)])
        harness.system.storedHistory = BackupHistory(lastSuccess: Self.minutes(-60))
        harness.changeSettings { $0.backupInterval = .init(count: 1, unit: .hours) }
        scriptBackup(harness, totalBytes: 3_200_000_000)
        harness.system.nextBackup = .lasting(minutes: 5)
        harness.system.nextBackup.snapshotMinutesAfterStart = 0

        await harness.restart() // backs up 00:00 to 00:05, dated 00:00 by Time Machine
        await harness.advance(minutes: 10)

        #expect(captions(harness).suffix(2) == [
            "Wed 31 Dec 23:00: backed up 23:57",
            "Thu 1 Jan 00:00: backed up 00:05, 3.2 GB copied",
        ])
    }

    @Test func aFailedBackupKeepsNoSize() async {
        let harness = harnessWithNetworkDisk()
        scriptBackup(harness, totalBytes: 3_200_000_000, result: 19)
        harness.at(minutes: 40) { system in
            system.nextBackup = .succeeds // 20 minutes, never seen copying
            system.backupProgress = nil
        }
        harness.changeSettings { $0.retryMinutes = 60 }

        await harness.start() // fails 00:00 to 00:30, then backs up 01:30 to 01:50
        await harness.advance(minutes: 3 * 60)

        #expect(today(harness)?.caption == "Thu 1 Jan: backed up 01:50")
    }

    @Test func aBackupTimeMachineStartedItselfKeepsOne() async {
        let harness = harnessWithNetworkDisk(snapshots: [Self.minutes(-60)])
        harness.system.storedHistory = BackupHistory(lastSuccess: Self.minutes(-60)) // nothing due
        harness.system.timeMachineStatus = .running(destinationID: "network-id", phase: "Copying")
        harness.system.backupProgress = BackupProgress(fraction: 0.5, totalBytes: 840_000_000)
        harness.at(minutes: 30) { system in
            system.timeMachineStatus = .idle
            system.preferences?.destinations[0].snapshotDates.append(Self.minutes(29))
        }

        await harness.restart()
        await harness.advance(minutes: 60)

        #expect(harness.system.startedBackups.isEmpty)
        #expect(today(harness)?.caption == "Thu 1 Jan: backed up 00:29, 840 MB copied")
    }

    @Test func openingTheMenuAsTimeMachinesOwnBackupEndsShowsItsSize() async {
        let harness = harnessWithNetworkDisk(snapshots: [Self.minutes(-60)])
        harness.system.storedHistory = BackupHistory(lastSuccess: Self.minutes(-60)) // nothing due
        harness.system.timeMachineStatus = .running(destinationID: "network-id", phase: "Copying")
        harness.system.backupProgress = BackupProgress(fraction: 0.5, totalBytes: 840_000_000)
        await harness.restart()
        await harness.advance(minutes: 29)

        // It ends between ticks, and the menu is opened before the next one.
        harness.system.timeMachineStatus = .idle
        harness.system.preferences?.destinations[0].snapshotDates.append(Self.minutes(29))
        await harness.scheduler.refreshStatus()

        #expect(today(harness)?.caption == "Thu 1 Jan: backed up 00:29, 840 MB copied")
    }

    @Test func aBackupTimeMachineStartedItselfThatWasStoppedKeepsNone() async {
        let harness = harnessWithNetworkDisk(snapshots: [Self.minutes(-60)])
        harness.system.storedHistory = BackupHistory(lastSuccess: Self.minutes(-60)) // nothing due
        harness.system.timeMachineStatus = .running(destinationID: "network-id", phase: "Copying")
        harness.system.backupProgress = BackupProgress(fraction: 0.5, totalBytes: 840_000_000)
        harness.at(minutes: 30) { $0.timeMachineStatus = .idle } // no new backup on the disk
        harness.at(minutes: 50) { $0.preferences?.destinations[0].snapshotDates.append(Self.minutes(50)) }

        await harness.restart()
        await harness.advance(minutes: 60)

        #expect(today(harness)?.caption == "Thu 1 Jan: backed up 00:50")
    }

    @Test func aBackupStoppedAfterLaunchingMidBackupKeepsNone() async {
        // BackMeUp launches while Time Machine is already copying, so it first sees the backup
        // before it has read the disk's backups.
        let harness = harnessWithNetworkDisk(snapshots: [Self.minutes(-60)])
        harness.system.storedHistory = BackupHistory(lastSuccess: Self.minutes(-60)) // nothing due
        harness.system.timeMachineStatus = .running(destinationID: "network-id", phase: "Copying")
        harness.system.backupProgress = BackupProgress(fraction: 0.5, totalBytes: 840_000_000)
        harness.at(minutes: 30) { $0.timeMachineStatus = .idle } // stopped: no new backup

        await harness.restart()
        await harness.advance(minutes: 60)

        #expect(captions(harness).filter { $0.contains("copied") } == [])
        #expect(harness.system.storedHistory?.sizes ?? [] == [])
    }

    @Test func aResumedFirstBackupShowsWhatTheFinishingRunCopied() async {
        let harness = harnessWithNetworkDisk()
        harness.changeSettings { $0.retryMinutes = 60 }
        // The first run stops with no error result: paused.
        scriptBackup(harness, totalBytes: 250_000_000_000, result: nil)
        harness.at(minutes: 40) { system in
            system.nextBackup = .lasting(minutes: 30)
            system.backupProgress = BackupProgress(fraction: 0.6, totalBytes: 120_000_000_000)
        }

        await harness.start() // paused 00:00 to 00:30, resumes 01:30 to 02:00
        #expect(harness.system.storedHistory?.attempts.last?.outcome != .succeeded)
        await harness.advance(minutes: 3 * 60)

        #expect(harness.system.storedHistory?.attempts.map(\.outcome) == [.paused, .succeeded])
        #expect(today(harness)?.caption == "Thu 1 Jan: backed up 02:00, 120 GB copied")
    }

    @Test func theLastTotalSeenWhileCopyingIsKept() async {
        let harness = harnessWithNetworkDisk()
        scriptBackup(harness, totalBytes: 3_000_000_000)
        harness.at(minutes: 10) { $0.backupProgress = BackupProgress(fraction: 0.7, totalBytes: 3_400_000_000) }
        harness.at(minutes: 25) { $0.startedBackupPhase = "ThinningPostBackup" }

        await harness.start()
        await harness.advance(minutes: 60)

        #expect(today(harness)?.caption == "Thu 1 Jan: backed up 00:30, 3.4 GB copied")
    }

    @Test func sizesSurviveARestart() async {
        let harness = harnessWithNetworkDisk()
        scriptBackup(harness, totalBytes: 3_200_000_000)
        await harness.start()
        await harness.advance(minutes: 60)

        await harness.restart()

        #expect(today(harness)?.caption == "Thu 1 Jan: backed up 00:30, 3.2 GB copied")
    }

    @Test func aBackupWithNoKnownSizeKeepsItsPlainCaption() async {
        let harness = harnessWithNetworkDisk(snapshots: [Self.minutes(-24 * 60 + 9 * 60 + 14)]) // Wed 31 Dec 09:14
        scriptBackup(harness, totalBytes: 3_200_000_000)

        await harness.start()
        await harness.advance(minutes: 60)

        #expect(captions(harness).suffix(2) == [
            "Wed 31 Dec: backed up 09:14",
            "Thu 1 Jan: backed up 00:30, 3.2 GB copied",
        ])
    }

    @Test func withTwoBackupsInOneSlotTheLatestOnesSizeIsShown() async {
        let harness = harnessWithNetworkDisk()
        harness.changeSettings { $0.backupInterval = .init(count: 1, unit: .weeks) }
        scriptBackup(harness, totalBytes: 3_200_000_000)
        harness.at(minutes: 40) { $0.backupProgress = BackupProgress(fraction: 0.5, totalBytes: 840_000_000) }

        await harness.start() // backs up 00:00 to 00:30
        await harness.advance(minutes: 40)
        await harness.backUpNow() // backs up 00:40 to 01:10
        await harness.advance(minutes: 60)

        #expect(today(harness)?.caption.hasSuffix(": backed up Thu 1 Jan 01:10, 840 MB copied") == true)
    }

    @Test func aBackupToAnotherDiskRecordsNothing() async {
        let harness = SchedulerHarness()
        let usbDisk = Destination(kind: .local, id: "usb-id", name: "Old Disk", mountPoint: "/Volumes/Old Disk")
        let networkDisk = Destination(kind: .network, id: "network-id", name: "New Disk")
        harness.system.destinationInfo = .several([usbDisk, networkDisk])
        harness.system.preferences = TimeMachinePreferences(autoBackup: false, destinations: [
            .init(id: "usb-id", encryption: .notEncrypted, result: 0, snapshotDates: []),
            .init(id: "network-id", encryption: .encrypted, result: 0, snapshotDates: [Self.minutes(-60)]),
        ])
        harness.system.storedHistory = BackupHistory(lastSuccess: Self.minutes(-60)) // nothing due
        harness.system.timeMachineStatus = .running(destinationID: "usb-id", phase: "Copying")
        harness.system.backupProgress = BackupProgress(fraction: 0.5, totalBytes: 840_000_000)
        // Time Machine finishes the other disk's backup just as one to the chosen disk lands.
        harness.at(minutes: 30) { system in
            system.timeMachineStatus = .idle
            system.preferences?.destinations[0].snapshotDates.append(Self.minutes(29))
            system.preferences?.destinations[1].snapshotDates.append(Self.minutes(29))
        }

        await harness.restart()
        await harness.scheduler.chooseDisk(id: "network-id")
        await harness.advance(minutes: 60)

        #expect(captions(harness).last == "Thu 1 Jan: backed up 00:29")
        #expect(harness.system.storedHistory?.sizes ?? [] == [])
    }

    @Test func sizesOlderThanTwelveWeeksAreDropped() async {
        let harness = harnessWithNetworkDisk()
        let old = Self.minutes(-85 * 24 * 60) // over 12 weeks ago
        let recent = Self.minutes(-83 * 24 * 60) // within them
        harness.system.storedHistory = BackupHistory(
            lastSuccess: recent,
            attempts: [
                BackupAttempt(started: old, finished: old, outcome: .succeeded),
                BackupAttempt(started: recent, finished: recent, outcome: .succeeded),
            ],
            sizes: [BackupSize(finished: old, bytes: 1_000_000_000), BackupSize(finished: recent, bytes: 2_000_000_000)]
        )
        scriptBackup(harness, totalBytes: 3_200_000_000)

        await harness.restart()
        await harness.advance(minutes: 60)

        #expect(harness.system.storedHistory?.sizes?.map(\.bytes) == [2_000_000_000, 3_200_000_000])
    }

    /// Minutes after the harness's start date, Thu 1 Jan 2026 00:00 UTC.
    static func minutes(_ minutes: Double) -> Date {
        SchedulerHarness.startDate.addingTimeInterval(minutes * 60)
    }

    func captions(_ harness: SchedulerHarness) -> [String] {
        harness.scheduler.backupStrip.slots.map(\.caption)
    }
}
