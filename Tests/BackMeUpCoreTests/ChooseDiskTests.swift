import Foundation
import Testing
import BackMeUpCore

/// Several Time Machine disks: the user chooses the one BackMeUp backs up to, and every check
/// and rule follows that disk.
@MainActor
@Suite("Choosing the backup disk")
struct ChooseDiskTests {
    /// An old unencrypted USB disk listed first, and a new encrypted network disk second.
    static let usbDisk = Destination(kind: .local, id: "usb-id", name: "Old Disk", mountPoint: "/Volumes/Old Disk")
    static let networkDisk = Destination(kind: .network, id: "network-id", name: "New Disk")
    static let otherDisk = Destination(kind: .network, id: "other-id", name: "Other Disk")

    func harnessWithTwoDisks() -> SchedulerHarness {
        let harness = SchedulerHarness()
        harness.system.destinationInfo = .several([Self.usbDisk, Self.networkDisk])
        harness.system.preferences = TimeMachinePreferences(autoBackup: false, destinations: [
            .init(id: "usb-id", encryption: .notEncrypted, result: 0),
            .init(id: "network-id", encryption: .encrypted, result: 0),
        ])
        return harness
    }

    // MARK: Nothing chosen

    @Test func withTwoDisksAndNoneChosenCheckOneAsksForAChoiceAndBackupsWait() async {
        let harness = harnessWithTwoDisks()

        await harness.start()
        await harness.backUpNow()
        await harness.advance(minutes: 3 * 60)

        let check = harness.scheduler.checklist?.item(.diskSetUp)
        #expect(check?.state == .failed)
        #expect(check?.sentence == "Choose which disk BackMeUp backs up to.")
        #expect(check?.diskChoices == [
            DiskChoice(id: "usb-id", label: "Old Disk (USB disk, not encrypted, never backed up)"),
            DiskChoice(id: "network-id", label: "New Disk (Network disk, encrypted, never backed up)"),
        ])
        #expect(check?.chosenDiskID == nil)
        #expect(check?.needsDiskChoice == true)
        #expect(harness.system.startedBackups.isEmpty)
        #expect(harness.scheduler.skipReason == .setupNotFinished)
        #expect(harness.statusLine == "Finish setting up: see the checklist")
        #expect(harness.checklistShown == 1)
    }

    // MARK: Labels

    /// Each label says when that disk was last backed up to, from its latest snapshot, so the
    /// disk someone stopped using stands out.
    @Test func eachDiskSaysWhenItWasLastBackedUpTo() async {
        let harness = SchedulerHarness()
        let unnamedDisk = Destination(kind: .local, id: "unnamed-id", name: nil)
        harness.system.destinationInfo = .several([Self.usbDisk, Self.networkDisk, unnamedDisk])
        harness.system.preferences = TimeMachinePreferences(autoBackup: false, destinations: [
            .init(id: "usb-id", encryption: .notEncrypted, result: 0,
                  snapshotDates: [harness.minutes(-4 * 30 * 24 * 60 - 90)]),
            .init(id: "network-id", encryption: .encrypted, result: 0,
                  snapshotDates: [harness.minutes(-3 * 24 * 60 - 5)]),
            .init(id: "unnamed-id", result: nil),
        ])

        await harness.start()

        #expect(harness.scheduler.diskChoices == [
            DiskChoice(id: "usb-id", label: "Old Disk (USB disk, not encrypted, last backup 4 months ago)"),
            DiskChoice(id: "network-id", label: "New Disk (Network disk, encrypted, last backup 3 days ago)"),
            DiskChoice(id: "unnamed-id", label: "Unnamed disk (USB disk, never backed up)"),
        ])
    }

    nonisolated static let ages: [(Double, String)] = [
        (0.5, "last backup less than a minute ago"),
        (1, "last backup 1 minute ago"),
        (45, "last backup 45 minutes ago"),
        (60, "last backup 1 hour ago"),
        (5 * 60 + 59, "last backup 5 hours ago"),
        (24 * 60, "last backup 1 day ago"),
        (59 * 24 * 60, "last backup 59 days ago"),
        (60 * 24 * 60, "last backup 2 months ago"),
        (400 * 24 * 60, "last backup 13 months ago"),
    ]

    /// Ages are measured on the scheduler's clock, not the wall clock.
    @Test(arguments: ages)
    func agesReadNaturally(minutesAgo: Double, expected: String) async {
        let harness = harnessWithTwoDisks()
        harness.system.preferences?.destinations[1].snapshotDates = [harness.minutes(-minutesAgo)]

        await harness.start()

        #expect(harness.scheduler.diskChoices.last?.label == "New Disk (Network disk, encrypted, \(expected))")
    }

    /// A label ages as the scheduler's clock moves on and the checklist is read again.
    @Test func aLabelAgesAsTimePasses() async {
        let harness = harnessWithTwoDisks()
        harness.system.preferences?.destinations[1].snapshotDates = [harness.minutes(-50)]
        await harness.start()

        await harness.advance(minutes: 20)
        await harness.scheduler.refreshStatus()

        #expect(harness.scheduler.diskChoices.last?.label == "New Disk (Network disk, encrypted, last backup 1 hour ago)")
    }

    // MARK: Choosing

    @Test func choosingTheEncryptedNetworkDiskPassesCheckThreeAndBacksUpToItOnAChosenNetwork() async {
        let harness = harnessWithTwoDisks()
        await harness.start()
        let shownBefore = harness.checklistShown

        await harness.scheduler.chooseDisk(id: "network-id")

        let checklist = harness.scheduler.checklist
        #expect(checklist?.item(.diskSetUp)?.state == .passed)
        #expect(checklist?.item(.diskSetUp)?.chosenDiskID == "network-id")
        #expect(checklist?.item(.diskSetUp)?.needsDiskChoice == false)
        #expect(checklist?.item(.diskEncrypted)?.state == .passed)
        #expect(checklist?.item(.networkChosen)?.state == .passed)
        #expect(harness.checklistShown == shownBefore)

        // The backup held back for setup starts within a minute, to the chosen disk only.
        await harness.advance(minutes: 1)
        #expect(harness.system.startedBackups == [harness.minutes(1)])
        #expect(harness.system.startedBackupDestinations == ["network-id"])
        #expect(harness.statusLine == "Last backup: today 00:21")
    }

    @Test func aChoiceMadeWhileTheChecklistIsBeingReadIsKept() async {
        let harness = harnessWithTwoDisks()
        await harness.start()
        let shownBefore = harness.checklistShown

        // The open checklist's refresh is part-way through reading when the user chooses.
        harness.system.pausesNextPreferencesRead = true
        let refresh = Task { await harness.scheduler.refreshStatus() }
        while !harness.system.isPreferencesReadPaused { await Task.yield() }
        await harness.scheduler.chooseDisk(id: "network-id")
        harness.system.resumePreferencesRead()
        await refresh.value

        let checklist = harness.scheduler.checklist
        let check = checklist?.item(.diskSetUp)
        #expect(check?.state == .passed)
        #expect(check?.chosenDiskID == "network-id")
        // The pop-up stays on the chosen disk rather than going back to "Choose a disk…".
        #expect(check?.needsDiskChoice == false)
        // Checks 3 and 6 are about the chosen disk too.
        #expect(checklist?.item(.diskEncrypted)?.state == .passed)
        #expect(checklist?.item(.networkChosen)?.state == .passed)
        #expect(harness.checklistShown == shownBefore)
    }

    // MARK: Status and progress

    nonisolated static let runningBackups: [(String?, String)] = [
        ("network-id", "First backup: 50.0%, about 2 minutes left"),
        // Time Machine doesn't say which disk: shown, as with one disk.
        (nil, "First backup: 50.0%, about 2 minutes left"),
        // Another disk: said so, with none of its progress.
        ("usb-id", "Time Machine is backing up to another disk"),
    ]

    /// Time Machine backing up by itself: only a backup to the chosen disk shows its progress.
    @Test(arguments: runningBackups)
    func statusAndProgressFollowTheChosenDisk(runningTo: String?, expected: String) async {
        let harness = harnessWithTwoDisks()
        await harness.start()
        await harness.scheduler.chooseDisk(id: "network-id")
        harness.system.timeMachineStatus = .running(destinationID: runningTo)
        harness.system.backupProgress = BackupProgress(fraction: 0.5, timeRemaining: 120)

        await harness.scheduler.refreshStatus()

        #expect(harness.statusLine == expected)
    }

    /// Someone starts a backup to the old disk from Time Machine's own menu. BackMeUp waits for it
    /// without counting it as its own, then backs up to the chosen disk once it's over.
    @Test func aBackupToAnotherDiskIsWaitedForAndNotCounted() async {
        let harness = harnessWithTwoDisks()
        harness.system.timeMachineStatus = .running(destinationID: "usb-id")
        harness.system.backupProgress = BackupProgress(fraction: 0.5, timeRemaining: 120)
        harness.at(minutes: 30) { $0.timeMachineStatus = .idle }
        await harness.start()

        await harness.scheduler.chooseDisk(id: "network-id")
        await harness.advance(minutes: 29)

        #expect(harness.system.startedBackups.isEmpty)
        #expect(harness.scheduler.history.attempts.isEmpty)
        #expect(harness.statusLine == "Time Machine is backing up to another disk")
        #expect(harness.nextBackupLine == "")

        // It ends: the backup due since the choice starts, to the chosen disk.
        await harness.advance(minutes: 1)
        #expect(harness.system.startedBackups == [harness.minutes(30)])
        #expect(harness.system.startedBackupDestinations == ["network-id"])
        #expect(harness.scheduler.history.attempts.map(\.outcome) == [.succeeded])
    }

    /// Back Up Now while Time Machine backs up to another disk is skipped, not a failure, and
    /// the backup still due starts once the other disk's backup ends.
    @Test func backUpNowWhileAnotherDiskBacksUpIsSkipped() async {
        let harness = harnessWithTwoDisks()
        await harness.start()
        await harness.scheduler.chooseDisk(id: "network-id")
        harness.system.timeMachineStatus = .running(destinationID: "usb-id")
        harness.at(minutes: 30) { $0.timeMachineStatus = .idle }

        await harness.backUpNow()

        #expect(harness.system.startedBackups.isEmpty)
        #expect(harness.scheduler.skipReason == .timeMachineBackingUpToAnotherDisk)
        #expect(harness.system.logLines.contains("Backup skipped: Time Machine is backing up to another disk"))
        #expect(harness.statusLine == "Time Machine is backing up to another disk")

        await harness.advance(minutes: 30)
        #expect(harness.system.startedBackups == [harness.minutes(30)])
        #expect(harness.system.startedBackupDestinations == ["network-id"])
        #expect(!harness.scheduler.history.attempts.contains { if case .failed = $0.outcome { true } else { false } })
    }

    /// With one disk nothing is chosen, so any backup Time Machine names is shown, as before.
    @Test func withOneDiskEveryRunningBackupShowsAsBefore() async {
        let harness = SchedulerHarness()
        harness.system.timeMachineStatus = .running(destinationID: "some-other-id")
        harness.system.backupProgress = BackupProgress(fraction: 0.5, timeRemaining: 120)

        await harness.start()

        #expect(harness.statusLine == "First backup: 50.0%, about 2 minutes left")
        #expect(harness.system.startedBackups.isEmpty)
    }

    /// A backup that falls due while another disk backs up starts as soon as that one ends.
    @Test func aBackupDueWhileAnotherDiskBacksUpStartsWhenItEnds() async {
        let harness = harnessWithTwoDisks()
        await harness.start()
        await harness.scheduler.chooseDisk(id: "network-id")
        await harness.advance(minutes: 1)
        #expect(harness.system.startedBackups == [harness.minutes(1)])

        // A day later the next backup is due, but Time Machine is busy with the old disk.
        harness.at(minutes: 23 * 60) { $0.timeMachineStatus = .running(destinationID: "usb-id") }
        harness.at(minutes: 25 * 60) { $0.timeMachineStatus = .idle }
        // The first backup ended at minute 21; stop a minute before the other disk's backup ends.
        await harness.advance(minutes: 25 * 60 - 22)
        #expect(harness.system.startedBackups == [harness.minutes(1)])
        #expect(harness.statusLine == "Time Machine is backing up to another disk")

        await harness.advance(minutes: 1)
        #expect(harness.system.startedBackups == [harness.minutes(1), harness.minutes(25 * 60)])
        // After the skip from before the choice, only BackMeUp's own two backups.
        #expect(harness.scheduler.history.attempts.map(\.outcome) == [.skipped(.setupNotFinished), .succeeded, .succeeded])
    }

    @Test func theChosenNetworkDiskFollowsTheNetworkRule() async {
        let harness = harnessWithTwoDisks()
        harness.system.network = .router(address: "02:00:00:00:00:09", wifiName: "Cafe")
        await harness.start()

        await harness.scheduler.chooseDisk(id: "network-id")
        await harness.advance(minutes: 1)

        #expect(harness.system.startedBackups.isEmpty)
        #expect(harness.scheduler.skipReason == .notOnChosenNetwork)
    }

    @Test func choosingTheUSBDiskWarnsAboutEncryptionAndNeedsNoNetwork() async {
        let harness = harnessWithTwoDisks()
        harness.system.network = .router(address: "02:00:00:00:00:09", wifiName: "Cafe")
        await harness.start()

        await harness.scheduler.chooseDisk(id: "usb-id")
        await harness.advance(minutes: 1)

        let checklist = harness.scheduler.checklist
        #expect(checklist?.item(.diskSetUp)?.state == .passed)
        #expect(checklist?.item(.diskEncrypted)?.state == .warning)
        #expect(checklist?.item(.networkChosen)?.state == .notNeeded)
        #expect(harness.system.startedBackupDestinations == ["usb-id"])
    }

    @Test func switchingToTheEncryptedDiskClearsCheckThreesWarning() async {
        let harness = harnessWithTwoDisks()
        await harness.start()
        await harness.scheduler.chooseDisk(id: "usb-id")
        #expect(harness.scheduler.checklist?.item(.diskEncrypted)?.state == .warning)
        let shownBefore = harness.checklistShown

        await harness.scheduler.chooseDisk(id: "network-id")
        #expect(harness.scheduler.checklist?.item(.diskEncrypted)?.state == .passed)

        await harness.advance(minutes: 90)
        #expect(harness.scheduler.checklist?.item(.diskEncrypted)?.state == .passed)
        #expect(harness.checklistShown == shownBefore)

        await harness.restart()
        #expect(harness.scheduler.checklist?.item(.diskEncrypted)?.state == .passed)
    }

    @Test func theChoiceIsKeptAcrossRestartsAndUpdates() async {
        let harness = harnessWithTwoDisks()
        await harness.start()
        await harness.scheduler.chooseDisk(id: "network-id")

        harness.system.appVersion = "2.0"
        await harness.restart()

        #expect(harness.scheduler.settings.destinationID == "network-id")
        #expect(harness.scheduler.checklist?.item(.diskSetUp)?.state == .passed)
        #expect(harness.system.startedBackupDestinations == ["network-id"])
    }

    @Test func savingTheOtherSettingsKeepsTheChoice() async {
        let harness = harnessWithTwoDisks()
        await harness.start()
        await harness.scheduler.chooseDisk(id: "network-id")

        // The Settings window saves its fields as new settings, without the disk.
        harness.scheduler.updateSettings(BackupSettings(backupInterval: BackupInterval(count: 2, unit: .days), retryMinutes: 60))

        #expect(harness.scheduler.settings.destinationID == "network-id")
        #expect(harness.system.storedSettings?.destinationID == "network-id")
    }

    @Test func settingsSavedBeforeDiskChoicesStillLoad() throws {
        let saved = #"{"backupInterval":{"count":2,"unit":"days"},"retryMinutes":30,"allowBackupsOnBattery":false}"#
        let settings = try JSONDecoder().decode(BackupSettings.self, from: Data(saved.utf8))
        #expect(settings.backupInterval == BackupInterval(count: 2, unit: .days))
        #expect(settings.destinationID == nil)

        var chosen = settings
        chosen.destinationID = "network-id"
        let reloaded = try JSONDecoder().decode(BackupSettings.self, from: JSONEncoder().encode(chosen))
        #expect(reloaded == chosen)
    }

    // MARK: A second disk is added

    /// The Mac has backed up to its only disk, the old USB disk.
    func harnessBackingUpToOneDisk() async -> SchedulerHarness {
        let harness = harnessWithTwoDisks()
        harness.system.destinationInfo = .configured(Self.usbDisk)
        await harness.start()
        return harness
    }

    @Test func addingASecondDiskKeepsBackingUpToTheFirstWithoutAnAlert() async {
        let harness = await harnessBackingUpToOneDisk()
        let shownBefore = harness.checklistShown
        harness.system.destinationInfo = .several([Self.usbDisk, Self.networkDisk])

        await harness.advance(minutes: 24 * 60)

        #expect(harness.scheduler.settings.destinationID == "usb-id")
        #expect(harness.system.storedSettings?.destinationID == "usb-id")
        let check = harness.scheduler.checklist?.item(.diskSetUp)
        #expect(check?.state == .passed)
        #expect(check?.sentence == "Time Machine has a new disk. BackMeUp still backs up to Old Disk.")
        #expect(check?.diskChoices.map(\.id) == ["usb-id", "network-id"])
        #expect(check?.chosenDiskID == "usb-id")
        #expect(check?.needsDiskChoice == false)
        #expect(harness.system.startedBackupDestinations == [nil, "usb-id"])
        #expect(harness.notifications.isEmpty)
        #expect(harness.system.ntfyMessages.isEmpty)
        #expect(harness.checklistShown == shownBefore)
        #expect(harness.system.logLines.contains("Time Machine has a new disk; still backing up to the disk BackMeUp used"))
    }

    @Test func afterASecondDiskIsAddedSwitchingToItWorks() async {
        let harness = await harnessBackingUpToOneDisk()
        harness.system.destinationInfo = .several([Self.usbDisk, Self.networkDisk])
        await harness.advance(minutes: 1)

        await harness.scheduler.chooseDisk(id: "network-id")
        await harness.advance(minutes: 24 * 60)

        let check = harness.scheduler.checklist?.item(.diskSetUp)
        #expect(check?.state == .passed)
        #expect(check?.sentence == "A Time Machine disk is set up.")
        #expect(check?.chosenDiskID == "network-id")
        #expect(harness.scheduler.checklist?.item(.diskEncrypted)?.state == .passed)
        #expect(harness.system.startedBackupDestinations == [nil, "network-id"])
    }

    @Test func aSecondDiskAddedWhileBackMeUpWasQuitKeepsBackingUpToTheFirst() async {
        let harness = await harnessBackingUpToOneDisk()
        harness.quit()
        harness.system.destinationInfo = .several([Self.usbDisk, Self.networkDisk])

        await harness.restart()
        await harness.advance(minutes: 24 * 60)

        #expect(harness.scheduler.settings.destinationID == "usb-id")
        let check = harness.scheduler.checklist?.item(.diskSetUp)
        #expect(check?.state == .passed)
        #expect(check?.sentence == "Time Machine has a new disk. BackMeUp still backs up to Old Disk.")
        #expect(check?.needsDiskChoice == false)
        #expect(harness.system.startedBackupDestinations == [nil, "usb-id"])
        #expect(harness.notifications.isEmpty)
    }

    @Test func theNewDiskNoteSurvivesARestartUntilTheUserChooses() async {
        let harness = await harnessBackingUpToOneDisk()
        harness.system.destinationInfo = .several([Self.usbDisk, Self.networkDisk])
        await harness.advance(minutes: 1)

        await harness.restart()
        #expect(harness.scheduler.checklist?.item(.diskSetUp)?.sentence
            == "Time Machine has a new disk. BackMeUp still backs up to Old Disk.")

        await harness.scheduler.chooseDisk(id: "network-id")
        #expect(harness.scheduler.checklist?.item(.diskSetUp)?.sentence == "A Time Machine disk is set up.")
        await harness.restart()
        #expect(harness.scheduler.checklist?.item(.diskSetUp)?.sentence == "A Time Machine disk is set up.")
    }

    @Test func removingADiskChosenAfterTheSwitchStillAsksRatherThanGoingBackToTheFirst() async {
        let harness = await harnessBackingUpToOneDisk()
        harness.system.destinationInfo = .several([Self.usbDisk, Self.networkDisk])
        await harness.advance(minutes: 1)
        await harness.scheduler.chooseDisk(id: "network-id")

        harness.system.destinationInfo = .several([Self.usbDisk, Self.otherDisk])
        await harness.advance(minutes: 1)

        #expect(harness.scheduler.settings.destinationID == nil)
        #expect(harness.scheduler.checklist?.item(.diskSetUp)?.state == .failed)
        #expect(harness.scheduler.checklist?.item(.diskSetUp)?.needsDiskChoice == true)
    }

    @Test func aSecondDiskFoundAtTheFirstLaunchAfterAnUpdateIsNotChosenForTheUser() async {
        let harness = await harnessBackingUpToOneDisk()
        harness.system.destinationInfo = .several([Self.usbDisk, Self.networkDisk])
        // Versions before this one never saved the disk they backed up to.
        harness.system.storedSetupState = SetupState(firstRunDone: true, lastLaunchedVersion: "1.0")

        harness.system.appVersion = "2.0"
        await harness.restart()

        #expect(harness.scheduler.settings.destinationID == nil)
        #expect(harness.scheduler.checklist?.item(.diskSetUp)?.state == .failed)
        #expect(harness.scheduler.checklist?.item(.diskSetUp)?.needsDiskChoice == true)
        #expect(harness.system.startedBackupDestinations == [nil])
    }

    @Test func setupStateSavedBeforeTheLastUsedDiskStillLoads() throws {
        let saved = #"{"firstRunDone":true,"lastLaunchedVersion":"1.0","networksAskedAbout":["02:00:00:00:00:09"]}"#
        let state = try JSONDecoder().decode(SetupState.self, from: Data(saved.utf8))
        #expect(state.firstRunDone)
        #expect(state.lastUsedDiskID == nil)
        #expect(state.chosenDiskRemoved == nil)
        #expect(state.newDiskAdded == nil)
    }

    // MARK: The chosen disk disappears

    @Test func removingTheChosenDiskWithTwoLeftClearsTheChoiceAndOpensTheChecklist() async {
        let harness = harnessWithTwoDisks()
        await harness.start()
        await harness.scheduler.chooseDisk(id: "network-id")
        await harness.advance(minutes: 30) // backs up to the network disk
        let shownBefore = harness.checklistShown
        harness.system.destinationInfo = .several([Self.usbDisk, Self.otherDisk])

        await harness.advance(minutes: 24 * 60)

        #expect(harness.scheduler.settings.destinationID == nil)
        #expect(harness.system.storedSettings?.destinationID == nil)
        #expect(harness.scheduler.checklist?.item(.diskSetUp)?.state == .failed)
        #expect(harness.checklistShown == shownBefore + 1)
        #expect(harness.system.startedBackupDestinations == ["network-id"])
        #expect(harness.system.logLines.contains("The chosen backup disk is no longer in Time Machine; asking which disk to back up to"))
    }

    @Test func checkOneSaysTheChosenDiskWasRemovedUntilTheUserChoosesAgain() async {
        let harness = harnessWithTwoDisks()
        await harness.start()
        await harness.scheduler.chooseDisk(id: "network-id")
        harness.system.destinationInfo = .several([Self.usbDisk, Self.otherDisk])

        await harness.advance(minutes: 60)
        #expect(harness.scheduler.checklist?.item(.diskSetUp)?.sentence
            == "The disk you chose is no longer in Time Machine. Choose a disk to start backups again.")
        #expect(harness.scheduler.checklist?.item(.diskSetUp)?.needsDiskChoice == true)

        await harness.scheduler.chooseDisk(id: "other-id")
        #expect(harness.scheduler.checklist?.item(.diskSetUp)?.sentence == "A Time Machine disk is set up.")
    }

    @Test func removingTheChosenDiskWithOneLeftPausesBackupsAndAsks() async {
        let harness = harnessWithTwoDisks()
        await harness.start()
        await harness.scheduler.chooseDisk(id: "network-id")
        await harness.advance(minutes: 30) // backs up to the network disk
        let shownBefore = harness.checklistShown
        harness.system.destinationInfo = .configured(Self.usbDisk)

        await harness.advance(minutes: 24 * 60)

        let check = harness.scheduler.checklist?.item(.diskSetUp)
        #expect(check?.state == .failed)
        #expect(check?.sentence == "The disk you chose is no longer in Time Machine. Choose a disk to start backups again.")
        #expect(check?.diskChoices.map(\.id) == ["usb-id"])
        #expect(check?.needsDiskChoice == true)
        #expect(harness.scheduler.skipReason == .setupNotFinished)
        #expect(harness.statusLine == "Finish setting up: see the checklist")
        #expect(harness.checklistShown == shownBefore + 1)
        #expect(harness.system.startedBackupDestinations == ["network-id"])
        #expect(harness.system.logLines.contains("The chosen backup disk is no longer in Time Machine; asking which disk to back up to"))
    }

    @Test func afterTheChosenDiskIsRemovedChoosingTheOneDiskLeftStartsBackupsAgain() async {
        let harness = harnessWithTwoDisks()
        await harness.start()
        await harness.scheduler.chooseDisk(id: "network-id")
        await harness.advance(minutes: 30)
        harness.system.destinationInfo = .configured(Self.usbDisk)
        await harness.advance(minutes: 60)

        await harness.scheduler.chooseDisk(id: "usb-id")
        await harness.advance(minutes: 24 * 60)

        let check = harness.scheduler.checklist?.item(.diskSetUp)
        #expect(check?.state == .passed)
        #expect(check?.sentence == "A Time Machine disk is set up.")
        #expect(check?.diskChoices == [])
        #expect(harness.system.startedBackupDestinations == ["network-id", "usb-id"])
    }

    @Test func theChosenDiskRemovedWithOneLeftStillAsksAfterARestart() async {
        let harness = harnessWithTwoDisks()
        await harness.start()
        await harness.scheduler.chooseDisk(id: "network-id")
        await harness.advance(minutes: 30)
        harness.system.destinationInfo = .configured(Self.usbDisk)
        await harness.advance(minutes: 1)

        await harness.restart()
        await harness.advance(minutes: 24 * 60)

        #expect(harness.scheduler.checklist?.item(.diskSetUp)?.state == .failed)
        #expect(harness.scheduler.checklist?.item(.diskSetUp)?.needsDiskChoice == true)
        #expect(harness.system.startedBackupDestinations == ["network-id"])
        #expect(harness.notifications.filter { $0.kind == .chooseDisk }.count == 1)
    }

    @Test func aRemovedChosenDiskNeverFallsBackToTheDiskBackMeUpUsedBefore() async {
        // BackMeUp backed up to the USB disk while it was the only one, then the user chose
        // the network disk from a different pair.
        let harness = await harnessBackingUpToOneDisk()
        harness.system.destinationInfo = .several([Self.networkDisk, Self.otherDisk])
        await harness.advance(minutes: 1)
        await harness.scheduler.chooseDisk(id: "network-id")

        harness.system.destinationInfo = .several([Self.usbDisk, Self.otherDisk])
        await harness.advance(minutes: 24 * 60)

        #expect(harness.scheduler.settings.destinationID == nil)
        #expect(harness.scheduler.checklist?.item(.diskSetUp)?.needsDiskChoice == true)
        #expect(harness.system.startedBackupDestinations == [nil])
    }

    @Test func whenTheDisksCannotBeReadTheChoiceIsKept() async {
        let harness = harnessWithTwoDisks()
        await harness.start()
        await harness.scheduler.chooseDisk(id: "network-id")
        harness.system.destinationInfo = .unknown

        await harness.advance(minutes: 1)

        #expect(harness.scheduler.settings.destinationID == "network-id")
    }

    // MARK: Listing the disks (--print-status)

    @Test func everyDiskIsListedEvenWhenThereIsOnlyOne() async {
        let harness = harnessWithTwoDisks()
        harness.system.destinationInfo = .configured(Self.usbDisk)

        await harness.start()

        #expect(harness.scheduler.disks == [
            ListedDisk(label: "Old Disk (USB disk, not encrypted, never backed up)", isBackupDisk: true),
        ])
    }

    @Test func theListSaysWhichOfSeveralDisksIsChosen() async {
        let harness = harnessWithTwoDisks()
        await harness.start()
        #expect(harness.scheduler.disks.map(\.isBackupDisk) == [false, false])

        await harness.scheduler.chooseDisk(id: "network-id")

        #expect(harness.scheduler.disks == [
            ListedDisk(label: "Old Disk (USB disk, not encrypted, never backed up)", isBackupDisk: false),
            ListedDisk(label: "New Disk (Network disk, encrypted, never backed up)", isBackupDisk: true),
        ])
    }

    @Test func withTheChosenDiskRemovedTheOneLeftIsNotTheBackupDiskUntilChosen() async {
        let harness = harnessWithTwoDisks()
        await harness.start()
        await harness.scheduler.chooseDisk(id: "network-id")
        harness.system.destinationInfo = .configured(Self.usbDisk)

        await harness.advance(minutes: 1)

        #expect(harness.scheduler.disks.map(\.isBackupDisk) == [false])
    }

    @Test func withOneDiskThereIsNothingToChoose() async {
        let harness = SchedulerHarness()
        harness.system.destinationInfo = .configured(Self.networkDisk)

        await harness.start()

        let check = harness.scheduler.checklist?.item(.diskSetUp)
        #expect(check?.state == .passed)
        #expect(check?.sentence == "A Time Machine disk is set up.")
        #expect(check?.diskChoices == [])
        #expect(check?.needsDiskChoice == false)
        #expect(harness.scheduler.diskChoices == [])
        #expect(harness.system.startedBackups == [harness.startDate])
        #expect(harness.system.startedBackupDestinations == [nil])
    }
}
