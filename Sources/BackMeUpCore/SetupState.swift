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
    /// The app version (`CFBundleVersion`) that last launched, to spot the first launch after an
    /// update. nil if it was never recorded, for example by a version from before updates existed.
    public var lastLaunchedVersion: String?
    /// Router addresses of networks BackMeUp has already asked about allowing (after a new
    /// router, say), so it asks only once per network. nil in state saved before it existed.
    public var networksAskedAbout: [String]?
    /// Time Machine's ID for the disk BackMeUp last backed up to while it was the only disk, so
    /// that disk is kept when a second one is added. Not the user's choice. nil in state saved
    /// before it existed, so the first launch after that update asks instead.
    public var lastUsedDiskID: String?

    public init(firstRunDone: Bool = false, lastLaunchedVersion: String? = nil) {
        self.firstRunDone = firstRunDone
        self.lastLaunchedVersion = lastLaunchedVersion
    }
}
