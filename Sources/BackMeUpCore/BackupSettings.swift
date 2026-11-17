import Foundation

/// How often backups run: every N hours, days or weeks after the last success.
public struct BackupInterval: Codable, Equatable, Sendable {
    public enum Unit: String, Codable, CaseIterable, Sendable {
        case hours, days, weeks
    }

    public var count: Int
    public var unit: Unit

    public init(count: Int, unit: Unit) {
        self.count = count
        self.unit = unit
    }

    func date(after date: Date, in calendar: Calendar) -> Date {
        let component: Calendar.Component = switch unit {
        case .hours: .hour
        case .days: .day
        case .weeks: .weekOfYear
        }
        return calendar.date(byAdding: component, value: count, to: date) ?? date
    }
}

public struct BackupSettings: Codable, Equatable, Sendable {
    public static let minimumRetryMinutes = 15
    public static let standard = BackupSettings(
        backupInterval: BackupInterval(count: 1, unit: .days),
        retryMinutes: 60
    )

    public var backupInterval: BackupInterval
    /// How long to wait after a failed or skipped backup before trying again.
    public var retryMinutes: Int

    /// When to alert. Stored as an optional so settings saved before alerts existed still load.
    private var storedAlerts: AlertSettings?
    public var alerts: AlertSettings {
        get { storedAlerts ?? .standard }
        set { storedAlerts = newValue }
    }

    public init(backupInterval: BackupInterval, retryMinutes: Int) {
        self.backupInterval = backupInterval
        self.retryMinutes = retryMinutes
    }

    /// The same settings, raised to the minimums: an interval of at least 1, and retries at
    /// least `minimumRetryMinutes` apart.
    public var validated: BackupSettings {
        var settings = self
        settings.backupInterval.count = max(1, backupInterval.count)
        settings.retryMinutes = max(Self.minimumRetryMinutes, retryMinutes)
        settings.alerts = alerts.validated
        return settings
    }
}
