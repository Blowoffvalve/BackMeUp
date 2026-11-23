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
        /// Whether Time Machine records a new snapshot for the disk, as a finished backup does.
        var addsSnapshot = true
        /// Whether Time Machine started its own backup to this disk just before BackMeUp's command,
        /// so the command gives up straight away and `RESULT` is left as it was.
        var alreadyInProgress = false

        static let succeeds = ScriptedBackup()
        static func fails(exitCode: Int32? = 0, result: Int? = 0, minutes: Double = 20) -> ScriptedBackup {
            ScriptedBackup(exitCode: exitCode, result: result, minutes: minutes, addsSnapshot: false)
        }
        /// `tmutil` exits 0 and `RESULT` is still 0 from an earlier backup, but no new backup was
        /// made.
        static let staleResult = ScriptedBackup(exitCode: 0, result: 0, addsSnapshot: false)
        /// Time Machine started its own backup a moment before: `tmutil` prints "Backup already in
        /// progress." and exits 3 at once, as seen on macOS 27.2.
        static let alreadyInProgress = ScriptedBackup(exitCode: 3, result: nil, minutes: 0, addsSnapshot: false, alreadyInProgress: true)
        /// A backup that keeps running for `minutes` of simulated time, then ends as scripted.
        static func lasting(minutes: Double, exitCode: Int32? = 0, result: Int? = 0) -> ScriptedBackup {
            ScriptedBackup(
                exitCode: exitCode,
                result: result,
                minutes: minutes,
                runsWhileTimePasses: true,
                addsSnapshot: exitCode == 0 && result == 0
            )
        }
    }

    var now: Date
    var timeMachineStatus: TimeMachineStatus = .idle
    var destinationInfo: DestinationInfo = .notSetUp
    /// Starts with Time Machine's automatic backups off, as the checklist asks.
    var preferences: TimeMachinePreferences? = TimeMachinePreferences(autoBackup: false, destinations: [])
    /// Changing it tells whoever is watching straight away, as macOS's power source
    /// notification does.
    var powerSource: PowerSource = .ac {
        didSet { powerSourceWatchers.forEach { $0() } }
    }
    private var powerSourceWatchers: [@MainActor () -> Void] = []

    func watchPowerSource(_ onChange: @escaping @MainActor () -> Void) {
        powerSourceWatchers.append(onChange)
    }
    /// What Time Machine reports about a running backup's progress. Only read while one runs.
    var backupProgress: BackupProgress?
    /// Whether BackMeUp is holding its "prevent idle sleep" assertion.
    private(set) var isPreventingIdleSleep = false
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
    /// The `--destination` each `tmutil startbackup` was given, nil for none.
    private(set) var startedBackupDestinations: [String?] = []

    /// Every Mac notification shown, with the simulated time it was shown. Nothing real is posted.
    private(set) var notifications: [(date: Date, alert: Alert)] = []

    init(now: Date) {
        self.now = now
    }

    /// The stage name (`BackupPhase`) Time Machine reports for a backup started through the port
    /// while it runs. nil: running, with no stage named yet.
    var startedBackupPhase: String?

    /// Time Machine reports itself running while a backup started through the port runs.
    func readTimeMachineStatus() async -> TimeMachineStatus {
        runningBackup != nil ? .running(destinationID: backingUpTo, phase: startedBackupPhase) : timeMachineStatus
    }

    func readBackupProgress() async -> BackupProgress? {
        guard case .running = await readTimeMachineStatus() else { return nil }
        return backupProgress
    }

    func readDestinationInfo() async -> DestinationInfo {
        destinationInfo
    }

    func readPreferences() async -> TimeMachinePreferences? {
        if pausesNextPreferencesRead {
            pausesNextPreferencesRead = false
            await withCheckedContinuation { pausedPreferencesRead = $0 }
        }
        return preferences
    }

    /// Whether the next read of Time Machine's preferences waits for `resumePreferencesRead()`,
    /// so a test can act while a reading is in flight.
    var pausesNextPreferencesRead = false
    private var pausedPreferencesRead: CheckedContinuation<Void, Never>?
    /// Whether a read of Time Machine's preferences is waiting for `resumePreferencesRead()`.
    var isPreferencesReadPaused: Bool { pausedPreferencesRead != nil }

    func resumePreferencesRead() {
        pausedPreferencesRead?.resume()
        pausedPreferencesRead = nil
    }

    /// Records the command, moves the clock on by the scripted duration (the real command blocks
    /// until Time Machine finishes), and writes the scripted `RESULT` for the destination it was
    /// given, or the only one.
    func startBackup(destinationID: String?) async -> Int32? {
        let backup = nextBackup
        startedBackups.append(now)
        startedBackupDestinations.append(destinationID)
        backingUpTo = destinationID
        guard let exitCode = backup.exitCode else { return nil }
        if backup.alreadyInProgress {
            timeMachineStatus = .running(destinationID: destinationID)
            return exitCode
        }
        let end = now.addingTimeInterval(backup.minutes * 60)
        if backup.runsWhileTimePasses {
            await withCheckedContinuation { runningBackup = (end, $0) }
        } else {
            now = end
        }
        writeResult(backup.result, addingSnapshot: backup.addsSnapshot)
        if backup.preferencesUnreadableAfterwards { preferences = nil }
        return exitCode
    }

    func readNetwork() async -> NetworkReading {
        network
    }

    // MARK: Troubleshoot

    /// Whether the backup server answers on its file-sharing port.
    var serverAnswering = true
    /// Every server asked whether it answers.
    private(set) var serversAsked: [String] = []
    /// What Time Machine's log says about a lost mount during a backup: nil when the log can't be read.
    var timeMachineLogShowsLostMount: Bool? = true
    /// When the Mac last started up. Change it to simulate a restart.
    var bootTime: Date? = SchedulerHarness.startDate.addingTimeInterval(-3600)

    func serverAnswers(host: String) async -> Bool {
        serversAsked.append(host)
        return serverAnswering
    }

    func timeMachineLostItsMount(from start: Date, to end: Date) async -> Bool? {
        timeMachineLogShowsLostMount
    }

    func loadNetworks() -> NetworkSettings? { storedNetworks }
    func saveNetworks(_ networks: NetworkSettings) { storedNetworks = networks }
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

    func showNotification(_ alert: Alert) {
        notifications.append((now, alert))
    }

    // MARK: Login item, notifications and System Settings

    /// BackMeUp is in Login Items and notifications are allowed, unless a test says otherwise.
    var loginItemStatus = LoginItemStatus.enabled
    /// What registering the login item leads to.
    var loginItemStatusAfterRegistering = LoginItemStatus.enabled
    private(set) var loginItemRegistrations = 0
    private(set) var loginItemUnregistrations = 0
    var notificationPermission = NotificationPermission.allowed
    /// How the user answers when asked to allow notifications.
    var notificationAnswer = NotificationPermission.allowed
    private(set) var notificationPermissionRequests = 0
    /// Whether System Settings links open. Nothing real is opened either way.
    var settingsLinksOpen = true
    private(set) var openedSettings: [SystemSettingsPane] = []
    var storedSetupState: SetupState?
    /// The running app's version. Change it before `SchedulerHarness.restart()` to simulate an update.
    var appVersion: String? = "1.0"

    func readLoginItemStatus() -> LoginItemStatus { loginItemStatus }

    func registerLoginItem() -> LoginItemStatus {
        loginItemRegistrations += 1
        loginItemStatus = loginItemStatusAfterRegistering
        return loginItemStatus
    }

    func unregisterLoginItem() {
        loginItemUnregistrations += 1
        loginItemStatus = .notRegistered
    }

    func readNotificationPermission() async -> NotificationPermission { notificationPermission }

    func requestNotificationPermission() async -> NotificationPermission {
        guard notificationPermission == .notDetermined else { return notificationPermission }
        notificationPermissionRequests += 1
        notificationPermission = notificationAnswer
        return notificationPermission
    }

    func openSystemSettings(_ pane: SystemSettingsPane) -> Bool {
        guard settingsLinksOpen else { return false }
        openedSettings.append(pane)
        return true
    }

    func loadSetupState() -> SetupState? { storedSetupState }
    func saveSetupState(_ state: SetupState) { storedSetupState = state }

    // MARK: ntfy, the log and secrets

    /// Every ntfy message sent through the port. Nothing real is sent.
    private(set) var ntfyMessages: [NtfyMessage] = []
    /// How the next ntfy sends turn out.
    var ntfyResult = NtfySendResult.sent
    /// Every line written to the log since it was last deleted.
    private(set) var logLines: [String] = []
    /// Whether the log opens. Nothing real is opened either way.
    var logOpens = true
    private(set) var logOpenings = 0
    private(set) var logDeletions = 0
    /// What's in the Keychain. Survives `SchedulerHarness.restart()`.
    var secrets: [Secret: String] = [:]
    var storedNtfyServer: String?

    func sendNtfy(_ message: NtfyMessage, completion: @escaping @MainActor (NtfySendResult) -> Void) {
        ntfyMessages.append(message)
        completion(ntfyResult)
    }

    func log(_ message: String) { logLines.append(message) }

    func openLog() -> Bool {
        guard logOpens else { return false }
        logOpenings += 1
        return true
    }

    func deleteLog() {
        logLines = []
        logDeletions += 1
    }
    func loadSecret(_ secret: Secret) -> String? { secrets[secret] }
    func saveSecret(_ value: String?, as secret: Secret) { secrets[secret] = value }
    func loadNtfyServer() -> String? { storedNtfyServer }
    func saveNtfyServer(_ server: String) { storedNtfyServer = server }

    func loadHistory() -> BackupHistory? { storedHistory }
    func saveHistory(_ history: BackupHistory) { storedHistory = history }
    func loadSettings() -> BackupSettings? { storedSettings }
    func saveSettings(_ settings: BackupSettings) { storedSettings = settings }

    /// Empties settings storage, as removing BackMeUp's `UserDefaults` does. Leaves the Keychain.
    func deleteAllSettings() {
        storedHistory = nil
        storedSettings = nil
        storedNetworks = nil
        storedSetupState = nil
        storedNtfyServer = nil
    }

    /// The `--destination` of the backup running or last run.
    private var backingUpTo: String?

    private func writeResult(_ result: Int?, addingSnapshot: Bool) {
        // Time Machine backs up to the --destination given, or the only disk.
        let disks = destinationInfo.disks
        guard backingUpTo != nil || disks.count == 1 else { return }
        let id = backingUpTo ?? disks[0].id
        var preferences = preferences ?? TimeMachinePreferences(autoBackup: false, destinations: [])
        let entry = preferences.destination(id: id)
        let encryption = entry?.encryption ?? .encrypted
        let snapshotDates = (entry?.snapshotDates ?? []) + (addingSnapshot ? [now] : [])
        preferences.destinations.removeAll { $0.id == id }
        preferences.destinations.append(.init(id: id, encryption: encryption, result: result, snapshotDates: snapshotDates))
        self.preferences = preferences
    }
}
