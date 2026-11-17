import Foundation

/// A message telling the user that backups have stopped, or started working again.
///
/// The scheduler decides when to send one and what it says. Each channel (a Mac notification,
/// later an ntfy message) delivers the same title and body.
public struct Alert: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        /// Backups started and didn't finish, enough times in a row.
        case failed
        /// No successful backup for too long, whatever the reason.
        case overdue
        /// The first success after an alert.
        case workingAgain
    }

    public var kind: Kind
    public var title: String
    public var body: String

    public init(kind: Kind, title: String, body: String) {
        self.kind = kind
        self.title = title
        self.body = body
    }
}
