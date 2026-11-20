import Foundation

/// When BackMeUp alerts the user that backups have stopped.
public struct AlertSettings: Codable, Equatable, Sendable {
    public static let standard = AlertSettings(failuresInARow: 1, daysWithoutBackup: 3)

    /// Alert once this many started backups in a row haven't finished. Skips don't count.
    public var failuresInARow: Int
    /// Alert once there's been no successful backup for this many days, whatever the reason.
    public var daysWithoutBackup: Int

    public init(failuresInARow: Int, daysWithoutBackup: Int) {
        self.failuresInARow = failuresInARow
        self.daysWithoutBackup = daysWithoutBackup
    }

    /// Both thresholds at least 1.
    public var validated: AlertSettings {
        AlertSettings(failuresInARow: max(1, failuresInARow), daysWithoutBackup: max(1, daysWithoutBackup))
    }
}
