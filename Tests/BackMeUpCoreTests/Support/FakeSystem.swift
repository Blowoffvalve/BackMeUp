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
        /// Whether the backup stays running while `SchedulerHarness` moves the clock, so the test
        /// can look at the Mac mid-backup. Otherwise the clock jumps straight to its end.
        var runsWhileTimePasses = false

        static let succeeds = ScriptedBackup()
        static func fails(exitCode: Int32? = 0, result: Int? = 0, minutes: Double = 20) -> ScriptedBackup {
            ScriptedBackup(exitCode: exitCode, result: result, minutes: minutes)
        }
        /// A backup that keeps running for `minutes` of simulated time, then ends as scripted.
        static func lasting(minutes: Double, exitCode: Int32? = 0, result: Int? = 0) -> ScriptedBackup {
            ScriptedBackup(exitCode: exitCode, result: result, minutes: minutes, runsWhileTimePasses: true)
        }
    }

    var now: Date
    var timeMachineStatus: TimeMachineStatus = .idle
    var destinationInfo: DestinationInfo = .notSetUp
    var preferences: TimeMachinePreferences?
    var powerSource: PowerSource = .ac
    /// What Time Machine reports about a running backup's progress. Only read while one runs.
    var backupProgress: BackupProgress?
    /// Whether BackMeUp is holding its "prevent idle sleep" assertion.
    private(set) var isPreventingIdleSleep = false
    /// Every backup started through the port succeeds unless scripted otherwise.
    var nextBackup = ScriptedBackup.succeeds

    /// What's in settings storage. Survives `SchedulerHarness.restart()`, like `UserDefaults`.
    var storedHistory: BackupHistory?
    var storedSettings: BackupSettings?

    /// The simulated time each `tmutil startbackup` began.
    private(set) var startedBackups: [Date] = []

    init(now: Date) {
        self.now = now
    }

    /// Time Machine reports itself running while a backup started through the port runs.
    func readTimeMachineStatus() async -> TimeMachineStatus {
        runningBackup != nil ? .running : timeMachineStatus
    }

    func readBackupProgress() async -> BackupProgress? {
        runningBackup != nil || timeMachineStatus == .running ? backupProgress : nil
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
        let end = now.addingTimeInterval(backup.minutes * 60)
        if backup.runsWhileTimePasses {
            await withCheckedContinuation { runningBackup = (end, $0) }
        } else {
            now = end
        }
        writeResult(backup.result)
        if backup.preferencesUnreadableAfterwards { preferences = nil }
        return exitCode
    }

    // MARK: Backups that run while time passes

    private var runningBackup: (end: Date, continuation: CheckedContinuation<Void, Never>)?

    /// Whether a backup started through the port is waiting for the clock to reach its end.
    var isWaitingOnTheClock: Bool { runningBackup != nil }

    /// Lets a backup that runs while time passes finish, once the clock has reached its end.
    func finishBackupIfDue() {
        guard let backup = runningBackup, now >= backup.end else { return }
        runningBackup = nil
        backup.continuation.resume()
    }

    func setIdleSleepPrevented(_ prevented: Bool) {
        isPreventingIdleSleep = prevented
    }

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
