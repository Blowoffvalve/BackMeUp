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

        #expect(harness.statusLine == "Backing up now")
        #expect(harness.stayAwakeNote == Self.note)
    }

    @Test func showsUnderTheFirstBackupsProgressOnBattery() async {
        let harness = harnessWithNetworkDisk()
        harness.system.powerSource = .battery
        harness.system.timeMachineStatus = .running(destinationID: nil)
        harness.system.backupProgress = BackupProgress(fraction: 0.352, timeRemaining: nil)

        await harness.start()

        #expect(harness.statusLine == "First backup: 35.2%")
        #expect(harness.stayAwakeNote == Self.note)
    }

    @Test func showsUnderALaterBackupsProgressAndGoesWhenItFinishes() async {
        let harness = harnessWithNetworkDisk()
        await harness.start() // the first backup succeeds
        harness.system.nextBackup = .lasting(minutes: 30)
        harness.system.backupProgress = BackupProgress(fraction: 0.5, timeRemaining: 20 * 60)

        await harness.backUpNow()
        await harness.advance(minutes: 1)
        #expect(harness.statusLine == "Backing up: 50.0%, about 20 minutes left")
        #expect(harness.stayAwakeNote == Self.note)

        await harness.advance(minutes: 30)
        #expect(harness.statusLine.hasPrefix("Last backup: "))
        #expect(harness.stayAwakeNote == "")
    }

    @Test func goesOnceTheBackupHasFinished() async {
        let harness = harnessWithNetworkDisk()

        await harness.start() // the first backup succeeds

        #expect(harness.statusLine == "Last backup: today 00:20")
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
