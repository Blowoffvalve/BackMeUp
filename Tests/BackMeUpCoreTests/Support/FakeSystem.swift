import Foundation
import BackMeUpCore

/// A System for tests: returns whatever state the test scripts, and keeps a simulated clock
/// that only moves when the test (or `SchedulerHarness`) moves it.
@MainActor
final class FakeSystem: System {
    var now: Date
    var timeMachineStatus: TimeMachineStatus = .idle
    var destinationInfo: DestinationInfo = .notSetUp

    init(now: Date) {
        self.now = now
    }

    func readTimeMachineStatus() async -> TimeMachineStatus {
        timeMachineStatus
    }

    func readDestinationInfo() async -> DestinationInfo {
        destinationInfo
    }
}
