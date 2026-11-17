import Foundation

/// The System port: the one interface between BackMeUp and everything outside it.
///
/// The scheduler sees the outside world only through this protocol. `RealSystem` talks to macOS;
/// tests use a fake that returns scripted states over simulated time. Later tickets add starting
/// backups, network identity, power, notifications, settings storage and the log here.
@MainActor
public protocol System {
    /// The clock.
    var now: Date { get }

    /// Whether Time Machine is backing up right now.
    func readTimeMachineStatus() async -> TimeMachineStatus

    /// Time Machine's backup disk, if any.
    func readDestinationInfo() async -> DestinationInfo
}
