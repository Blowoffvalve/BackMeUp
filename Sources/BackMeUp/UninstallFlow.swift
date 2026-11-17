import AppKit
import BackMeUpCore

/// The menu's Uninstall… item: asks first, has the scheduler remove BackMeUp's login item,
/// settings and Keychain items, reminds the user to turn Time Machine's automatic backups back
/// on, then quits so the app can be dragged to the Trash. Never touches Time Machine itself.
@MainActor
enum UninstallFlow {
    /// `removeMenuBarIcon` runs once everything is removed, before the reminder shows.
    static func run(scheduler: Scheduler, removeMenuBarIcon: () -> Void) {
        NSApp.activate(ignoringOtherApps: true)
        guard confirm() else { return }

        scheduler.uninstall()
        removeMenuBarIcon()

        if showReminder(), !scheduler.openTimeMachineSettings() {
            showDirections()
        }
        // applicationWillTerminate calls prepareToQuit, which deletes the settings once more.
        NSApp.terminate(nil)
    }

    /// Asks before removing anything. Cancel is the default button.
    private static func confirm() -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = Uninstall.confirmationTitle
        alert.informativeText = Uninstall.confirmationText
        let uninstall = alert.addButton(withTitle: Uninstall.confirmButton)
        let cancel = alert.addButton(withTitle: Uninstall.cancelButton)
        uninstall.hasDestructiveAction = true
        uninstall.keyEquivalent = ""
        cancel.keyEquivalent = "\r"
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// Returns true if the user chose to open Time Machine settings.
    private static func showReminder() -> Bool {
        let alert = NSAlert()
        alert.messageText = Uninstall.reminderTitle
        alert.informativeText = Uninstall.reminderText
        alert.addButton(withTitle: Uninstall.openSettingsButton)
        alert.addButton(withTitle: Uninstall.quitButton)
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// When Time Machine settings couldn't be opened: says how to get there by hand.
    private static func showDirections() {
        let alert = NSAlert()
        alert.messageText = "Time Machine settings couldn't be opened"
        alert.informativeText = Uninstall.reminderDirections
        alert.addButton(withTitle: Uninstall.quitButton)
        alert.runModal()
    }
}
