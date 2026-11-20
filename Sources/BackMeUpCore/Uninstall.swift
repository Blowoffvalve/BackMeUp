/// The words for Uninstall…: the confirmation before anything is removed, and the reminder to
/// turn Time Machine's automatic backups back on afterwards. `Scheduler.uninstall()` does the work.
public enum Uninstall {
    public static let confirmationTitle = "Uninstall BackMeUp?"
    public static let confirmationText = """
        This removes BackMeUp from Login Items and deletes its settings, its backup history and \
        its phone alert details from the Keychain. Then BackMeUp quits.

        Your Time Machine backups and Time Machine's settings aren't touched.
        """
    public static let confirmButton = "Uninstall"
    public static let cancelButton = "Cancel"

    public static let reminderTitle = "Turn Time Machine's automatic backups back on"
    public static let reminderText = """
        BackMeUp has been removed. Without it, your Mac won't back up until Time Machine's \
        automatic backups are back on. In Time Machine settings, click Options and set Back up \
        frequency to one of the Automatically options.

        Then drag BackMeUp from your Applications folder to the Trash.
        """
    public static let openSettingsButton = "Open Time Machine Settings"
    public static let quitButton = "Quit"

    /// Shown instead when Time Machine settings can't be opened.
    public static let reminderDirections = """
        Open System Settings, then General > Time Machine. Click Options and set Back up \
        frequency to one of the Automatically options.
        """
}
