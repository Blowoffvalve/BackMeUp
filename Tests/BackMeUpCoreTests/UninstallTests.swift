import Foundation
import Testing
import BackMeUpCore

/// Uninstall…: removes BackMeUp's login item, settings and Keychain items, and never touches
/// Time Machine's settings or backups.
@MainActor
@Suite("Uninstall")
struct UninstallTests {
    static let networkDisk = DestinationInfo.configured(Destination(kind: .network, id: "network-id"))

    /// A Mac where BackMeUp has been in use: a backup done, settings changed, ntfy set up.
    func harnessInUse() async -> SchedulerHarness {
        let harness = SchedulerHarness()
        harness.system.destinationInfo = Self.networkDisk
        harness.scheduler.updateNtfy(NtfySettings(server: "https://ntfy.example", topic: "example-topic", token: "example-token"))
        harness.changeSettings { $0.allowBackupsOnBattery = false }
        await harness.start()
        return harness
    }

    @Test func removesTheLoginItemSettingsAndEveryKeychainItem() async {
        let harness = await harnessInUse()
        #expect(harness.system.secrets.count == Secret.allCases.count)
        #expect(harness.system.storedHistory != nil)

        harness.scheduler.uninstall()

        #expect(harness.system.loginItemStatus == .notRegistered)
        #expect(harness.system.loginItemUnregistrations == 1)
        #expect(harness.system.secrets.isEmpty)
        #expect(harness.system.storedHistory == nil)
        #expect(harness.system.storedSettings == nil)
        #expect(harness.system.storedNetworks == nil)
        #expect(harness.system.storedSetupState == nil)
        #expect(harness.system.storedNtfyServer == nil)
    }

    @Test func leavesTimeMachineAloneAndStartsNoBackupAfterwards() async {
        let harness = await harnessInUse()
        harness.system.preferences = TimeMachinePreferences(
            autoBackup: false,
            destinations: [.init(id: "network-id", encryption: .encrypted, result: 0)]
        )
        let preferences = harness.system.preferences
        #expect(harness.system.startedBackups.count == 1)
        let ntfySent = harness.system.ntfyMessages.count

        harness.scheduler.uninstall()
        // The app stays open while the reminder shows; a backup would be due by now.
        await harness.advance(minutes: 3 * 24 * 60)
        harness.scheduler.backUpNow()
        await harness.advance(minutes: 1)
        harness.quit()

        #expect(harness.system.startedBackups.count == 1)
        #expect(harness.system.preferences == preferences)
        #expect(harness.system.destinationInfo == Self.networkDisk)
        #expect(harness.notifications.isEmpty)
        #expect(harness.system.ntfyMessages.count == ntfySent)
        #expect(!harness.system.isPreventingIdleSleep)
    }

    @Test func savesNothingAgainAfterUninstalling() async {
        let harness = await harnessInUse()

        harness.scheduler.uninstall()
        await harness.advance(minutes: 3 * 24 * 60)
        harness.changeSettings { $0.retryMinutes = 30 }
        harness.changeNetworks { $0.allNetworks = true }
        harness.scheduler.allowCurrentNetwork(label: "Somewhere")
        harness.scheduler.updateNtfy(NtfySettings(server: "https://ntfy.example", topic: "example-topic", token: "example-token"))
        harness.scheduler.registerLoginItem()
        let ntfySent = harness.system.ntfyMessages.count
        _ = await harness.scheduler.sendTestMessage()
        harness.quit()

        #expect(harness.system.ntfyMessages.count == ntfySent)
        #expect(harness.system.loginItemRegistrations == 1)
        #expect(harness.system.loginItemStatus == .notRegistered)
        #expect(harness.system.secrets.isEmpty)
        #expect(harness.system.storedHistory == nil)
        #expect(harness.system.storedSettings == nil)
        #expect(harness.system.storedNetworks == nil)
        #expect(harness.system.storedSetupState == nil)
        #expect(harness.system.storedNtfyServer == nil)
    }

    @Test func aBackupRunningWhenUninstallingIsLeftToTimeMachineAndNotRecorded() async {
        let harness = SchedulerHarness()
        harness.system.destinationInfo = Self.networkDisk
        harness.system.nextBackup = .lasting(minutes: 60)
        await harness.start()
        await harness.advance(minutes: 10)
        #expect(harness.system.isPreventingIdleSleep)

        harness.scheduler.uninstall()
        #expect(!harness.system.isPreventingIdleSleep)
        await harness.advance(minutes: 60)

        #expect(harness.system.startedBackups.count == 1)
        #expect(harness.system.storedHistory == nil)
        #expect(!harness.system.isPreventingIdleSleep)
        #expect(!harness.scheduler.isBackingUp)
    }

    @Test func deletesSettingsAgainAsItQuitsInCaseSomethingSavedOneMeanwhile() async {
        let harness = await harnessInUse()
        harness.scheduler.uninstall()

        // Something outside the scheduler (macOS saving the menu bar icon's position, say) writes.
        harness.system.storedNtfyServer = "https://ntfy.example"
        harness.quit()

        #expect(harness.system.storedNtfyServer == nil)
    }

    @Test func quittingWithoutUninstallingKeepsSettings() async {
        let harness = await harnessInUse()

        harness.quit()

        #expect(harness.system.storedSettings != nil)
        #expect(harness.system.secrets.count == Secret.allCases.count)
    }

    @Test func theReminderButtonOpensTimeMachineSettings() async {
        let harness = await harnessInUse()
        harness.scheduler.uninstall()

        #expect(harness.scheduler.openTimeMachineSettings())
        #expect(harness.system.openedSettings == [.timeMachine])
        #expect(harness.system.preferences?.autoBackup == false)
    }

    @Test func saysWhenTimeMachineSettingsCouldntBeOpened() async {
        let harness = await harnessInUse()
        harness.scheduler.uninstall()
        harness.system.settingsLinksOpen = false

        #expect(!harness.scheduler.openTimeMachineSettings())
        #expect(harness.system.openedSettings.isEmpty)
    }
}
