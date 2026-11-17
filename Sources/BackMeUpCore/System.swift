import Foundation

/// The System port: the one interface between BackMeUp and everything outside it.
///
/// The scheduler sees the outside world only through this protocol. `RealSystem` talks to macOS;
/// tests use a fake that returns scripted states over simulated time. Later tickets add network
/// identity, power, notifications and the log here.
@MainActor
public protocol System {
    /// The clock.
    var now: Date { get }

    /// Whether Time Machine is backing up right now.
    func readTimeMachineStatus() async -> TimeMachineStatus

    /// Time Machine's backup disk, if any.
    func readDestinationInfo() async -> DestinationInfo

    /// Time Machine's preferences, or nil if they can't be read.
    func readPreferences() async -> TimeMachinePreferences?

    /// Runs `tmutil startbackup --auto --block`: starts a backup and waits for it to finish.
    /// Returns the exit code, or nil if the command couldn't be run.
    func startBackup() async -> Int32?

    /// Shows an alert as a Mac notification.
    func showNotification(_ alert: Alert)

    /// Settings storage. Values survive app restarts.
    func loadHistory() -> BackupHistory?
    func saveHistory(_ history: BackupHistory)
    func loadSettings() -> BackupSettings?
    func saveSettings(_ settings: BackupSettings)
}
