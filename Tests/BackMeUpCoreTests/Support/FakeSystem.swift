import Foundation
import BackMeUpCore

/// A System for tests: returns whatever state the test scripts, and keeps a simulated clock
/// that only moves when the test (or `SchedulerHarness`) moves it.
@MainActor
final class FakeSystem: System {
    /// How the next backup started through the port turns out.
    struct ScriptedBackup {
        /// `tmutil startbackup`'s exit code, or nil if it couldn't be run at all.
        var exitCode: Int32? = 0
        /// The `RESULT` Time Machine writes for the destination afterwards. nil removes the key.
        var result: Int? = 0
        /// How long the backup blocks, in simulated minutes.
        var minutes: Double = 20
        /// Whether Time Machine's preferences can't be read once the backup ends.
        var preferencesUnreadableAfterwards = false

        static let succeeds = ScriptedBackup()
        static func fails(exitCode: Int32? = 0, result: Int? = 0, minutes: Double = 20) -> ScriptedBackup {
            ScriptedBackup(exitCode: exitCode, result: result, minutes: minutes)
        }
    }

    var now: Date
    var timeMachineStatus: TimeMachineStatus = .idle
    var destinationInfo: DestinationInfo = .notSetUp
    var preferences: TimeMachinePreferences?
    /// Every backup started through the port succeeds unless scripted otherwise.
    var nextBackup = ScriptedBackup.succeeds

    /// What's in settings storage. Survives `SchedulerHarness.restart()`, like `UserDefaults`.
    var storedHistory: BackupHistory?
    var storedSettings: BackupSettings?

    /// The chosen network the fake starts on, "Home", and its router's hardware address.
    nonisolated static let homeRouter = "02:00:00:00:00:01"
    nonisolated static let home = NetworkReading.router(address: homeRouter, wifiName: "Home")

    /// The network the Mac is on. Starts on Home, which `storedNetworks` has as chosen.
    var network = FakeSystem.home
    var storedNetworks: NetworkSettings? = NetworkSettings(
        chosen: [ChosenNetwork(routerAddress: FakeSystem.homeRouter, label: "Home")]
    )

    /// The simulated time each `tmutil startbackup` began.
    private(set) var startedBackups: [Date] = []

    init(now: Date) {
        self.now = now
    }

    func readTimeMachineStatus() async -> TimeMachineStatus {
        timeMachineStatus
    }

    func readDestinationInfo() async -> DestinationInfo {
        destinationInfo
    }

    func readPreferences() async -> TimeMachinePreferences? {
        preferences
    }

    /// Records the command, moves the clock on by the scripted duration (the real command blocks
    /// until Time Machine finishes), and writes the scripted `RESULT` for the current destination.
    func startBackup() async -> Int32? {
        let backup = nextBackup
        startedBackups.append(now)
        guard let exitCode = backup.exitCode else { return nil }
        now = now.addingTimeInterval(backup.minutes * 60)
        writeResult(backup.result)
        if backup.preferencesUnreadableAfterwards { preferences = nil }
        return exitCode
    }

    func readNetwork() async -> NetworkReading {
        network
    }

    func loadNetworks() -> NetworkSettings? { storedNetworks }
    func saveNetworks(_ networks: NetworkSettings) { storedNetworks = networks }

    func loadHistory() -> BackupHistory? { storedHistory }
    func saveHistory(_ history: BackupHistory) { storedHistory = history }
    func loadSettings() -> BackupSettings? { storedSettings }
    func saveSettings(_ settings: BackupSettings) { storedSettings = settings }

    private func writeResult(_ result: Int?) {
        guard case let .configured(destination) = destinationInfo else { return }
        var preferences = preferences ?? TimeMachinePreferences(autoBackup: false, destinations: [])
        preferences.destinations.removeAll { $0.id == destination.id }
        preferences.destinations.append(.init(id: destination.id, encryption: .encrypted, result: result))
        self.preferences = preferences
    }
}
