import Foundation
import BackMeUpCore

/// Runs the real Scheduler against a FakeSystem over simulated time.
///
/// Script changes to the outside world with `at(minutes:_:)`, then call `advance(minutes:)`.
/// The clock moves one `Scheduler.tickInterval` at a time. At each step, scripted changes that are
/// due are applied to the fake, then the scheduler ticks, as the app's timer would make it.
/// A backup the scheduler starts runs to the end before the next step; the fake moves the clock
/// on by the backup's scripted duration.
///
/// Dates in the menu are formatted in UTC, so "today" is the UTC day of `system.now`.
@MainActor
final class SchedulerHarness {
    static let startDate = Date(timeIntervalSince1970: 1_767_225_600) // 2026-01-01 00:00 UTC

    let system: FakeSystem
    private(set) var scheduler: Scheduler
    let startDate: Date
    private var scripted: [(at: Date, change: (FakeSystem) -> Void)] = []

    init(startingAt start: Date = startDate) {
        startDate = start
        system = FakeSystem(now: start)
        scheduler = Self.makeScheduler(system)
    }

    private static func makeScheduler(_ system: FakeSystem) -> Scheduler {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return Scheduler(system: system, calendar: calendar)
    }

    var statusLine: String { scheduler.statusLine }
    var nextBackupLine: String { scheduler.nextBackupLine }

    /// Minutes since the start date, for readable expectations.
    func minutes(_ minutes: Double) -> Date {
        startDate.addingTimeInterval(minutes * 60)
    }

    /// Schedules a change to the outside world, in minutes after the start date.
    func at(minutes: Double, _ change: @escaping (FakeSystem) -> Void) {
        scripted.append((startDate.addingTimeInterval(minutes * 60), change))
    }

    /// Launches the app: applies changes due at the start, then ticks once.
    func start() async {
        applyDueChanges()
        await tick()
    }

    /// Quits and relaunches the app: a new Scheduler over the same outside world and storage.
    func restart() async {
        scheduler = Self.makeScheduler(system)
        await start()
    }

    /// Moves simulated time forward, ticking the scheduler at each step.
    func advance(minutes: Double) async {
        let end = system.now.addingTimeInterval(minutes * 60)
        while system.now < end {
            system.now = min(system.now.addingTimeInterval(Scheduler.tickInterval), end)
            applyDueChanges()
            await tick()
        }
    }

    /// Chooses Back Up Now in the menu, and waits for the backup to finish.
    func backUpNow() async {
        scheduler.backUpNow()
        await scheduler.waitForBackup()
    }

    /// Changes settings, as the Settings window does.
    func changeSettings(_ change: (inout BackupSettings) -> Void) {
        var settings = scheduler.settings
        change(&settings)
        scheduler.updateSettings(settings)
    }

    /// Changes chosen networks or the "all networks" switch, as the Settings window does.
    func changeNetworks(_ change: (inout NetworkSettings) -> Void) {
        var networks = scheduler.networks
        change(&networks)
        scheduler.updateNetworks(networks)
    }

    private func tick() async {
        await scheduler.tick()
        await scheduler.waitForBackup()
    }

    private func applyDueChanges() {
        let due = scripted.filter { $0.at <= system.now }
        scripted.removeAll { $0.at <= system.now }
        for item in due.sorted(by: { $0.at < $1.at }) {
            item.change(system)
        }
    }
}
