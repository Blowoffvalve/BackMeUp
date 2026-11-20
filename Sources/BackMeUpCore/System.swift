import Foundation

/// The System port: the one interface between BackMeUp and everything outside it.
///
/// The scheduler sees the outside world only through this protocol. `RealSystem` talks to macOS;
/// tests use a fake that returns scripted states over simulated time. It covers Time Machine,
/// network identity, power, notifications, the login item, ntfy, the log, the Keychain and settings
/// storage.
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

    /// Runs `tmutil startbackup --auto --block`, with `--destination <ID>` when one is given: starts
    /// a backup and waits for it to finish. Returns the exit code, or nil if the command couldn't
    /// be run.
    func startBackup(destinationID: String?) async -> Int32?

    /// The network the Mac is on, identified by its router's hardware address: the default route
    /// on a physical interface (never a VPN), looked up in the ARP table. Sends nothing on the
    /// network. The Wi-Fi name is included only when Location permission allows it.
    func readNetwork() async -> NetworkReading

    /// Chosen networks and the "all networks" switch. Values survive app restarts.
    func loadNetworks() -> NetworkSettings?
    func saveNetworks(_ networks: NetworkSettings)
    /// What the Mac is running on right now.
    var powerSource: PowerSource { get }
    /// Calls `onChange` on the main actor whenever macOS says the power source may have changed
    /// (plugged in, unplugged, or the battery level moved), for as long as the app runs.
    func watchPowerSource(_ onChange: @escaping @MainActor () -> Void)

    /// Holds or releases BackMeUp's power assertion that stops the Mac sleeping when idle. Closing
    /// the lid still sleeps it. Calling it again with the same value does nothing.
    func setIdleSleepPrevented(_ prevented: Bool)

    /// Shows an alert as a Mac notification, if notifications are allowed. Never asks for
    /// permission; only `requestNotificationPermission()` does, from checklist check 5.
    func showNotification(_ alert: Alert)

    /// Whether BackMeUp opens at login.
    func readLoginItemStatus() -> LoginItemStatus
    /// Adds BackMeUp to Login Items (`SMAppService.mainApp.register()`) and returns the status
    /// afterwards. macOS may refuse, or want the user's approval.
    func registerLoginItem() -> LoginItemStatus
    /// Removes BackMeUp from Login Items (`SMAppService.mainApp.unregister()`), for Uninstall….
    func unregisterLoginItem()

    /// Whether BackMeUp may show notifications.
    func readNotificationPermission() async -> NotificationPermission
    /// Asks the user to allow notifications, if they haven't been asked, and returns the answer.
    func requestNotificationPermission() async -> NotificationPermission

    /// Opens a System Settings screen. Returns false if it couldn't be opened.
    func openSystemSettings(_ pane: SystemSettingsPane) -> Bool

    /// The running app's build version (`CFBundleVersion`), or nil outside an app bundle. A
    /// different version from the last launch means Sparkle has installed an update.
    var appVersion: String? { get }

    /// What BackMeUp remembers about setting itself up.
    func loadSetupState() -> SetupState?
    func saveSetupState(_ state: SetupState)

    /// Sends a message through ntfy as an HTTP POST, and calls `completion` on the main actor
    /// when it has been sent or has failed. Never waits for the network itself.
    func sendNtfy(_ message: NtfyMessage, completion: @escaping @MainActor (NtfySendResult) -> Void)

    /// Writes a line to BackMeUp's log, a plain-text file the user can open with Show Log. Never
    /// pass it a secret, a network's name or a router's address.
    func log(_ message: String)
    /// Opens the log file for the user. Returns false if it couldn't be opened.
    func openLog() -> Bool
    /// Deletes the log file, for Uninstall….
    func deleteLog()

    /// Secret storage: the Keychain. nil deletes the value.
    func loadSecret(_ secret: Secret) -> String?
    func saveSecret(_ value: String?, as secret: Secret)
    /// The ntfy server address, kept with the other settings (it isn't secret).
    func loadNtfyServer() -> String?
    func saveNtfyServer(_ server: String)

    /// Settings storage. Values survive app restarts.
    func loadHistory() -> BackupHistory?
    func saveHistory(_ history: BackupHistory)
    func loadSettings() -> BackupSettings?
    func saveSettings(_ settings: BackupSettings)

    /// Deletes everything BackMeUp keeps in settings storage (all of its `UserDefaults`), for
    /// Uninstall…. Secrets in the Keychain are deleted separately, through `saveSecret(nil, as:)`.
    func deleteAllSettings()
}
