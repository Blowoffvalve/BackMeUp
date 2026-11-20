import Foundation

/// What the Mac is running on.
public enum PowerSource: Equatable, Sendable {
    /// Plugged in, or a Mac without a battery.
    case ac
    case battery
    /// Couldn't be read. Treated like AC power: backups aren't held back by a reading that failed.
    case unknown
}
