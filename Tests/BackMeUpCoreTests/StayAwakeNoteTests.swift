import Foundation
import Testing
import BackMeUpCore

/// The note under the progress line that the Mac stays awake while a backup runs.
@MainActor
@Suite("Stay-awake note")
struct StayAwakeNoteTests {
    static let networkDisk = DestinationInfo.configured(Destination(kind: .network, id: "network-id"))
    static let note = "Your Mac will stay awake until this backup finishes. Don't close the lid."

    func harnessWithNetworkDisk() -> SchedulerHarness {
        let harness = SchedulerHarness()
        harness.system.destinationInfo = Self.networkDisk
        return harness
    }

    @Test func showsWhileTimeMachineBacksUpByItselfBeforeItGivesProgress() async {
        let harness = harnessWithNetworkDisk()
        harness.system.timeMachineStatus = .running(destinationID: nil)

        await harness.start()

        #expect(harness.statusLine == "Time Machine is working on the first backup")
        #expect(harness.stayAwakeNote == Self.note)
    }

    @Test func showsUnderTheFirstBackupsProgressOnBattery() async {
        let harness = harnessWithNetworkDisk()
        harness.system.powerSource = .battery
        harness.system.timeMachineStatus = .running(destinationID: nil, phase: "Copying")
        harness.system.backupProgress = BackupProgress(fraction: 0.352, timeRemaining: nil)

        await harness.start()

        #expect(harness.statusLine == "First backup: 35.2%")
        #expect(harness.stayAwakeNote == Self.note)
    }

    @Test func showsUnderALaterBackupsProgressAndGoesWhenItFinishes() async {
        let harness = harnessWithNetworkDisk()
        await harness.start() // the first backup succeeds
        harness.system.nextBackup = .lasting(minutes: 30)
        harness.system.startedBackupPhase = "Copying"
        harness.system.backupProgress = BackupProgress(fraction: 0.5, timeRemaining: 20 * 60)

        await harness.backUpNow()
        await harness.advance(minutes: 1)
        #expect(harness.statusLine == "Backing up: 50.0%, about 20 minutes left")
        #expect(harness.stayAwakeNote == Self.note)

        await harness.advance(minutes: 30)
        #expect(harness.statusLine.hasPrefix("Last backup: "))
        #expect(harness.stayAwakeNote == "")
    }

    /// Time Machine holds the Mac awake for any backup, whoever started it and whichever disk it
    /// goes to, so the note shows for a backup to a disk other than the chosen one too.
    @Test func showsWhileTimeMachineBacksUpToAnotherDiskOnBattery() async {
        let harness = SchedulerHarness()
        harness.system.destinationInfo = .several([
            Destination(kind: .local, id: "usb-id", name: "Old Disk", mountPoint: "/Volumes/Old Disk"),
            Destination(kind: .network, id: "network-id", name: "New Disk"),
        ])
        harness.system.preferences = TimeMachinePreferences(autoBackup: false, destinations: [
            .init(id: "usb-id", encryption: .notEncrypted, result: 0),
            .init(id: "network-id", encryption: .encrypted, result: 0),
        ])
        harness.system.powerSource = .battery
        harness.system.timeMachineStatus = .running(destinationID: "usb-id", phase: "Copying")
        harness.at(minutes: 30) { $0.timeMachineStatus = .idle }
        await harness.start()
        await harness.scheduler.chooseDisk(id: "network-id")
        await harness.advance(minutes: 1)

        #expect(harness.statusLine == "Time Machine is backing up to another disk")
        #expect(harness.stayAwakeNote == Self.note)

        await harness.advance(minutes: 30)
        #expect(harness.statusLine != "Time Machine is backing up to another disk")
        #expect(harness.stayAwakeNote == "")
    }

    @Test func isAbsentAfterAFailedBackup() async {
        let harness = harnessWithNetworkDisk()
        harness.system.nextBackup = .fails(exitCode: 0, result: 19)

        await harness.start()

        #expect(harness.statusLine == "Last backup failed: Time Machine reported error 19")
        #expect(harness.stayAwakeNote == "")
    }

    @Test func isAbsentWhileSetupIsUnfinished() async {
        let harness = SchedulerHarness()
        harness.system.destinationInfo = .notSetUp

        await harness.start()

        #expect(harness.statusLine == "Finish setting up: see the checklist")
        #expect(harness.stayAwakeNote == "")
    }
}
