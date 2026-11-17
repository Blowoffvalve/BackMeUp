import Foundation
import Testing
import BackMeUpCore

/// Phone alerts through ntfy: every Mac notification alert also goes to ntfy once it's set up.
@MainActor
@Suite("ntfy")
struct NtfyTests {
    static let networkDisk = DestinationInfo.configured(Destination(kind: .network, id: "network-id"))
    static let topic = "example-topic"

    func harnessWithNtfy(token: String? = nil) -> SchedulerHarness {
        let harness = SchedulerHarness()
        harness.system.destinationInfo = Self.networkDisk
        harness.scheduler.updateNtfy(NtfySettings(server: "https://ntfy.example", topic: Self.topic, token: token))
        return harness
    }

    @Test func aFailureAlertAlsoGoesToNtfyWithAWarningTag() async {
        let harness = harnessWithNtfy()
        harness.system.nextBackup = .fails(result: 19)

        await harness.start()

        #expect(harness.system.ntfyMessages == [
            NtfyMessage(
               settings: NtfySettings(server: "https://ntfy.example", topic: Self.topic, token: nil),
                title: "Backup failed",
                body: "1 backup didn't finish. Time Machine reported error 19.",
                tags: [.warning]
            ),
        ])
    }

    @Test func withoutATopicNothingGoesToNtfy() async {
        let harness = SchedulerHarness()
        harness.system.destinationInfo = Self.networkDisk
        harness.system.nextBackup = .fails(result: 19)

        await harness.start()

        #expect(harness.notifications.count == 1)
        #expect(harness.system.ntfyMessages.isEmpty)
    }

    @Test func workingAgainGoesToNtfyWithASuccessTag() async {
        let harness = harnessWithNtfy()
        harness.system.nextBackup = .fails(result: 19)
        harness.at(minutes: 30) { $0.nextBackup = .succeeds }

        await harness.start() // fails at 00:20
        await harness.advance(minutes: 100) // the retry succeeds at 01:40

        let workingAgain = harness.system.ntfyMessages.first { $0.title == "Backups are working again" }
        #expect(workingAgain?.body == "Last backup: today 01:40")
        #expect(workingAgain?.tags == [.success])
    }

    @Test func anOverdueAlertGoesToNtfyWithAWarningTag() async {
        let harness = harnessWithNtfy()
        harness.system.network = .none

        await harness.start()
        await harness.advance(minutes: 3 * 24 * 60)

        #expect(harness.system.ntfyMessages.map(\.title) == ["Backups skipped"])
        #expect(harness.system.ntfyMessages.first?.body == harness.notifications.first?.body)
        #expect(harness.system.ntfyMessages.first?.tags == [.warning])
    }

    @Test func theAccessTokenIsSentWhenThereIsOne() async {
        let harness = harnessWithNtfy(token: "example-token")
        harness.system.nextBackup = .fails(result: 19)

        await harness.start()

        #expect(harness.system.ntfyMessages.map(\.settings.token) == ["example-token"])
    }

    @Test func theTopicAndTokenAreKeptInTheKeychainNotInSettings() async {
        let harness = harnessWithNtfy(token: "example-token")
        await harness.start()

        #expect(harness.system.secrets == [.ntfyTopic: Self.topic, .ntfyToken: "example-token"])
        #expect(harness.system.storedNtfyServer == "https://ntfy.example")
        let stored = [
            harness.system.storedSettings.flatMap { try? JSONEncoder().encode($0) },
            harness.system.storedHistory.flatMap { try? JSONEncoder().encode($0) },
            harness.system.storedNetworks.flatMap { try? JSONEncoder().encode($0) },
        ].compactMap { $0 }.map { String(decoding: $0, as: UTF8.self) }.joined()
        #expect(!stored.contains(Self.topic))
        #expect(!stored.contains("example-token"))

        await harness.restart()
        #expect(harness.scheduler.ntfy == NtfySettings(server: "https://ntfy.example", topic: Self.topic, token: "example-token"))
    }

    @Test func clearingTheTopicTurnsNtfyOffAndRemovesTheSecrets() async {
        let harness = harnessWithNtfy(token: "example-token")
        harness.scheduler.updateNtfy(NtfySettings(server: "https://ntfy.example", topic: " ", token: ""))
        harness.system.nextBackup = .fails(result: 19)

        await harness.start()

        #expect(harness.system.secrets.isEmpty)
        #expect(harness.system.ntfyMessages.isEmpty)
    }

    @Test func ntfyIsOffWithTheDefaultServerAtFirst() {
        let harness = SchedulerHarness()
        #expect(harness.scheduler.ntfy == NtfySettings(server: "https://ntfy.sh", topic: "", token: nil))
        #expect(!harness.scheduler.ntfy.isSetUp)
    }

    // MARK: First backup finished

    @Test func theFirstSuccessSendsFirstBackupFinishedOnce() async {
        let harness = harnessWithNtfy()

        await harness.start() // succeeds at 00:20
        await harness.advance(minutes: 3 * 24 * 60) // and daily after that

        #expect(harness.system.startedBackups.count > 1)
        #expect(harness.system.ntfyMessages == [
            NtfyMessage(
               settings: NtfySettings(server: "https://ntfy.example", topic: Self.topic, token: nil),
                title: "First backup finished",
                body: "Your Mac's first backup finished today 00:20.",
                tags: [.success]
            ),
        ])
        #expect(harness.notifications.isEmpty)
    }

    @Test func firstBackupFinishedIsNotSentAgainAfterARestart() async {
        let harness = harnessWithNtfy()

        await harness.start()
        await harness.restart()
        await harness.advance(minutes: 2 * 24 * 60)

        #expect(harness.system.ntfyMessages.map(\.title) == ["First backup finished"])
    }

    @Test func aFailedFirstBackupFinishedIsRetriedAtTheNextRun() async {
        let harness = harnessWithNtfy()
        harness.system.ntfyResult = .failed("the server answered 500")
        harness.at(minutes: 60) { $0.ntfyResult = .sent }

        await harness.start() // succeeds at 00:20, the message fails
        await harness.advance(minutes: 3 * 24 * 60)

        #expect(harness.system.ntfyMessages.map(\.title) == ["First backup finished", "First backup finished"])
    }

    @Test func firstBackupFinishedIsNotSentIfNtfyIsSetUpLater() async {
        let harness = SchedulerHarness()
        harness.system.destinationInfo = Self.networkDisk

        await harness.start() // succeeds at 00:20, without ntfy
        harness.scheduler.updateNtfy(NtfySettings(topic: Self.topic))
        await harness.advance(minutes: 2 * 24 * 60)

        #expect(harness.system.ntfyMessages.isEmpty)
    }

    // MARK: Failed sends

    @Test func aFailedSendIsLoggedWithoutTheTopicOrToken() async {
        let harness = harnessWithNtfy(token: "example-token")
        harness.system.nextBackup = .fails(result: 19)
        harness.system.ntfyResult = .failed("couldn't reach https://ntfy.example/\(Self.topic) with example-token")

        await harness.start()

        let ntfyLines = harness.system.logLines.filter { $0.contains("ntfy") }
        #expect(ntfyLines.count == 1)
        #expect(ntfyLines.first?.hasPrefix("Couldn't send the \"Backup failed\" phone alert through ntfy") == true)
        for line in harness.system.logLines {
            #expect(!line.contains(Self.topic))
            #expect(!line.contains("example-token"))
        }
    }

    @Test func failedSendsNeverHoldBackBackups() async {
        let harness = harnessWithNtfy()
        harness.system.nextBackup = .fails(result: 19)
        harness.system.ntfyResult = .failed("the server answered 500")
        harness.at(minutes: 30) { $0.nextBackup = .succeeds }

        await harness.start() // fails at 00:20
        await harness.advance(minutes: 24 * 60 + 120)

        #expect(harness.system.startedBackups == [harness.minutes(0), harness.minutes(80), harness.minutes(24 * 60 + 100)])
        #expect(harness.statusLine == "Last backup: today 02:00")
    }

    // MARK: Send test message

    @Test func theTestButtonSendsATestMessageAndSaysItWorked() async {
        let harness = harnessWithNtfy(token: "example-token")

        let report = await harness.scheduler.sendTestMessage()

        #expect(report == .sent)
        #expect(report.message == "Test message sent. Check that it arrived on your phone.")
        #expect(harness.system.ntfyMessages == [
            NtfyMessage(
               settings: NtfySettings(server: "https://ntfy.example", topic: Self.topic, token: "example-token"),
                title: "BackMeUp test message",
                body: "Phone alerts from BackMeUp will arrive here.",
                tags: [.success]
            ),
        ])
    }

    @Test func theTestButtonSaysWhySendingFailed() async {
        let harness = harnessWithNtfy()
        harness.system.ntfyResult = .failed("the server answered 403")

        let report = await harness.scheduler.sendTestMessage()

        #expect(report == .failed("the server answered 403"))
        #expect(report.message == "Couldn't send the test message: the server answered 403.")
        #expect(harness.system.logLines.count == 1)
    }

    @Test func theTestButtonAsksForATopicFirst() async {
        let harness = SchedulerHarness()

        let report = await harness.scheduler.sendTestMessage()

        #expect(report == .needsTopic)
        #expect(report.message == "Enter a topic first.")
        #expect(harness.system.ntfyMessages.isEmpty)
    }
}
