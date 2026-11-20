import Foundation
import BackMeUpCore
import Testing

/// Runs the real Scheduler against a FakeSystem over simulated time.
///
/// Script changes to the outside world with `at(minutes:_:)`, then call `advance(minutes:)`.
/// The clock moves one `Scheduler.tickInterval` at a time. At each step, scripted changes that are
/// due are applied to the fake, then the scheduler ticks, as the app's timer would make it.
/// A backup the scheduler starts runs to the end before the next step; the fake moves the clock
/// on by the backup's scripted duration. A backup scripted with `.lasting(minutes:)` instead keeps
/// running while the harness moves the clock, and ends at the first step at or after its end.
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
        watchChecklist()
    }

    /// How many times BackMeUp has shown the checklist window, across restarts.
    private(set) var checklistShown = 0

    private func watchChecklist() {
        scheduler.onShowChecklist = { [unowned self] in checklistShown += 1 }
    }

    private static func makeScheduler(_ system: FakeSystem) -> Scheduler {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return Scheduler(system: system, calendar: calendar)
    }

    var statusLine: String { scheduler.statusLine }
    var nextBackupLine: String { scheduler.nextBackupLine }
    /// The Mac notifications shown so far.
    var notifications: [Alert] { system.notifications.map(\.alert) }

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
        watchChecklist()
        await start()
    }

    /// Quits the app, as the menu's Quit item does.
    func quit() {
        scheduler.prepareToQuit()
    }

    /// Moves simulated time forward, ticking the scheduler at each step.
    func advance(minutes: Double) async {
        let end = system.now.addingTimeInterval(minutes * 60)
        while system.now < end {
            system.now = min(system.now.addingTimeInterval(Scheduler.tickInterval), end)
            applyDueChanges()
            system.finishBackupIfDue()
            await settle()
            await tick()
        }
    }

    /// Chooses Back Up Now in the menu, and waits for the backup to finish.
    func backUpNow() async {
        scheduler.backUpNow()
        await settle()
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
        await settle()
    }

    /// Waits until the backup BackMeUp started, if any, has finished and been recorded, or is
    /// running while time passes.
    private func settle() async {
        var turns = 0
        while scheduler.isBackingUp, !system.isWaitingOnTheClock {
            turns += 1
            if turns > 10_000 {
                Issue.record("The scheduler's backup never finished or waited on the clock")
                return
            }
            await Task.yield()
        }
    }

    private func applyDueChanges() {
        let due = scripted.filter { $0.at <= system.now }
        scripted.removeAll { $0.at <= system.now }
        for item in due.sorted(by: { $0.at < $1.at }) {
            item.change(system)
        }
    }
}
