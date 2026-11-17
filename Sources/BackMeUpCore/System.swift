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

    /// How far the running backup has got, or nil if Time Machine doesn't say.
    func readBackupProgress() async -> BackupProgress?

    /// Time Machine's backup disk, if any.
    func readDestinationInfo() async -> DestinationInfo

    /// Time Machine's preferences, or nil if they can't be read.
    func readPreferences() async -> TimeMachinePreferences?

    /// Runs `tmutil startbackup --auto --block`: starts a backup and waits for it to finish.
    /// Returns the exit code, or nil if the command couldn't be run.
    func startBackup() async -> Int32?

    /// The network the Mac is on, identified by its router's hardware address: the default route
    /// on a physical interface (never a VPN), looked up in the ARP table. Sends nothing on the
    /// network. The Wi-Fi name is included only when Location permission allows it.
    func readNetwork() async -> NetworkReading

    /// Chosen networks and the "all networks" switch. Values survive app restarts.
    func loadNetworks() -> NetworkSettings?
    func saveNetworks(_ networks: NetworkSettings)
    /// What the Mac is running on right now.
    var powerSource: PowerSource { get }

    /// Holds or releases BackMeUp's power assertion that stops the Mac sleeping when idle. Closing
    /// the lid still sleeps it. Calling it again with the same value does nothing.
    func setIdleSleepPrevented(_ prevented: Bool)

    /// Settings storage. Values survive app restarts.
    func loadHistory() -> BackupHistory?
    func saveHistory(_ history: BackupHistory)
    func loadSettings() -> BackupSettings?
    func saveSettings(_ settings: BackupSettings)
}
