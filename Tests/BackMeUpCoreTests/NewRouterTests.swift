import Foundation
import Testing
import BackMeUpCore

/// After a new router, the home network has a new address and stops counting as chosen. When
/// the backup disk is reachable on a network that isn't chosen, BackMeUp asks once whether to
/// allow backups on it.
@MainActor
@Suite("A new router")
struct NewRouterTests {
    /// Mounted: the Mac can reach it on this network.
    static let reachableNetworkDisk = DestinationInfo.configured(
        Destination(kind: .network, id: "network-id", mountPoint: "/Volumes/TimeMachine")
    )
    static let unmountedNetworkDisk = DestinationInfo.configured(Destination(kind: .network, id: "network-id"))
    nonisolated static let newRouter = NetworkReading.router(address: "02:00:00:00:00:0b", wifiName: "Home")
    nonisolated static let otherNetwork = NetworkReading.router(address: "02:00:00:00:00:0c", wifiName: nil)

    static let prompt = Alert(
        kind: .chooseNetwork,
        title: "Back up on this network?",
        body: "Your backup disk can be reached on this network, but it isn't one you chose, so backups are waiting. If it's your network with a new router, choose \u{201C}Allow backups on this network\u{201D} in the BackMeUp menu."
    )

    func harness(disk: DestinationInfo = reachableNetworkDisk, on network: NetworkReading = newRouter) -> SchedulerHarness {
        let harness = SchedulerHarness()
        harness.system.destinationInfo = disk
        harness.system.network = network
        return harness
    }

    @Test func withTheDiskReachableOnANetworkThatIsNotChosenBackMeUpAsksOnce() async {
        let harness = harness()

        await harness.start()
        await harness.advance(minutes: 2 * 24 * 60)

        #expect(harness.notifications.filter { $0.kind == .chooseNetwork } == [Self.prompt])
        #expect(harness.system.notifications.first { $0.alert.kind == .chooseNetwork }?.date == harness.startDate)
    }

    @Test func itAsksAgainOnlyForAnotherNetwork() async {
        let harness = harness()
        harness.at(minutes: 60) { $0.network = Self.otherNetwork }
        harness.at(minutes: 120) { $0.network = Self.newRouter }

        await harness.start()
        await harness.advance(minutes: 180)
        await harness.restart()

        #expect(harness.notifications.filter { $0.kind == .chooseNetwork }.count == 2)
    }

    @Test func itDoesNotAskWhenTheDiskCannotBeReached() async {
        let harness = harness(disk: Self.unmountedNetworkDisk)

        await harness.start()
        await harness.advance(minutes: 60)

        #expect(harness.notifications.isEmpty)
    }

    @Test func itDoesNotAskOnAChosenNetworkOrWithAllNetworksAllowed() async {
        let harness = harness(on: FakeSystem.home)
        await harness.start()
        harness.changeNetworks { $0.allNetworks = true }
        harness.system.network = Self.newRouter

        await harness.advance(minutes: 60)

        #expect(harness.notifications.isEmpty)
    }

    @Test func beforeAnyNetworkIsChosenTheChecklistAsksInstead() async {
        let harness = harness()
        harness.system.storedNetworks = nil
        await harness.restart()

        await harness.advance(minutes: 60)

        #expect(harness.notifications.isEmpty)
        #expect(harness.statusLine == "Finish setting up: see the checklist")
    }

    @Test func allowingTheNetworkLetsTheWaitingBackupStart() async {
        let harness = harness()
        await harness.start()
        #expect(harness.system.startedBackups.isEmpty)

        harness.scheduler.allowCurrentNetwork(label: "Home")
        await harness.advance(minutes: 1)

        #expect(harness.system.startedBackups == [harness.minutes(1)])
        #expect(harness.notifications.filter { $0.kind == .chooseNetwork }.count == 1)
    }

    @Test func theAskIsLoggedWithoutTheNetworksNameOrAddress() async {
        let harness = harness()

        await harness.start()

        #expect(harness.system.logLines.contains("Asked whether to allow backups on a network that isn't chosen"))
        for line in harness.system.logLines {
            #expect(!line.contains("02:00:00:00:00:0b"))
        }
    }
}
