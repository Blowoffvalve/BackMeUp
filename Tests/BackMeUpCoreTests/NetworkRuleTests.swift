import Foundation
import Testing
import BackMeUpCore

/// Network disks back up only on chosen networks. `FakeSystem` starts on a chosen network, "Home".
@MainActor
@Suite("Chosen networks")
struct NetworkRuleTests {
    static let networkDisk = DestinationInfo.configured(Destination(kind: .network, id: "network-id"))
    static let pluggedInLocalDisk = DestinationInfo.configured(
        Destination(kind: .local, id: "local-id", mountPoint: "/Volumes/Backup Disk")
    )
    nonisolated static let cafe = NetworkReading.router(address: "02:00:00:00:00:0c", wifiName: "Cafe")

    func harness(on network: NetworkReading, disk: DestinationInfo = networkDisk) -> SchedulerHarness {
        let harness = SchedulerHarness()
        harness.system.destinationInfo = disk
        harness.system.network = network
        return harness
    }

    // MARK: The rule

    @Test func onAChosenNetworkANetworkDiskBacksUp() async {
        let harness = harness(on: FakeSystem.home)

        await harness.start()

        #expect(harness.system.startedBackups == [harness.startDate])
    }

    @Test func onANetworkThatIsNotChosenTheBackupWaits() async {
        let harness = harness(on: Self.cafe)

        await harness.start()

        #expect(harness.system.startedBackups.isEmpty)
        #expect(harness.statusLine == "Waiting for a chosen network")
        #expect(harness.scheduler.skipReason == .notOnChosenNetwork)
    }

    @Test func theBackupStartsAsSoonAsTheMacIsBackOnAChosenNetwork() async {
        let harness = harness(on: Self.cafe)
        harness.at(minutes: 10) { $0.network = FakeSystem.home }

        await harness.start()
        await harness.advance(minutes: 10)

        #expect(harness.system.startedBackups == [harness.minutes(10)])
        #expect(harness.scheduler.skipReason == nil)
    }

    @Test func comingHomeDoesNotStartABackupThatIsNotDue() async {
        let harness = harness(on: FakeSystem.home)
        await harness.start() // succeeds at 00:20
        harness.at(minutes: 60) { $0.network = Self.cafe }
        harness.at(minutes: 120) { $0.network = FakeSystem.home }

        await harness.advance(minutes: 180)

        #expect(harness.system.startedBackups == [harness.startDate])
    }

    @Test func theSameRouterOverEthernetCountsAsTheSameNetwork() async {
        // Chosen over Wi-Fi as "Home"; over Ethernet the same router has no Wi-Fi name.
        let harness = harness(on: .router(address: FakeSystem.homeRouter, wifiName: nil))

        await harness.start()

        #expect(harness.system.startedBackups == [harness.startDate])
    }

    @Test(arguments: [NetworkReading.none])
    func noPhysicalNetworkIsNotAChosenNetwork(network: NetworkReading) async {
        // What a VPN-only default route, or no connection at all, reads as.
        let harness = harness(on: network)

        await harness.start()

        #expect(harness.system.startedBackups.isEmpty)
        #expect(harness.statusLine == "Waiting for a chosen network")
        #expect(harness.scheduler.skipReason == .notOnChosenNetwork)
    }

    @Test func whenTheRoutersAddressCannotBeReadTheBackupIsSkippedAndRetried() async {
        let harness = harness(on: .routerAddressUnknown)
        harness.at(minutes: 5) { $0.network = FakeSystem.home }

        await harness.start()
        #expect(harness.system.startedBackups.isEmpty)
        #expect(harness.statusLine == "Backup skipped: couldn't identify this network")
        #expect(harness.scheduler.skipReason == .networkUnidentified)

        await harness.advance(minutes: 5)
        #expect(harness.system.startedBackups == [harness.minutes(5)])
    }

    @Test func aRouterAddressThatStaysUnreadableIsRetriedAfterTheRetryInterval() async {
        let harness = harness(on: .routerAddressUnknown)

        await harness.start()
        await harness.advance(minutes: 60)

        #expect(harness.system.startedBackups.isEmpty)
        #expect(harness.nextBackupLine == "Next try: today 02:00")
    }

    // MARK: All networks and USB disks

    @Test func allNetworksRemovesTheRule() async {
        let harness = harness(on: Self.cafe)
        harness.changeNetworks { $0.allNetworks = true }

        await harness.start()

        #expect(harness.system.startedBackups == [harness.startDate])
    }

    @Test(arguments: [cafe, NetworkReading.none, NetworkReading.routerAddressUnknown])
    func aLocalDiskIsNeverHeldBackByTheNetwork(network: NetworkReading) async {
        let harness = harness(on: network, disk: Self.pluggedInLocalDisk)

        await harness.start()

        #expect(harness.system.startedBackups == [harness.startDate])
    }

    // MARK: Choosing networks

    @Test func allowingTheCurrentNetworkUsesItsWiFiNameAndStartsTheWaitingBackup() async {
        let harness = harness(on: Self.cafe)
        await harness.start()
        #expect(harness.scheduler.canAllowCurrentNetwork)
        #expect(harness.scheduler.currentNetworkWiFiName == "Cafe")

        harness.scheduler.allowCurrentNetwork(label: "Cafe")
        await harness.advance(minutes: 1)

        #expect(harness.scheduler.networks.chosen.map(\.label) == ["Home", "Cafe"])
        #expect(harness.system.startedBackups == [harness.minutes(1)])
        #expect(!harness.scheduler.canAllowCurrentNetwork)
    }

    @Test func withoutLocationPermissionTheUserNamesTheNetwork() async {
        let harness = harness(on: .router(address: "02:00:00:00:00:0c", wifiName: nil))
        await harness.start()
        #expect(harness.scheduler.currentNetworkWiFiName == nil)

        harness.scheduler.allowCurrentNetwork(label: "Office")

        #expect(harness.scheduler.networks.chosen.map(\.label) == ["Home", "Office"])
    }

    @Test func backupsKeepWorkingWhenLocationPermissionIsRevoked() async {
        let harness = harness(on: .router(address: "02:00:00:00:00:0c", wifiName: "Office Wi-Fi"))
        await harness.start()
        harness.scheduler.allowCurrentNetwork(label: "Office Wi-Fi")
        await harness.advance(minutes: 1)
        harness.at(minutes: 2) { $0.network = .router(address: "02:00:00:00:00:0c", wifiName: nil) }

        await harness.advance(minutes: 25 * 60)

        #expect(harness.system.startedBackups.count == 2)
        #expect(harness.scheduler.networks.chosen.map(\.label) == ["Home", "Office Wi-Fi"])
    }

    @Test func anIdentifiedNetworkCannotBeAllowedTwiceAndAnUnidentifiedOneNotAtAll() async {
        let home = harness(on: FakeSystem.home)
        await home.start()
        #expect(!home.scheduler.canAllowCurrentNetwork)
        home.scheduler.allowCurrentNetwork(label: "Again")
        #expect(home.scheduler.networks.chosen.map(\.label) == ["Home"])

        let unknown = harness(on: .routerAddressUnknown)
        await unknown.start()
        #expect(!unknown.scheduler.canAllowCurrentNetwork)
    }

    @Test func aRemovedNetworkIsNoLongerChosen() async {
        let harness = harness(on: FakeSystem.home)
        harness.changeNetworks { $0.chosen.removeAll() }

        await harness.start()

        // With no network chosen at all, check 6 of the checklist fails.
        #expect(harness.system.startedBackups.isEmpty)
        #expect(harness.statusLine == "Finish setting up: see the checklist")
    }

    @Test func aRenamedNetworkStillCounts() async {
        let harness = harness(on: FakeSystem.home)
        harness.changeNetworks { $0.chosen[0].label = "Flat" }

        await harness.start()

        #expect(harness.system.startedBackups == [harness.startDate])
        #expect(harness.scheduler.networks.chosen.map(\.label) == ["Flat"])
    }

    @Test func chosenNetworksSurviveARestart() async {
        let harness = harness(on: Self.cafe)
        await harness.start()
        harness.scheduler.allowCurrentNetwork(label: "Cafe")
        harness.changeNetworks { $0.allNetworks = true }

        await harness.restart()

        #expect(harness.scheduler.networks.chosen.map(\.label) == ["Home", "Cafe"])
        #expect(harness.scheduler.networks.allNetworks)
    }

    // MARK: The menu

    nonisolated static let networkLines: [(NetworkReading, String)] = [
        (FakeSystem.home, "Network: Home (backups allowed)"),
        (.router(address: FakeSystem.homeRouter, wifiName: nil), "Network: Home (backups allowed)"),
        (cafe, "Network: Cafe (not chosen)"),
        (.router(address: "02:00:00:00:00:0c", wifiName: nil), "Network: this network (not chosen)"),
        (.routerAddressUnknown, "Network: not identified yet"),
        (NetworkReading.none, "Network: not connected"),
    ]

    @Test(arguments: networkLines)
    func theMenuShowsTheCurrentNetworkByNameNeverByAddress(network: NetworkReading, line: String) async {
        let harness = harness(on: network)

        await harness.scheduler.refreshStatus()

        #expect(harness.scheduler.networkLine == line)
        #expect(!harness.scheduler.networkLine.contains(":0"))
    }

    @Test func withAllNetworksTheMenuSaysSo() async {
        let harness = harness(on: Self.cafe)
        harness.changeNetworks { $0.allNetworks = true }

        await harness.scheduler.refreshStatus()

        #expect(harness.scheduler.networkLine == "Network: Cafe (all networks allowed)")
        #expect(!harness.scheduler.canAllowCurrentNetwork)
    }
}
