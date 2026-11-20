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
            DiskChoice(id: "usb-id", label: "Old Disk (USB disk, not encrypted)"),
            DiskChoice(id: "network-id", label: "New Disk (Network disk, encrypted)"),
        ])
        #expect(check?.chosenDiskID == nil)
        #expect(harness.system.startedBackups.isEmpty)
        #expect(harness.scheduler.skipReason == .setupNotFinished)
        #expect(harness.statusLine == "Finish setting up: see the checklist")
        #expect(harness.checklistShown == 1)
    }

    @Test func withOneDiskThereIsNothingToChoose() async {
        let harness = SchedulerHarness()
        harness.system.destinationInfo = .configured(Self.networkDisk)

        await harness.start()

        let check = harness.scheduler.checklist?.item(.diskSetUp)
        #expect(check?.state == .passed)
        #expect(check?.sentence == "A Time Machine disk is set up.")
        #expect(check?.diskChoices == [])
        #expect(harness.scheduler.diskChoices == [])
        #expect(harness.system.startedBackups == [harness.startDate])
        #expect(harness.system.startedBackupDestinations == [nil])
    }
}
