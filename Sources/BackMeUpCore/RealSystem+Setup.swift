import AppKit
import Foundation
import ServiceManagement
import UserNotifications

/// The checklist's view of the real Mac: Login Items, notification permission and System Settings.
extension RealSystem {
    // MARK: Login item

    public func readLoginItemStatus() -> LoginItemStatus {
        guard Bundle.main.bundleIdentifier != nil else { return .notFound }
        return LoginItemStatus(SMAppService.mainApp.status)
    }

    public func registerLoginItem() -> LoginItemStatus {
        guard Bundle.main.bundleIdentifier != nil else { return .notFound }
        // Throws when macOS refuses, or when the user has to approve it; the status says which.
        try? SMAppService.mainApp.register()
        return readLoginItemStatus()
    }

    // MARK: Version

    public var appVersion: String? {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
    }

    // MARK: Notifications

    public func readNotificationPermission() async -> NotificationPermission {
        // UNUserNotificationCenter needs an app bundle; outside one it traps.
        guard Bundle.main.bundleIdentifier != nil else { return .denied }
        let status = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
        return NotificationPermission(status)
    }

    public func requestNotificationPermission() async -> NotificationPermission {
        guard Bundle.main.bundleIdentifier != nil else { return .denied }
        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
        return await readNotificationPermission()
    }

    // MARK: System Settings

    public func openSystemSettings(_ pane: SystemSettingsPane) -> Bool {
        let link: String
        switch pane {
        case .loginItems:
            SMAppService.openSystemSettingsLoginItems()
            return true
        case .timeMachine:
            link = "x-apple.systempreferences:com.apple.Time-Machine-Settings.extension"
        case .notifications:
            let id = Bundle.main.bundleIdentifier ?? ""
            link = "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(id)"
        }
        guard let url = URL(string: link) else { return false }
        return NSWorkspace.shared.open(url)
    }
}

extension LoginItemStatus {
    init(_ status: SMAppService.Status) {
        switch status {
        case .enabled: self = .enabled
        case .requiresApproval: self = .requiresApproval
        case .notRegistered: self = .notRegistered
        case .notFound: self = .notFound
        @unknown default: self = .notRegistered
        }
    }
}

extension NotificationPermission {
    init(_ status: UNAuthorizationStatus) {
        switch status {
        case .authorized, .provisional, .ephemeral: self = .allowed
        case .denied: self = .denied
        case .notDetermined: self = .notDetermined
        @unknown default: self = .notDetermined
        }
    }
}
