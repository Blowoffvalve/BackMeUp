import Foundation

/// The System port as the scheduler uses it: once `uninstall()` is called, everything that would
/// save, start or send something is dropped, so nothing BackMeUp does afterwards can undo
/// Uninstall…. Reads, deletions and opening System Settings still go through.
///
/// The scheduler goes through this for every call, so a new save path can't forget the check.
@MainActor
final class UninstallableSystem: System {
    private let base: any System

    /// Whether Uninstall… has run.
    private(set) var isUninstalled = false

    init(_ base: any System) {
        self.base = base
    }

    func uninstall() {
        isUninstalled = true
    }

    // MARK: Reads, deletions and links: always allowed

    var now: Date { base.now }
    var powerSource: PowerSource { base.powerSource }
    var appVersion: String? { base.appVersion }
    func readTimeMachineStatus() async -> TimeMachineStatus { await base.readTimeMachineStatus() }
    func readBackupProgress() async -> BackupProgress? { await base.readBackupProgress() }
    func readDestinationInfo() async -> DestinationInfo { await base.readDestinationInfo() }
    func readPreferences() async -> TimeMachinePreferences? { await base.readPreferences() }
    func readNetwork() async -> NetworkReading { await base.readNetwork() }
    func readLoginItemStatus() -> LoginItemStatus { base.readLoginItemStatus() }
    func readNotificationPermission() async -> NotificationPermission { await base.readNotificationPermission() }
    func openSystemSettings(_ pane: SystemSettingsPane) -> Bool { base.openSystemSettings(pane) }
    func loadNetworks() -> NetworkSettings? { base.loadNetworks() }
    func loadSetupState() -> SetupState? { base.loadSetupState() }
    func loadSecret(_ secret: Secret) -> String? { base.loadSecret(secret) }
    func loadNtfyServer() -> String? { base.loadNtfyServer() }
    func loadHistory() -> BackupHistory? { base.loadHistory() }
    func loadSettings() -> BackupSettings? { base.loadSettings() }
    func unregisterLoginItem() { base.unregisterLoginItem() }
    func deleteAllSettings() { base.deleteAllSettings() }

    /// Letting the Mac sleep is always allowed; keeping it awake isn't after Uninstall….
    func setIdleSleepPrevented(_ prevented: Bool) {
        guard !prevented || !isUninstalled else { return }
        base.setIdleSleepPrevented(prevented)
    }

    /// Deleting a secret is always allowed; saving one isn't after Uninstall….
    func saveSecret(_ value: String?, as secret: Secret) {
        guard value == nil || !isUninstalled else { return }
        base.saveSecret(value, as: secret)
    }

    // MARK: Saving, starting and sending: dropped after Uninstall…

    func startBackup() async -> Int32? {
        guard !isUninstalled else { return nil }
        return await base.startBackup()
    }

    func showNotification(_ alert: Alert) {
        guard !isUninstalled else { return }
        base.showNotification(alert)
    }

    func registerLoginItem() -> LoginItemStatus {
        guard !isUninstalled else { return base.readLoginItemStatus() }
        return base.registerLoginItem()
    }

    func requestNotificationPermission() async -> NotificationPermission {
        guard !isUninstalled else { return await base.readNotificationPermission() }
        return await base.requestNotificationPermission()
    }

    func sendNtfy(_ message: NtfyMessage, completion: @escaping @MainActor (NtfySendResult) -> Void) {
        guard !isUninstalled else {
            completion(.failed("BackMeUp has been uninstalled"))
            return
        }
        base.sendNtfy(message, completion: completion)
    }

    func log(_ message: String) {
        guard !isUninstalled else { return }
        base.log(message)
    }

    func saveNetworks(_ networks: NetworkSettings) {
        guard !isUninstalled else { return }
        base.saveNetworks(networks)
    }

    func saveSetupState(_ state: SetupState) {
        guard !isUninstalled else { return }
        base.saveSetupState(state)
    }

    func saveNtfyServer(_ server: String) {
        guard !isUninstalled else { return }
        base.saveNtfyServer(server)
    }

    func saveHistory(_ history: BackupHistory) {
        guard !isUninstalled else { return }
        base.saveHistory(history)
    }

    func saveSettings(_ settings: BackupSettings) {
        guard !isUninstalled else { return }
        base.saveSettings(settings)
    }
}
