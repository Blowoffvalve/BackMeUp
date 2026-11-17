import Foundation
import Testing
import BackMeUpCore

/// The battery rule, and keeping the Mac awake while a backup runs on power.
@MainActor
@Suite("Battery and sleep")
struct PowerTests {
    static let networkDisk = DestinationInfo.configured(Destination(kind: .network, id: "network-id"))

    func harnessWithNetworkDisk(on power: PowerSource) -> SchedulerHarness {
        let harness = SchedulerHarness()
        harness.system.destinationInfo = Self.networkDisk
        harness.system.powerSource = power
        return harness
    }

    // MARK: Keeping the Mac awake

    @Test func idleSleepIsPreventedWhileABackupRunsOnPower() async {
        let harness = harnessWithNetworkDisk(on: .ac)
        harness.system.nextBackup = .lasting(minutes: 30)
        #expect(!harness.system.isPreventingIdleSleep)

        await harness.start()
        #expect(harness.system.isPreventingIdleSleep)

        await harness.advance(minutes: 29)
        #expect(harness.system.isPreventingIdleSleep)

        await harness.advance(minutes: 1)
        #expect(!harness.system.isPreventingIdleSleep)
        #expect(harness.statusLine == "Last backup: today 00:30")
    }

    @Test func itIsReleasedWhenTheBackupFails() async {
        let harness = harnessWithNetworkDisk(on: .ac)
        await harness.start() // the first backup succeeds
        harness.system.nextBackup = .lasting(minutes: 30, result: 19)

        await harness.backUpNow()
        #expect(harness.system.isPreventingIdleSleep)

        await harness.advance(minutes: 30)
        #expect(!harness.system.isPreventingIdleSleep)
        #expect(harness.statusLine == "Last backup failed: Time Machine reported error 19")
    }

    @Test func itIsReleasedOnBatteryAndHeldAgainWhenPluggedBackIn() async {
        let harness = harnessWithNetworkDisk(on: .ac)
        harness.system.nextBackup = .lasting(minutes: 60)
        harness.at(minutes: 10) { $0.powerSource = .battery }
        harness.at(minutes: 20) { $0.powerSource = .ac }

        await harness.start()
        await harness.advance(minutes: 10)
        #expect(!harness.system.isPreventingIdleSleep)

        await harness.advance(minutes: 10)
        #expect(harness.system.isPreventingIdleSleep)
    }

    @Test func aBackupOnBatteryNeverKeepsTheMacAwake() async {
        let harness = harnessWithNetworkDisk(on: .battery)
        harness.system.nextBackup = .lasting(minutes: 30)

        await harness.start()

        #expect(harness.system.startedBackups.count == 1)
        #expect(!harness.system.isPreventingIdleSleep)
    }

    @Test func itIsReleasedWhenBackMeUpQuits() async {
        let harness = harnessWithNetworkDisk(on: .ac)
        harness.system.nextBackup = .lasting(minutes: 30)
        await harness.start()

        harness.quit()

        #expect(!harness.system.isPreventingIdleSleep)
    }

    // MARK: The battery rule

    @Test func backupsRunOnBatteryByDefault() async {
        let harness = harnessWithNetworkDisk(on: .battery)

        await harness.start()

        #expect(harness.system.startedBackups == [harness.startDate])
        #expect(harness.scheduler.settings.allowBackupsOnBattery)
    }

    @Test func onBatteryWithBatteryBackupsOffTheRunIsSkipped() async {
        let harness = harnessWithNetworkDisk(on: .battery)
        harness.changeSettings { $0.allowBackupsOnBattery = false }

        await harness.start()

        #expect(harness.system.startedBackups.isEmpty)
        #expect(harness.statusLine == "Backup skipped: on battery")
        #expect(harness.nextBackupLine == "Next try: today 01:00")
        #expect(harness.scheduler.skipReason == .onBattery)
    }

    @Test func aSkippedRunOnBatteryRunsAtTheNextTryOncePluggedIn() async {
        let harness = harnessWithNetworkDisk(on: .battery)
        harness.changeSettings { $0.allowBackupsOnBattery = false }
        harness.at(minutes: 30) { $0.powerSource = .ac }

        await harness.start()
        await harness.advance(minutes: 60)

        #expect(harness.system.startedBackups == [harness.minutes(60)])
        #expect(harness.scheduler.skipReason == nil)
    }

    @Test func backUpNowRunsOnBatteryEvenWithBatteryBackupsOff() async {
        // The setting holds back scheduled backups; choosing Back Up Now is the person's own call.
        let harness = harnessWithNetworkDisk(on: .battery)
        harness.changeSettings { $0.allowBackupsOnBattery = false }
        await harness.start()

        await harness.backUpNow()

        #expect(harness.system.startedBackups == [harness.startDate])
        #expect(harness.statusLine == "Last backup: today 00:20")
    }
}
