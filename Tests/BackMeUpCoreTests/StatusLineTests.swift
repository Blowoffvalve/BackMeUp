import Foundation
import Testing
import BackMeUpCore

/// What the menu's status line says about Time Machine.
@MainActor
@Suite("Menu status line")
struct StatusLineTests {
    nonisolated static let networkDisk = DestinationInfo.configured(Destination(kind: .network, id: "network-id"))
    nonisolated static let localDisk = DestinationInfo.configured(Destination(kind: .local, id: "local-id"))

    @Test func idleWithNetworkDisk() async {
        let harness = SchedulerHarness()
        harness.system.timeMachineStatus = .idle
        harness.system.destinationInfo = Self.networkDisk

        await harness.start()

        #expect(harness.statusLine == "Time Machine idle · network disk")
    }

    @Test(arguments: [
        (TimeMachineStatus.running, networkDisk, "Backing up now · network disk"),
        (.running, localDisk, "Backing up now · local disk"),
        (.idle, localDisk, "Time Machine idle · local disk"),
        (.idle, .notSetUp, "No Time Machine disk set up"),
        (.unknown, networkDisk, "Can't tell what Time Machine is doing · network disk"),
        (.idle, .unknown, "Can't read Time Machine's settings"),
    ])
    func describesTimeMachine(status: TimeMachineStatus, destination: DestinationInfo, expected: String) async {
        let harness = SchedulerHarness()
        harness.system.timeMachineStatus = status
        harness.system.destinationInfo = destination

        await harness.start()

        #expect(harness.statusLine == expected)
    }

    @Test func followsABackupThatStartsAndFinishesAsTimePasses() async {
        let harness = SchedulerHarness()
        harness.system.destinationInfo = Self.networkDisk
        harness.at(minutes: 10) { $0.timeMachineStatus = .running }
        harness.at(minutes: 70) { $0.timeMachineStatus = .idle }

        await harness.start()
        #expect(harness.statusLine == "Time Machine idle · network disk")

        await harness.advance(minutes: 30)
        #expect(harness.statusLine == "Backing up now · network disk")

        await harness.advance(minutes: 60)
        #expect(harness.statusLine == "Time Machine idle · network disk")
    }

    @Test func noticesWhenTheDiskIsRemoved() async {
        let harness = SchedulerHarness()
        harness.system.destinationInfo = Self.localDisk
        harness.at(minutes: 5) { $0.destinationInfo = .notSetUp }

        await harness.start()
        await harness.advance(minutes: 5)

        #expect(harness.statusLine == "No Time Machine disk set up")
    }
}
