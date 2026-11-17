import BackMeUpCore
import Testing

/// What BackMeUp does at the first launch after Sparkle has installed an update.
@MainActor
struct UpdateTests {
    func harnessWithNetworkDisk() -> SchedulerHarness {
        let harness = SchedulerHarness()
        harness.system.destinationInfo = ChecklistTests.networkDisk
        return harness
    }

    @Test func anUpdateAddsBackMeUpToLoginItemsAgain() async {
        let harness = harnessWithNetworkDisk()
        harness.system.appVersion = "1.0"
        await harness.start()
        #expect(harness.system.loginItemRegistrations == 1)

        harness.system.appVersion = "1.1"
        await harness.restart()
        #expect(harness.system.loginItemRegistrations == 2)

        await harness.restart()
        await harness.advance(minutes: 60)
        #expect(harness.system.loginItemRegistrations == 2)
    }

    @Test func ifTheLoginItemCantBeAddedAfterAnUpdateTheChecklistSaysSo() async {
        let harness = harnessWithNetworkDisk()
        await harness.start()
        #expect(harness.checklistShown == 1)

        harness.system.appVersion = "1.1"
        harness.system.loginItemStatus = .notRegistered
        harness.system.loginItemStatusAfterRegistering = .requiresApproval
        await harness.restart()

        #expect(harness.checklistShown == 2)
        #expect(harness.scheduler.checklist?.item(.opensAtLogin)?.state == .failed)
    }

    @Test func anUpdateWithEverythingStillSetUpDoesntShowTheChecklist() async {
        let harness = harnessWithNetworkDisk()
        await harness.start()

        harness.system.appVersion = "1.1"
        await harness.restart()
        await harness.advance(minutes: 60)

        #expect(harness.checklistShown == 1)
    }

    @Test func aVersionFromBeforeUpdatesExistedCountsAsAnUpdate() async {
        let harness = harnessWithNetworkDisk()
        harness.system.storedSetupState = SetupState(firstRunDone: true)
        harness.system.loginItemStatus = .notRegistered

        await harness.start()

        #expect(harness.system.loginItemRegistrations == 1)
        #expect(harness.system.storedSetupState?.lastLaunchedVersion == "1.0")
    }
}
