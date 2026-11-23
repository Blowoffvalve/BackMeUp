import Foundation
import Testing
import BackMeUpCore

/// What the menu's two lines say: the last backup, and the next one.
@MainActor
@Suite("Menu status line")
struct StatusLineTests {
    static let networkDisk = DestinationInfo.configured(Destination(kind: .network, id: "network-id"))

    @Test func beforeAnyBackupHasRun() {
        let harness = SchedulerHarness()

        #expect(harness.statusLine == "No backups yet")
        #expect(harness.nextBackupLine == "Next backup: now")
    }

    @Test func refreshingTheMenuNeverStartsABackup() async {
        let harness = SchedulerHarness()
        harness.system.destinationInfo = Self.networkDisk
        harness.system.timeMachineStatus = .running(destinationID: nil)

        await harness.scheduler.refreshStatus()

        #expect(harness.system.startedBackups.isEmpty)
        #expect(harness.statusLine == "Time Machine is working on the first backup")
    }

    @Test func showsTimeMachineBackingUpByItself() async {
        let harness = SchedulerHarness()
        harness.system.destinationInfo = Self.networkDisk
        harness.system.timeMachineStatus = .running(destinationID: nil)

        await harness.start()

        #expect(harness.statusLine == "Time Machine is working on the first backup")
        #expect(harness.nextBackupLine == "")
    }

    // MARK: Following Time Machine's stage

    /// One row of the wording table: what Time Machine reports, and the line for each case.
    struct StageRow: Sendable, CustomTestStringConvertible {
        var phase: String?
        var progress: BackupProgress?
        var chosenDisk: String
        var firstBackup: String
        var anotherDisk: String
        var testDescription: String { "\(phase ?? "no stage"), \(progress == nil ? "no percent" : "percent")" }
    }

    nonisolated static let threeHours = BackupProgress(fraction: 0.045, timeRemaining: 3 * 3600)

    /// The line never claims more than Time Machine does: a percent shows only while copying.
    nonisolated static let stageRows: [StageRow] = [
        "Starting", "MountingBackupVol", "MountingBackupVolForHealthCheck", "MountingDiskImage",
        "HealthCheckCopyHFSMeta", "CalculatingChanges", "FindingChanges", "PreparingSourceVolumes",
    ].map {
        StageRow(
            phase: $0, progress: threeHours,
            chosenDisk: "Getting ready to back up",
            firstBackup: "Getting ready for first backup",
            anotherDisk: "Time Machine is getting ready to back up to another disk"
        )
    } + [
        StageRow(
            phase: "Copying", progress: threeHours,
            chosenDisk: "Backing up: 4.5%, about 3 hours left",
            firstBackup: "First backup: 4.5%, about 3 hours left",
            anotherDisk: "Time Machine is backing up to another disk"
        ),
        StageRow(
            phase: "Copying", progress: nil,
            chosenDisk: "Backing up",
            firstBackup: "First backup",
            anotherDisk: "Time Machine is backing up to another disk"
        ),
        StageRow(
            phase: "ThinningPostBackup", progress: nil,
            chosenDisk: "Time Machine is cleaning up old backups",
            firstBackup: "Time Machine is cleaning up old backups",
            anotherDisk: "Time Machine is cleaning up another disk"
        ),
        StageRow(
            phase: "SomeFutureStage", progress: threeHours,
            chosenDisk: "Time Machine is working on a backup",
            firstBackup: "Time Machine is working on the first backup",
            anotherDisk: "Time Machine is working on another disk"
        ),
        StageRow(
            phase: nil, progress: nil,
            chosenDisk: "Time Machine is working on a backup",
            firstBackup: "Time Machine is working on the first backup",
            anotherDisk: "Time Machine is working on another disk"
        ),
    ]

    @Test(arguments: stageRows)
    func followsTimeMachinesStageToTheChosenDisk(row: StageRow) async {
        let harness = SchedulerHarness()
        harness.system.destinationInfo = Self.networkDisk
        await harness.start() // the first backup succeeds
        harness.system.timeMachineStatus = .running(destinationID: "network-id", phase: row.phase)
        harness.system.backupProgress = row.progress

        await harness.scheduler.refreshStatus()

        #expect(harness.statusLine == row.chosenDisk)
    }

    @Test(arguments: stageRows)
    func followsTimeMachinesStageInTheFirstBackup(row: StageRow) async {
        let harness = SchedulerHarness()
        harness.system.destinationInfo = Self.networkDisk
        harness.system.timeMachineStatus = .running(destinationID: "network-id", phase: row.phase)
        harness.system.backupProgress = row.progress

        await harness.start()

        #expect(harness.system.startedBackups.isEmpty)
        #expect(harness.statusLine == row.firstBackup)
    }

    @Test(arguments: stageRows)
    func followsTimeMachinesStageToAnotherDisk(row: StageRow) async {
        let harness = SchedulerHarness()
        harness.system.destinationInfo = .several([
            Destination(kind: .local, id: "usb-id", name: "Old Disk", mountPoint: "/Volumes/Old Disk"),
            Destination(kind: .network, id: "network-id", name: "New Disk"),
        ])
        await harness.start()
        await harness.scheduler.chooseDisk(id: "network-id")
        harness.system.timeMachineStatus = .running(destinationID: "usb-id", phase: row.phase)
        harness.system.backupProgress = row.progress

        await harness.scheduler.refreshStatus()

        #expect(harness.statusLine == row.anotherDisk)
    }

    /// Before Time Machine reports a backup BackMeUp started as running, the line already says
    /// it's getting ready, and keeps saying so through Time Machine's own preparing stages.
    @Test func theFirstBackupGetsReadyFromTheMomentBackMeUpStartsIt() async {
        let harness = SchedulerHarness()
        harness.system.destinationInfo = Self.networkDisk
        harness.system.nextBackup = .lasting(minutes: 600)
        harness.system.reportsStartedBackup = false

        await harness.start()
        #expect(harness.statusLine == "Getting ready for first backup")

        await harness.advance(minutes: 1)
        #expect(harness.statusLine == "Getting ready for first backup")

        harness.system.reportsStartedBackup = true
        harness.system.startedBackupPhase = "MountingBackupVol"
        await harness.advance(minutes: 1)
        #expect(harness.statusLine == "Getting ready for first backup")

        harness.system.startedBackupPhase = "Copying"
        await harness.advance(minutes: 1)
        #expect(harness.statusLine == "First backup")

        harness.system.backupProgress = BackupProgress(fraction: 0.352, timeRemaining: 3 * 3600)
        await harness.advance(minutes: 1)
        #expect(harness.statusLine == "First backup: 35.2%, about 3 hours left")
    }

    /// Once Time Machine reports a backup BackMeUp started as running, a missing stage name gets
    /// the neutral line, as for any other backup.
    @Test func aBackupBackMeUpStartedWithNoStageNameGetsTheNeutralLine() async {
        let harness = SchedulerHarness()
        harness.system.destinationInfo = Self.networkDisk
        harness.system.nextBackup = .lasting(minutes: 600)

        await harness.start()
        await harness.advance(minutes: 1)

        #expect(harness.statusLine == "Time Machine is working on the first backup")
    }

    @Test func backUpNowSaysItIsGettingReadyStraightAway() async {
        let harness = SchedulerHarness()
        harness.system.destinationInfo = Self.networkDisk
        await harness.start() // the first backup succeeds
        harness.system.nextBackup = .lasting(minutes: 30)

        await harness.backUpNow()

        #expect(harness.statusLine == "Getting ready to back up")
    }

    @Test func olderBackupsShowTheirDate() async {
        let harness = SchedulerHarness()
        harness.system.destinationInfo = Self.networkDisk
        await harness.start() // finished 1 Jan 00:20
        harness.changeSettings { $0.backupInterval = BackupInterval(count: 1, unit: .weeks) }

        await harness.advance(minutes: 24 * 60)
        #expect(harness.statusLine == "Last backup: yesterday 00:20")

        await harness.advance(minutes: 24 * 60)
        #expect(harness.statusLine == "Last backup: 1 Jan 00:20")
        #expect(harness.nextBackupLine == "Next backup: 8 Jan 00:20")
    }
}
