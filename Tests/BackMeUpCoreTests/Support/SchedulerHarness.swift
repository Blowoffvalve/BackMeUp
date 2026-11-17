import Foundation
import BackMeUpCore

/// Runs the real Scheduler against a FakeSystem over simulated time.
///
/// Script changes to the outside world with `at(minutes:_:)`, then call `advance(minutes:)`.
/// The clock moves one `Scheduler.tickInterval` at a time. At each step, scripted changes that are
/// due are applied to the fake, then the scheduler ticks, as the app's timer would make it.
@MainActor
final class SchedulerHarness {
    static let startDate = Date(timeIntervalSince1970: 1_767_225_600) // 2026-01-01 00:00 UTC

    let system: FakeSystem
    let scheduler: Scheduler
    let startDate: Date
    private var scripted: [(at: Date, change: (FakeSystem) -> Void)] = []

    init(startingAt start: Date = startDate) {
        startDate = start
        system = FakeSystem(now: start)
        scheduler = Scheduler(system: system)
    }

    var statusLine: String { scheduler.statusLine }

    /// Schedules a change to the outside world, in minutes after the start date.
    func at(minutes: Double, _ change: @escaping (FakeSystem) -> Void) {
        scripted.append((startDate.addingTimeInterval(minutes * 60), change))
    }

    /// Launches the app: applies changes due at the start, then ticks once.
    func start() async {
        applyDueChanges()
        await scheduler.tick()
    }

    /// Moves simulated time forward, ticking the scheduler at each step.
    func advance(minutes: Double) async {
        let end = system.now.addingTimeInterval(minutes * 60)
        while system.now < end {
            system.now = min(system.now.addingTimeInterval(Scheduler.tickInterval), end)
            applyDueChanges()
            await scheduler.tick()
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
