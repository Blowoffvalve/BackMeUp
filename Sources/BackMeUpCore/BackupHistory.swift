import Foundation

/// Why a due backup wasn't started. Skips are never failures.
public enum SkipReason: String, Codable, Equatable, Sendable {
    /// Time Machine has no backup disk.
    case noDiskSetUp
    /// The backup disk is a local disk that isn't mounted.
    case diskNotConnected
    /// The Mac is on battery and backups on battery are turned off.
    case onBattery

    public var description: String {
        switch self {
        case .noDiskSetUp: "no Time Machine disk set up"
        case .diskNotConnected: "backup disk not connected"
        case .onBattery: "on battery"
        }
    }

    /// How the overdue alert explains this reason, as a sentence. `since` names the day the first
    /// skip for this reason happened since the last success: "today", "yesterday", "Friday" or
    /// "3 January". The alert code needs nothing else from a new reason.
    public func alertSentence(since: String) -> String {
        switch self {
        case .noDiskSetUp: "Time Machine has no backup disk set up."
        case .diskNotConnected: "The backup disk hasn't been connected since \(since)."
        case .onBattery: "Your Mac has been on battery each time a backup was due since \(since)."
        }
    }
}

/// Why a backup that was started didn't succeed.
public enum FailureReason: Codable, Equatable, Sendable {
    /// `tmutil` couldn't be run.
    case couldNotStart
    /// `tmutil startbackup` exited with a non-zero code.
    case exitCode(Int32)
    /// `tmutil` exited 0 but the destination's `RESULT` wasn't 0.
    case result(Int)
    /// `tmutil` exited 0 but the destination's `RESULT` couldn't be read.
    case resultUnreadable

    public var description: String {
        switch self {
        case .couldNotStart: "couldn't start Time Machine"
        case let .exitCode(code): "Time Machine stopped with code \(code)"
        case let .result(code): "Time Machine reported error \(code)"
        case .resultUnreadable: "couldn't read Time Machine's result"
        }
    }
}

public struct BackupAttempt: Codable, Equatable, Sendable {
    public enum Outcome: Codable, Equatable, Sendable {
        case succeeded
        case failed(FailureReason)
        case skipped(SkipReason)
        /// The first backup stopped before finishing, with no error result. Not a failure: it
        /// resumes at the next try.
        case paused
    }

    public var started: Date
    public var finished: Date
    public var outcome: Outcome

    public init(started: Date, finished: Date, outcome: Outcome) {
        self.started = started
        self.finished = finished
        self.outcome = outcome
    }
}

/// What BackMeUp remembers about its backups across restarts.
public struct BackupHistory: Codable, Equatable, Sendable {
    /// How many attempts are kept. Older ones are dropped.
    public static let maximumAttempts = 200

    /// When the last successful backup finished.
    public var lastSuccess: Date?
    /// Oldest first.
    public var attempts: [BackupAttempt]
    /// When the latest alert about the current problem was sent. nil when no problem has been
    /// alerted since the last success.
    public var lastAlertSent: Date?
    /// When BackMeUp first ran. Before the first success, backups are overdue counted from here.
    public var monitoringSince: Date?

    public init(lastSuccess: Date? = nil, attempts: [BackupAttempt] = []) {
        self.lastSuccess = lastSuccess
        self.attempts = attempts
    }

    mutating func record(_ attempt: BackupAttempt) {
        attempts.append(attempt)
        if attempts.count > Self.maximumAttempts {
            attempts.removeFirst(attempts.count - Self.maximumAttempts)
        }
        if attempt.outcome == .succeeded {
            lastSuccess = attempt.finished
        }
    }
}
