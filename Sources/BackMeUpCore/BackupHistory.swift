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
    /// The backup disk is a network disk that Time Machine couldn't reach (its `RESULT` 18), for
    /// example just after login while a VPN is still starting.
    case diskNotReachable
    /// The Mac is on battery and backups on battery are turned off.
    case onBattery
    /// A required checklist item (automatic backups off, a chosen network for a network disk, or
    /// one BackMeUp can't check) isn't done. A missing disk is `noDiskSetUp` instead.
    case setupNotFinished
    /// Back Up Now while Time Machine was backing up to a disk other than the chosen one.
    /// Scheduled backups wait for it instead.
    case timeMachineBackingUpToAnotherDisk

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
        case .diskNotReachable: "network backup disk not reachable"
        case .onBattery: "on battery"
        case .setupNotFinished: "setup isn't finished"
        case .timeMachineBackingUpToAnotherDisk: "Time Machine is backing up to another disk"
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
        case .diskNotReachable: "Time Machine hasn't been able to reach the network backup disk since \(since)."
        case .onBattery: "Your Mac has been on battery each time a backup was due since \(since)."
        case .setupNotFinished: "BackMeUp's setup checklist hasn't been finished. Open it from the menu."
        case .timeMachineBackingUpToAnotherDisk: "Time Machine has been backing up to another disk each time you chose Back Up Now since \(since)."
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
    /// Time Machine couldn't reach the backup disk: `RESULT` 26, which Time Machine's log names
    /// `BACKUP_FAILED_DISCONNECTED_NETWORK`. Seen for a network share that was reachable, when Time
    /// Machine kept a stale record of its mount; restarting the Mac fixed it. `isNetworkDisk` is
    /// false for a local disk or one BackMeUp couldn't identify.
    case diskUnreachable(isNetworkDisk: Bool)
    /// Time Machine is stuck: it still believes the network disk is mounted after the connection
    /// under it went, so every backup fails at once with `RESULT` 26 without trying to reconnect.
    /// Seen on macOS 27.2; only restarting the Mac fixed it. `afterRestart`: the Mac has been
    /// restarted since it was first seen, and it's still stuck.
    case timeMachineStuck(afterRestart: Bool)
    /// `tmutil` exited 0 but the destination's `RESULT` couldn't be read.
    case resultUnreadable
    /// `tmutil` exited 0 and `RESULT` was 0, but nothing showed the result was from this backup:
    /// no newer backup appeared on the disk. It may be left over from an earlier one.
    case notConfirmed

    /// What to try when a network disk couldn't be reached. Shown in alerts and the status line.
    static let networkDiskHint =
        "Check you're on the right network. If it keeps happening, restarting your Mac usually fixes it."

    /// How the menu's status line explains this failure: the description, plus the hint for an
    /// unreachable network disk.
    var statusText: String {
        switch self {
        case .diskUnreachable(isNetworkDisk: true): "\(description). \(Self.networkDiskHint)"
        case .timeMachineStuck(afterRestart: false): "Time Machine is stuck. Restarting your Mac fixes this."
        case .timeMachineStuck(afterRestart: true): "Time Machine is still stuck after a restart. Choose How to Fix This…"
        default: description
        }
    }

    public var description: String {
        switch self {
        case .couldNotStart: "couldn't start Time Machine"
        case let .exitCode(code): "Time Machine stopped with code \(code)"
        case let .result(code): "Time Machine reported error \(code)"
        case .diskUnreachable: "the backup disk couldn't be reached"
        case .timeMachineStuck(afterRestart: false): "Time Machine is stuck"
        case .timeMachineStuck(afterRestart: true): "Time Machine is still stuck after a restart"
        case .resultUnreadable: "couldn't read Time Machine's result"
        case .notConfirmed: "couldn't tell whether Time Machine finished"
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

extension BackupAttempt.Outcome {
    /// How the log records it. Never names the network.
    var logLine: String {
        switch self {
        case .succeeded: "Backup succeeded"
        case let .failed(reason): "Backup failed: \(reason.description)"
        case let .skipped(reason): "Backup skipped: \(reason.description)"
        case .paused: "First backup paused"
        }
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
    /// How long attempts are kept: as far back as the backup strip goes. Older ones are dropped,
    /// but `sinceLastSuccess` still counts them.
    public static let keptWeeks = BackupStripText.weekCount
    /// The most attempts kept however recent, so the saved history stays a few hundred KB at most.
    /// The oldest go first.
    public static let maximumAttempts = 3000

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
    /// Set while Time Machine is stuck (`FailureReason.timeMachineStuck`); cleared by the next
    /// success.
    public var stuck: StuckRecord?
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

    /// Records an attempt and drops the ones that started more than `keptWeeks` before `now`.
    mutating func record(_ attempt: BackupAttempt, now: Date, calendar: Calendar) {
        var tally = sinceLastSuccess
        tally.add(attempt)
        storedSinceLastSuccess = tally
        attempts.append(attempt)
        if let cutoff = calendar.date(byAdding: .weekOfYear, value: -Self.keptWeeks, to: now) {
            attempts.removeAll { $0.started < cutoff }
        }
        if attempts.count > Self.maximumAttempts {
            attempts.removeFirst(attempts.count - Self.maximumAttempts)
        }
        if attempt.outcome == .succeeded {
            lastSuccess = attempt.finished
            stuck = nil
        }
    }
}

/// What BackMeUp remembers while Time Machine is stuck, so it can tell when the Mac has been
/// restarted and whether that helped.
public struct StuckRecord: Codable, Equatable, Sendable {
    /// When Time Machine was first seen stuck.
    public var since: Date
    /// When the Mac had last started up as of the latest stuck backup, or nil if that couldn't
    /// be read. A different start-up time now means the Mac has restarted since.
    public var bootTime: Date?
    /// Whether a backup after a restart was stuck too.
    public var restartDidNotHelp: Bool

    public init(since: Date, bootTime: Date?, restartDidNotHelp: Bool = false) {
        self.since = since
        self.bootTime = bootTime
        self.restartDidNotHelp = restartDidNotHelp
    }

    /// Whether the Mac has restarted since the latest stuck backup. Start-up times read a second
    /// apart count as the same.
    func hasRestarted(bootTime now: Date?) -> Bool {
        guard let bootTime, let now else { return false }
        return abs(now.timeIntervalSince(bootTime)) > 1
    }
}
