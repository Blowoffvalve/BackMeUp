import Foundation
import Testing
import BackMeUpCore

/// Back Up Now is greyed out, with the reason under it, while Time Machine can't start a backup:
/// while any backup runs, and while Time Machine cleans up old backups after one.
@MainActor
@Suite("Back Up Now availability")
struct BackUpNowAvailabilityTests {
    static let networkDisk = DestinationInfo.configured(Destination(kind: .network, id: "network-id"))

    @Test func availableWhileTimeMachineIsIdle() async {
        let harness = SchedulerHarness()
        harness.system.destinationInfo = Self.networkDisk
        await harness.start()

        #expect(harness.scheduler.backUpNowUnavailableReason == nil)
    }

    @Test func unavailableWhileTimeMachineBacksUpByItself() async {
        let harness = SchedulerHarness()
        harness.system.destinationInfo = Self.networkDisk
        harness.system.timeMachineStatus = .running(destinationID: "network-id", phase: "Copying")

        await harness.scheduler.refreshStatus()

        #expect(harness.scheduler.backUpNowUnavailableReason == "Available once this backup finishes")
    }

    @Test func unavailableWhileTimeMachineCleansUp() async {
        let harness = SchedulerHarness()
        harness.system.destinationInfo = Self.networkDisk
        harness.system.timeMachineStatus = .running(destinationID: "network-id", phase: "ThinningPostBackup")

        await harness.scheduler.refreshStatus()

        #expect(harness.statusLine == "Time Machine is cleaning up old backups")
        #expect(harness.scheduler.backUpNowUnavailableReason == "Available once Time Machine finishes cleaning up")
    }

    @Test func unavailableWhileAnotherDiskIsCleanedUp() async {
        let harness = SchedulerHarness()
        harness.system.destinationInfo = .several([
            Destination(kind: .local, id: "usb-id", name: "Old Disk", mountPoint: "/Volumes/Old Disk"),
            Destination(kind: .network, id: "network-id", name: "New Disk"),
        ])
        await harness.start()
        await harness.scheduler.chooseDisk(id: "network-id")
        harness.system.timeMachineStatus = .running(destinationID: "usb-id", phase: "ThinningPreBackup")

        await harness.scheduler.refreshStatus()

        #expect(harness.statusLine == "Time Machine is cleaning up another disk")
        #expect(harness.scheduler.backUpNowUnavailableReason == "Available once Time Machine finishes cleaning up")
    }

    @Test func availableAgainOnceTimeMachineFinishes() async {
        let harness = SchedulerHarness()
        harness.system.destinationInfo = Self.networkDisk
        harness.system.timeMachineStatus = .running(destinationID: "network-id", phase: "ThinningPostBackup")
        await harness.scheduler.refreshStatus()

        harness.system.timeMachineStatus = .idle
        await harness.scheduler.refreshStatus()

        #expect(harness.scheduler.backUpNowUnavailableReason == nil)
    }
}
