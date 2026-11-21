import Foundation
import Testing
@testable import BackMeUpCore

/// Troubleshoot: spotting a stuck Time Machine, guiding a restart, and checking afterwards.
@MainActor
@Suite("Troubleshoot")
struct TroubleshootTests {
    static let server = "backup-server"
    static let networkDisk = DestinationInfo.configured(Destination(kind: .network, id: "network-id", serverHost: server))
    /// Time Machine giving up at once with `RESULT` 26, as it did when stuck.
    static let fastUnreachable = FakeSystem.ScriptedBackup.fails(result: 26, minutes: 0)

    func harness() -> SchedulerHarness {
        let harness = SchedulerHarness()
        harness.system.destinationInfo = Self.networkDisk
        return harness
    }

    static let stuckAlert = Alert(
        kind: .failed,
        title: "Time Machine is stuck",
        body: "Your backup disk is fine, but Time Machine has lost track of it. Restarting your Mac fixes this."
    )

    // MARK: Spotting it

    @Test func aFastUnreachableWithTheServerAnsweringAndALostMountIsStuck() async {
        let harness = harness()
        harness.system.nextBackup = Self.fastUnreachable

        await harness.start()

        #expect(harness.scheduler.history.attempts.last?.outcome == .failed(.timeMachineStuck(afterRestart: false)))
        #expect(harness.notifications == [Self.stuckAlert])
        #expect(harness.statusLine == "Last backup failed: Time Machine is stuck. Restarting your Mac fixes this.")
        #expect(harness.scheduler.history.stuck?.since == harness.startDate)
        #expect(harness.scheduler.needsFixing)
        let fix = harness.scheduler.troubleshootReport?.firstFailure
        #expect(fix?.kind == .timeMachine)
        #expect(fix?.steps == TroubleshootReport.restartSteps)
    }

    @Test func whenTheLogCannotBeReadTheOtherSignsAreEnough() async {
        let harness = harness()
        harness.system.nextBackup = Self.fastUnreachable
        harness.system.timeMachineLogShowsLostMount = nil

        await harness.start()

        #expect(harness.notifications == [Self.stuckAlert])
    }

    @Test func aLogWithNoLostMountIsNotStuck() async {
        let harness = harness()
        harness.system.nextBackup = Self.fastUnreachable
        harness.system.timeMachineLogShowsLostMount = false

        await harness.start()

        #expect(harness.scheduler.history.attempts.last?.outcome == .failed(.diskUnreachable(isNetworkDisk: true)))
        #expect(harness.scheduler.history.stuck == nil)
    }

    @Test func aSlowUnreachableIsNotStuck() async {
        let harness = harness()
        harness.system.nextBackup = .fails(result: 26, minutes: 1)

        await harness.start()

        #expect(harness.scheduler.history.attempts.last?.outcome == .failed(.diskUnreachable(isNetworkDisk: true)))
        #expect(harness.scheduler.troubleshootReport?.firstFailure == nil)
    }

    @Test func aDiskWithNoKnownServerIsNeverCalledStuck() async {
        let harness = harness()
        harness.system.destinationInfo = .configured(Destination(kind: .network, id: "network-id"))
        harness.system.nextBackup = Self.fastUnreachable

        await harness.start()

        #expect(harness.scheduler.history.attempts.last?.outcome == .failed(.diskUnreachable(isNetworkDisk: true)))
        #expect(harness.system.serversAsked.isEmpty)
    }

    @Test func aServerThatDoesNotAnswerIsNamedInsteadOfARestart() async {
        let harness = harness()
        harness.system.nextBackup = Self.fastUnreachable
        harness.system.serverAnswering = false

        await harness.start()

        #expect(harness.scheduler.history.attempts.last?.outcome == .failed(.diskUnreachable(isNetworkDisk: true)))
        #expect(harness.notifications.map(\.body) == ["1 backup didn't finish. The backup server isn't answering."])
        #expect(harness.statusLine == "Last backup failed. The backup server isn't answering.")
        #expect(harness.scheduler.troubleshootReport?.firstFailure?.kind == .server)
    }

    @Test func stuckIsAlertedOnTheFirstFailureWhateverTheAlertSetting() async {
        let harness = harness()
        harness.changeSettings { $0.alerts.failuresInARow = 3 }
        harness.system.nextBackup = Self.fastUnreachable

        await harness.start()

        #expect(harness.notifications == [Self.stuckAlert])
    }

    // MARK: After a restart

    /// Stuck at the first backup, then the Mac restarts an hour later and BackMeUp opens at login.
    func stuckThenRestarted() async -> SchedulerHarness {
        let harness = harness()
        harness.system.nextBackup = Self.fastUnreachable
        await harness.start()
        await harness.advance(minutes: 60)
        harness.system.bootTime = harness.system.now
        return harness
    }

    @Test func afterARestartOneBackupStartsFiveMinutesAfterLaunch() async {
        let harness = await stuckThenRestarted()
        harness.system.nextBackup = .succeeds
        let backupsBefore = harness.system.startedBackups.count
        let launch = harness.system.now

        await harness.restart()
        await harness.advance(minutes: 4)
        #expect(harness.system.startedBackups.count == backupsBefore)

        await harness.advance(minutes: 1)
        #expect(harness.system.startedBackups == harness.system.startedBackups.prefix(backupsBefore) + [launch.addingTimeInterval(5 * 60)])
    }

    @Test func aWorkingBackupAfterTheRestartSaysItIsFixed() async {
        let harness = await stuckThenRestarted()
        harness.system.nextBackup = .succeeds

        await harness.restart()
        await harness.advance(minutes: 5)

        #expect(harness.notifications.last?.title == "Fixed: backing up again")
        #expect(harness.notifications.last?.body.hasPrefix("Restarting your Mac fixed Time Machine. Last backup: ") == true)
        #expect(harness.scheduler.history.stuck == nil)
        #expect(!harness.scheduler.needsFixing)
    }

    @Test func stillStuckAfterTheRestartSaysSoAndAsksForNoOtherRestart() async {
        let harness = await stuckThenRestarted()

        await harness.restart()
        await harness.advance(minutes: 5)

        #expect(harness.scheduler.history.attempts.last?.outcome == .failed(.timeMachineStuck(afterRestart: true)))
        #expect(harness.notifications.last?.title == "Restarting didn't fix Time Machine")
        #expect(harness.statusLine == "Last backup failed: Time Machine is still stuck after a restart. Choose How to Fix This…")
        let fix = harness.scheduler.troubleshootReport?.firstFailure
        #expect(fix?.sentence == "Time Machine is still stuck after a restart.")
        #expect(fix?.steps.contains { $0.contains("Restart") } == false)
        #expect(fix?.steps.first?.contains("Copy Details") == true)
    }

    @Test func reopeningBackMeUpWithoutARestartKeepsTheUsualSchedule() async {
        let harness = harness()
        harness.system.nextBackup = Self.fastUnreachable
        await harness.start()
        await harness.advance(minutes: 60)
        let backupsBefore = harness.system.startedBackups.count

        await harness.restart() // same start-up time: only BackMeUp was reopened
        await harness.advance(minutes: 5)

        #expect(harness.system.startedBackups.count == backupsBefore)
        #expect(harness.system.logLines.contains { $0.contains("restarted") } == false)
    }

    @Test func theBackupAfterARestartFollowsTheBatteryRule() async {
        let harness = await stuckThenRestarted()
        harness.changeSettings { $0.allowBackupsOnBattery = false }
        harness.system.powerSource = .battery
        let backupsBefore = harness.system.startedBackups.count

        await harness.restart()
        await harness.advance(minutes: 5)

        #expect(harness.system.startedBackups.count == backupsBefore)
        #expect(harness.statusLine == "Backup skipped: on battery")
    }

    // MARK: From the menu

    @Test func troubleshootFromTheMenuFindsTheWrongNetwork() async {
        let harness = harness()
        await harness.start()
        harness.system.network = .router(address: "02:00:00:00:00:99", wifiName: "Café")

        await harness.scheduler.troubleshoot()

        let report = harness.scheduler.troubleshootReport
        #expect(report?.checks.map(\.state) == [.failed, .passed, .passed])
        #expect(report?.firstFailure?.sentence == "Your Mac isn't on a network you chose for backups.")
    }

    @Test func troubleshootFromTheMenuNeverStartsABackup() async {
        let harness = harness()
        await harness.start()
        let backupsBefore = harness.system.startedBackups.count

        await harness.scheduler.troubleshoot()

        #expect(harness.system.startedBackups.count == backupsBefore)
        #expect(harness.scheduler.troubleshootReport?.checks.allSatisfy { $0.state == .passed } == true)
    }

    @Test func aUSBDiskHasNoNetworkOrServerToCheck() async {
        let harness = SchedulerHarness()
        harness.system.destinationInfo = .configured(Destination(kind: .local, id: "usb-id", mountPoint: "/Volumes/Backup"))
        await harness.start()

        await harness.scheduler.troubleshoot()

        #expect(harness.scheduler.troubleshootReport?.checks.map(\.state) == [.notNeeded, .notNeeded, .passed])
        #expect(harness.system.serversAsked.isEmpty)
    }

    // MARK: Copy Details

    @Test func copyDetailsNamesNoServerNetworkOrAddress() async {
        let harness = harness()
        harness.system.nextBackup = Self.fastUnreachable
        await harness.start()

        let details = harness.scheduler.troubleshootDetails ?? ""

        #expect(details.contains("BackMeUp 1.0 troubleshooting"))
        #expect(details.contains("Latest problem: Time Machine is stuck"))
        #expect(details.contains("✗ Time Machine: Time Machine is stuck."))
        for personal in [Self.server, "Home", FakeSystem.homeRouter] {
            #expect(!details.contains(personal))
        }
    }
}
