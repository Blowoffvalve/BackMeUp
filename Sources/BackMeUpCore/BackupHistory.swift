import Foundation

/// Why a due backup wasn't started. Skips are never failures.
public enum SkipReason: String, Codable, Equatable, Sendable {
    /// Time Machine has no backup disk.
    case noDiskSetUp
    /// The backup disk is a local disk that isn't mounted.
    case diskNotConnected
    /// The backup disk is a network disk and the Mac isn't on a chosen network (or on none, or
    /// only on a VPN).
    case notOnChosenNetwork
    /// The backup disk is a network disk and the router's hardware address couldn't be read.
    case networkUnidentified
    /// The Mac is on battery and backups on battery are turned off.
    case onBattery
    /// A required checklist item (automatic backups off, a chosen network for a network disk, or
    /// one BackMeUp can't check) isn't done. A missing disk is `noDiskSetUp` instead.
    case setupNotFinished

    /// Whether this skip ends as soon as the checklist allows backups.
    public var isSetupReason: Bool {
        self == .noDiskSetUp || self == .setupNotFinished
    }

    /// Whether this skip ends as soon as the Mac is on a chosen network.
    public var isNetworkReason: Bool {
        self == .notOnChosenNetwork || self == .networkUnidentified
    }

    public var description: String {
        switch self {
        case .noDiskSetUp: "no Time Machine disk set up"
        case .diskNotConnected: "backup disk not connected"
        case .notOnChosenNetwork: "not on a chosen network"
        case .networkUnidentified: "couldn't identify this network"
        case .onBattery: "on battery"
        case .setupNotFinished: "setup isn't finished"
        }
    }

    /// How the overdue alert explains this reason, as a sentence. `since` names the day the first
    /// skip for this reason happened since the last success: "today", "yesterday", "Friday" or
    /// "3 January". The alert code needs nothing else from a new reason.
    public func alertSentence(since: String) -> String {
        switch self {
        case .noDiskSetUp: "Time Machine has no backup disk set up."
        case .diskNotConnected: "The backup disk hasn't been connected since \(since)."
        case .notOnChosenNetwork: "Your Mac hasn't been on a chosen network since \(since)."
        case .networkUnidentified: "BackMeUp hasn't been able to identify your Mac's network since \(since)."
        case .onBattery: "Your Mac has been on battery each time a backup was due since \(since)."
        case .setupNotFinished: "BackMeUp's setup checklist hasn't been finished. Open it from the menu."
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

/// A tally of every attempt since the last success, kept in full however many attempts
/// `BackupHistory` drops, so alerts can count and date them correctly.
public struct SinceLastSuccess: Codable, Equatable, Sendable {
    /// How often one skip reason came up.
    public struct Skips: Codable, Equatable, Sendable {
        public var reason: SkipReason
        public var count: Int
        /// When the first and latest skips for this reason started.
        public var first: Date
        public var latest: Date
    }

    public var failures = 0
    public var lastFailure: FailureReason?
    public var pauses = 0
    /// One entry per reason, in the order each reason first came up.
    public var skips: [Skips] = []

    public init() {}

    init(_ attempts: some Sequence<BackupAttempt>) {
        for attempt in attempts { add(attempt) }
    }

    /// Counts an attempt. A success starts the tally again.
    mutating func add(_ attempt: BackupAttempt) {
        switch attempt.outcome {
        case .succeeded:
            self = SinceLastSuccess()
        case let .failed(reason):
            failures += 1
            lastFailure = reason
        case .paused:
            pauses += 1
        case let .skipped(reason):
            if let index = skips.firstIndex(where: { $0.reason == reason }) {
                skips[index].count += 1
                skips[index].latest = attempt.started
            } else {
                skips.append(Skips(reason: reason, count: 1, first: attempt.started, latest: attempt.started))
            }
        }
    }

    public var skipCount: Int { skips.reduce(0) { $0 + $1.count } }
}

/// What BackMeUp remembers about its backups across restarts.
public struct BackupHistory: Codable, Equatable, Sendable {
    /// How many attempts are kept. Older ones are dropped, but `sinceLastSuccess` still counts them.
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
    /// Whether the one-time "First backup finished" ntfy message is still to be sent: set at the
    /// first success when ntfy is set up, cleared once the message is sent.
    public var firstBackupMessagePending: Bool?
    /// The tally since the last success, as stored. nil in history saved before it existed; see
    /// `sinceLastSuccess`.
    private var storedSinceLastSuccess: SinceLastSuccess?

    /// Every attempt since the last success, counted, including ones too old to be kept. For
    /// history saved before the tally existed, it's worked out from the attempts still kept.
    public var sinceLastSuccess: SinceLastSuccess {
        if let storedSinceLastSuccess { return storedSinceLastSuccess }
        let start = attempts.lastIndex { $0.outcome == .succeeded }.map { $0 + 1 } ?? 0
        return SinceLastSuccess(attempts[start...])
    }

    public init(lastSuccess: Date? = nil, attempts: [BackupAttempt] = []) {
        self.lastSuccess = lastSuccess
        self.attempts = attempts
    }

    mutating func record(_ attempt: BackupAttempt) {
        var tally = sinceLastSuccess
        tally.add(attempt)
        storedSinceLastSuccess = tally
        attempts.append(attempt)
        if attempts.count > Self.maximumAttempts {
            attempts.removeFirst(attempts.count - Self.maximumAttempts)
        }
        if attempt.outcome == .succeeded {
            lastSuccess = attempt.finished
        }
    }
}
