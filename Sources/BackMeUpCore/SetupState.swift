import Foundation

/// Whether BackMeUp is in Login Items, from `SMAppService.mainApp.status`.
public enum LoginItemStatus: Equatable, Sendable {
    case enabled
    /// Registered, but the user has to allow it in Login Items.
    case requiresApproval
    case notRegistered
    /// macOS can't find the app to register, for example when it runs outside an app bundle.
    case notFound
}

/// Whether BackMeUp may show Mac notifications.
public enum NotificationPermission: Equatable, Sendable {
    case allowed
    case denied
    /// The user hasn't been asked yet.
    case notDetermined
}

/// The System Settings screens the checklist opens.
public enum SystemSettingsPane: Equatable, Sendable {
    case timeMachine
    case loginItems
    case notifications
}

/// What BackMeUp remembers about setting itself up. Values survive app restarts.
public struct SetupState: Codable, Equatable, Sendable {
    /// Whether the first run (adding the login item and showing the checklist) has happened.
    public var firstRunDone: Bool

    public init(firstRunDone: Bool = false) {
        self.firstRunDone = firstRunDone
    }
}
