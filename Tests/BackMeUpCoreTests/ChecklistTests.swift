import Foundation
import Testing
import BackMeUpCore

/// The first-run checklist: what each check shows, and that backups wait for checks 1, 2 and 6.
@MainActor
@Suite("Checklist")
struct ChecklistTests {
    static let networkDisk = DestinationInfo.configured(Destination(kind: .network, id: "network-id"))

    func harnessWithNetworkDisk() -> SchedulerHarness {
        let harness = SchedulerHarness()
        harness.system.destinationInfo = Self.networkDisk
        return harness
    }

    // MARK: Gating

    @Test func withNoDiskSetUpNoBackupStartsAndTheStatusLinePointsToTheChecklist() async {
        let harness = SchedulerHarness()
        harness.system.destinationInfo = .notSetUp

        await harness.start()
        await harness.advance(minutes: 3 * 60)

        #expect(harness.system.startedBackups.isEmpty)
        #expect(harness.statusLine == "Finish setting up: see the checklist")
    }

    @Test func withAutomaticBackupsOnNothingStartsNotEvenBackUpNow() async {
        let harness = harnessWithNetworkDisk()
        harness.system.preferences = TimeMachinePreferences(autoBackup: true, destinations: [])

        await harness.start()
        await harness.backUpNow()
        await harness.advance(minutes: 3 * 60)

        #expect(harness.system.startedBackups.isEmpty)
        #expect(harness.statusLine == "Finish setting up: see the checklist")
        #expect(harness.nextBackupLine == "Backups start once setup is finished")
    }

    @Test func whenBackMeUpCannotTellWhetherADiskIsSetUpNothingStarts() async {
        let harness = SchedulerHarness()
        harness.system.destinationInfo = .unknown

        await harness.start()
        await harness.advance(minutes: 3 * 60)

        #expect(harness.system.startedBackups.isEmpty)
        #expect(harness.scheduler.checklist?.item(.diskSetUp)?.state == .unknown)
        #expect(harness.statusLine == "Finish setting up: see the checklist")
    }

    @Test func whenBackMeUpCannotTellWhetherAutomaticBackupsAreOffNothingStarts() async {
        let harness = harnessWithNetworkDisk()
        harness.system.preferences = nil

        await harness.start()
        await harness.advance(minutes: 3 * 60)

        #expect(harness.system.startedBackups.isEmpty)
        #expect(harness.scheduler.checklist?.item(.automaticBackupsOff)?.state == .unknown)
    }

    @Test func aNetworkDiskWithNoChosenNetworkWaitsUntilOneIsChosen() async {
        let harness = harnessWithNetworkDisk()
        harness.changeNetworks { $0.chosen.removeAll() }

        await harness.start()
        await harness.advance(minutes: 10)
        #expect(harness.system.startedBackups.isEmpty)

        harness.scheduler.allowCurrentNetwork(label: "Home")
        await harness.advance(minutes: 1)
        #expect(harness.system.startedBackups == [harness.minutes(11)])
    }

    @Test func allNetworksOnPassesTheNetworkCheck() async {
        let harness = harnessWithNetworkDisk()
        harness.changeNetworks { $0 = NetworkSettings(allNetworks: true) }

        await harness.start()

        #expect(harness.system.startedBackups == [harness.startDate])
        #expect(harness.scheduler.checklist?.item(.networkChosen)?.state == .passed)
    }

    @Test func aUSBDiskNeedsNoChosenNetwork() async {
        let harness = SchedulerHarness()
        harness.system.destinationInfo = .configured(Destination(kind: .local, id: "local-id", mountPoint: "/Volumes/Backup"))
        harness.changeNetworks { $0.chosen.removeAll() }

        await harness.start()

        #expect(harness.system.startedBackups == [harness.startDate])
        #expect(harness.scheduler.checklist?.item(.networkChosen)?.state == .notNeeded)
    }

    @Test func turningAutomaticBackupsOffStartsTheDueBackupWithinAMinute() async {
        let harness = harnessWithNetworkDisk()
        harness.system.preferences = TimeMachinePreferences(autoBackup: true, destinations: [])
        harness.at(minutes: 30) { $0.preferences?.autoBackup = false }

        await harness.start()
        await harness.advance(minutes: 30)

        #expect(harness.system.startedBackups == [harness.minutes(30)])
    }

    @Test func turningAutomaticBackupsBackOnStopsScheduledBackups() async {
        let harness = harnessWithNetworkDisk()
        await harness.start() // first backup succeeds at 00:20
        harness.at(minutes: 60) { $0.preferences?.autoBackup = true }

        await harness.advance(minutes: 3 * 24 * 60)

        #expect(harness.system.startedBackups == [harness.startDate])
        #expect(harness.statusLine == "Finish setting up: see the checklist")
    }

    @Test func theOverdueAlertSaysSetupIsNotFinished() async {
        let harness = harnessWithNetworkDisk()
        harness.system.preferences = TimeMachinePreferences(autoBackup: true, destinations: [])

        await harness.start()
        await harness.advance(minutes: 3 * 24 * 60)

        #expect(harness.notifications.map(\.body) == [
            "No backup for 3 days. BackMeUp's setup checklist hasn't been finished. Open it from the menu.",
        ])
    }

    // MARK: Each check

    func preferences(encryption: EncryptionState) -> TimeMachinePreferences {
        TimeMachinePreferences(autoBackup: false, destinations: [.init(id: "network-id", encryption: encryption, result: nil)])
    }

    @Test func anUnencryptedDiskIsOnlyAWarning() async {
        let harness = harnessWithNetworkDisk()
        harness.system.preferences = preferences(encryption: .notEncrypted)

        await harness.start()

        #expect(harness.scheduler.checklist?.item(.diskEncrypted)?.state == .warning)
        #expect(harness.system.startedBackups == [harness.startDate])
    }

    @Test func anEncryptedDiskPassesTheEncryptionCheck() async {
        let harness = harnessWithNetworkDisk()
        harness.system.preferences = preferences(encryption: .encrypted)

        await harness.start()

        #expect(harness.scheduler.checklist?.item(.diskEncrypted)?.state == .passed)
    }

    @Test func checksShowPlainSentences() async {
        let harness = harnessWithNetworkDisk()
        harness.system.preferences = preferences(encryption: .notEncrypted)

        await harness.start()

        #expect(harness.scheduler.checklist?.items.map(\.sentence) == [
            "A Time Machine disk is set up.",
            "Time Machine's automatic backups are off.",
            "Your backup disk isn't encrypted, so anyone who gets hold of it can read your files. You can choose to encrypt it in Time Machine settings.",
            "BackMeUp opens at login.",
            "Notifications are allowed.",
            "At least one network is chosen for backups.",
        ])
    }

    nonisolated static let loginItemProblems: [LoginItemStatus] = [.requiresApproval, .notRegistered, .notFound]

    @Test(arguments: loginItemProblems)
    func whenBackMeUpCannotOpenAtLoginCheck4SaysHowToAddItByHand(status: LoginItemStatus) async {
        let harness = harnessWithNetworkDisk()
        harness.system.loginItemStatus = status
        harness.system.loginItemStatusAfterRegistering = status

        await harness.start()

        let item = harness.scheduler.checklist?.item(.opensAtLogin)
        #expect(item?.state == .failed)
        #expect(item?.showsDirections == true)
        #expect(item?.directions == "Open System Settings, then General > Login Items & Extensions. Under \"Open at Login\", click + and choose BackMeUp in your Applications folder.")
        // Opening at login is not required for backups.
        #expect(harness.system.startedBackups == [harness.startDate])
    }

    @Test func notificationsNotYetAskedAboutAreRequestedFromCheck5() async {
        let harness = harnessWithNetworkDisk()
        harness.system.notificationPermission = .notDetermined

        await harness.start()
        let before = harness.scheduler.checklist?.item(.notificationsAllowed)
        #expect(before?.state == .failed)
        #expect(before?.action == .allowNotifications)
        #expect(before?.sentence == "Allow notifications, so that BackMeUp can tell you when backups stop.")

        await harness.scheduler.performAction(for: .notificationsAllowed)

        #expect(harness.system.notificationPermissionRequests == 1)
        #expect(harness.scheduler.checklist?.item(.notificationsAllowed)?.state == .passed)
        #expect(harness.system.openedSettings.isEmpty)
    }

    @Test func notificationsTurnedOffSendTheUserToNotificationSettings() async {
        let harness = harnessWithNetworkDisk()
        harness.system.notificationPermission = .denied

        await harness.start()
        await harness.scheduler.performAction(for: .notificationsAllowed)

        #expect(harness.scheduler.checklist?.item(.notificationsAllowed)?.state == .failed)
        #expect(harness.system.notificationPermissionRequests == 0)
        #expect(harness.system.openedSettings == [.notifications])
    }

    // MARK: Open Settings

    nonisolated static let panes: [(ChecklistItem.Check, SystemSettingsPane)] = [
        (.diskSetUp, .timeMachine),
        (.automaticBackupsOff, .timeMachine),
        (.diskEncrypted, .timeMachine),
        (.opensAtLogin, .loginItems),
        (.notificationsAllowed, .notifications),
    ]

    @Test(arguments: panes)
    func openSettingsOpensTheRightScreen(check: ChecklistItem.Check, pane: SystemSettingsPane) async {
        let harness = harnessWithNetworkDisk()
        await harness.start()

        await harness.scheduler.performAction(for: check)

        #expect(harness.system.openedSettings == [pane])
        #expect(harness.scheduler.checklist?.item(check)?.showsDirections == false)
    }

    @Test func theNetworkCheckOpensBackMeUpsOwnSettings() async {
        let harness = harnessWithNetworkDisk()
        await harness.start()

        #expect(harness.scheduler.checklist?.item(.networkChosen)?.action == .openBackMeUpSettings)
    }

    @Test func whenALinkFailsToOpenTheItemShowsPlainTextDirections() async {
        let harness = harnessWithNetworkDisk()
        harness.system.preferences = TimeMachinePreferences(autoBackup: true, destinations: [])
        harness.system.settingsLinksOpen = false
        await harness.start()

        await harness.scheduler.performAction(for: .automaticBackupsOff)

        let item = harness.scheduler.checklist?.item(.automaticBackupsOff)
        #expect(item?.showsDirections == true)
        #expect(item?.directions == "Open System Settings, then General > Time Machine. Click Options and set Back up frequency to Manually.")
    }

    // MARK: First run

    @Test func theFirstRunAddsBackMeUpToLoginItemsOnce() async {
        let harness = harnessWithNetworkDisk()
        harness.system.loginItemStatus = .notRegistered

        await harness.start()
        #expect(harness.system.loginItemRegistrations == 1)
        #expect(harness.scheduler.checklist?.item(.opensAtLogin)?.state == .passed)

        await harness.restart()
        await harness.advance(minutes: 60)
        #expect(harness.system.loginItemRegistrations == 1)
    }

    @Test func theChecklistIsShownOnFirstLaunch() async {
        let harness = harnessWithNetworkDisk()

        await harness.start()
        await harness.advance(minutes: 60)
        #expect(harness.checklistShown == 1)

        await harness.restart()
        #expect(harness.checklistShown == 1)
    }

    @Test func theChecklistComesBackWhenSomethingChangesLater() async {
        let harness = harnessWithNetworkDisk()
        harness.at(minutes: 60) { $0.preferences?.autoBackup = true }
        harness.at(minutes: 120) { $0.destinationInfo = .notSetUp }

        await harness.start() // the first backup runs until 00:20
        await harness.advance(minutes: 39)
        #expect(harness.checklistShown == 1)

        await harness.advance(minutes: 1)
        #expect(harness.checklistShown == 2)
        await harness.advance(minutes: 59)
        #expect(harness.checklistShown == 2)

        await harness.advance(minutes: 1)
        #expect(harness.checklistShown == 3)
    }

    @Test func aLaunchWithARequiredCheckFailingShowsTheChecklist() async {
        let harness = harnessWithNetworkDisk()
        await harness.start()
        harness.system.preferences?.autoBackup = true

        await harness.restart()

        #expect(harness.checklistShown == 2)
    }

    @Test func theChecklistSuggestsDoingTheFirstBackupOnPowerAndAtHome() async {
        let harness = harnessWithNetworkDisk()
        harness.system.nextBackup = .lasting(minutes: 60)
        await harness.start()

        #expect(harness.scheduler.checklistTip == "Do your first backup with your Mac plugged in, and at home or with the USB disk attached, so that it has the best chance of finishing.")

        await harness.advance(minutes: 60)
        #expect(harness.scheduler.checklistTip == nil)
    }
}
