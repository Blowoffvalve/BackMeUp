import Foundation
import Testing
import BackMeUpCore

/// Before the first success, an interrupted backup is paused, not failed.
@MainActor
@Suite("The first backup")
struct FirstBackupTests {
    static let networkDisk = DestinationInfo.configured(Destination(kind: .network, id: "network-id"))

    func harnessWithNetworkDisk() -> SchedulerHarness {
        let harness = SchedulerHarness()
        harness.system.destinationInfo = Self.networkDisk
        return harness
    }

    nonisolated static let interruptions: [FakeSystem.ScriptedBackup] = [
        .fails(exitCode: 1, result: nil), // stopped, for example by closing the lid
        .fails(exitCode: 0, result: nil), // tmutil says nothing went wrong, but there's no result
        .fails(exitCode: 1, result: 0), // stopped, and Time Machine reports no error
        .staleResult, // tmutil exits 0, but there's no new backup on the disk
    ]

    @Test(arguments: interruptions)
    func anInterruptedFirstBackupIsPausedNotFailed(backup: FakeSystem.ScriptedBackup) async {
        let harness = harnessWithNetworkDisk()
        harness.system.nextBackup = backup // finishes at 00:20

        await harness.start()

        #expect(harness.statusLine == "First backup paused")
        #expect(harness.nextBackupLine == "Resumes: today 01:20")
        #expect(harness.scheduler.history.attempts.map(\.outcome) == [.paused])
        #expect(harness.scheduler.skipReason == nil)
    }

    @Test func aPausedFirstBackupResumesAtTheNextRetry() async {
        let harness = harnessWithNetworkDisk()
        harness.system.nextBackup = .fails(exitCode: 1, result: nil)
        harness.at(minutes: 21) { $0.nextBackup = .succeeds }

        await harness.start()
        await harness.advance(minutes: 60)

        #expect(harness.system.startedBackups == [harness.minutes(0), harness.minutes(80)])
        #expect(harness.statusLine == "Last backup: today 01:40")
    }

    @Test func aPausedFirstBackupSurvivesARestart() async {
        let harness = harnessWithNetworkDisk()
        harness.system.nextBackup = .fails(exitCode: 1, result: nil)
        await harness.start()

        await harness.restart()

        #expect(harness.statusLine == "First backup paused")
        #expect(harness.system.startedBackups.count == 1)
    }

    nonisolated static let errors: [(FakeSystem.ScriptedBackup, String)] = [
        (.fails(exitCode: 0, result: 19), "Last backup failed: Time Machine reported error 19"),
        (.fails(exitCode: 1, result: 19), "Last backup failed: Time Machine reported error 19"),
        (.fails(exitCode: 0, result: 26, minutes: 1), "Last backup failed: the backup disk couldn't be reached. Check you're on the right network. If it keeps happening, restarting your Mac usually fixes it."),
        (.fails(exitCode: 1, result: 26), "Last backup failed: the backup disk couldn't be reached. Check you're on the right network. If it keeps happening, restarting your Mac usually fixes it."),
        (.fails(exitCode: nil), "Last backup failed: couldn't start Time Machine"),
    ]

    @Test(arguments: errors)
    func aFirstBackupWithAnErrorResultStillFails(backup: FakeSystem.ScriptedBackup, expected: String) async {
        let harness = harnessWithNetworkDisk()
        harness.system.nextBackup = backup

        await harness.start()

        #expect(harness.statusLine == expected)
        #expect(harness.nextBackupLine.hasPrefix("Next try: "))
    }

    @Test func afterTheFirstSuccessAnInterruptionIsAFailure() async {
        let harness = harnessWithNetworkDisk()
        await harness.start() // the first backup succeeds
        harness.system.nextBackup = .fails(exitCode: 1, result: nil)

        await harness.backUpNow()

        #expect(harness.statusLine == "Last backup failed: Time Machine stopped with code 1")
    }
}
