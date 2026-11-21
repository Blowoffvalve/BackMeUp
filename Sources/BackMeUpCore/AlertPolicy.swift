import Foundation

/// Decides which alert, if any, is due, from the backup history and the alert settings alone.
///
/// - Failure alert: the last `failuresInARow` started backups didn't finish. Skips neither count
///   nor break the run.
/// - Overdue alert: no success for `daysWithoutBackup` days, counted from the last success or, before
///   the first one, from when BackMeUp first ran. It names the most common skip reason since then,
///   or the failures if there were more of those.
/// - While the problem lasts, the failure alert comes again for every further failed backup, and
///   the overdue alert each time its day count goes up. There's no time limit on repeats.
struct AlertPolicy {
    var history: BackupHistory
    var settings: AlertSettings
    var now: Date
    var calendar: Calendar
    /// What Troubleshoot found after the last failed backup, as a sentence, when it found the
    /// network or the server at fault. Replaces the failure's own explanation.
    var failureCause: String? = nil

    /// The alert to send now, if any.
    func alertDue() -> Alert? {
        guard let alert = problem() else { return nil }
        guard let lastAlertSent = history.lastAlertSent else { return alert }
        if alert.kind == .failed, failedSince(lastAlertSent) { return alert }
        if alert.kind == .overdue, let since = overdueSince, days(since, to: now) > days(since, to: lastAlertSent) {
            return alert
        }
        return nil
    }

    /// Whether the latest backup failed after `date`.
    private func failedSince(_ date: Date) -> Bool {
        guard let last = history.attempts.last, case .failed = last.outcome else { return false }
        return last.finished > date
    }

    /// The alert describing the current problem, if there is one.
    func problem() -> Alert? {
        let tally = history.sinceLastSuccess
        // A stuck Time Machine won't fix itself, so it's alerted on the first one.
        if case let .timeMachineStuck(afterRestart)? = tally.lastFailure,
           case .failed(.timeMachineStuck)? = history.attempts.last?.outcome {
            return Self.stuckAlert(afterRestart: afterRestart)
        }
        if let last = tally.lastFailure, tally.failures >= settings.failuresInARow {
            return Alert(kind: .failed, title: failedTitle(tally.failures), body: failureSentence(tally.failures, last))
        }
        return overdue()
    }

    /// "Time Machine is stuck", or, after a restart that didn't help, where to get help.
    static func stuckAlert(afterRestart: Bool) -> Alert {
        afterRestart
            ? Alert(
                kind: .failed,
                title: "Restarting didn't fix Time Machine",
                body: "Time Machine is still stuck after a restart. Choose How to Fix This… in the BackMeUp menu to copy the details for whoever set up your backups."
            )
            : Alert(
                kind: .failed,
                title: "Time Machine is stuck",
                body: "Your backup disk is fine, but Time Machine has lost track of it. Restarting your Mac fixes this."
            )
    }

    // MARK: Overdue

    private func overdue() -> Alert? {
        guard let since = overdueSince else { return nil }
        let days = days(since, to: now)
        guard days >= settings.daysWithoutBackup else { return nil }
        let opening = "No backup for \(days) \(days == 1 ? "day" : "days")."

        let tally = history.sinceLastSuccess
        if let skips = mainSkipReason(tally.skips), tally.skipCount >= tally.failures {
            return Alert(
                kind: .overdue,
                title: "Backups skipped",
                body: "\(opening) \(skips.reason.alertSentence(since: dayName(skips.first)))"
            )
        }
        if let last = tally.lastFailure, tally.failures >= tally.pauses {
            return Alert(kind: .overdue, title: failedTitle(tally.failures), body: "\(opening) \(failureSentence(tally.failures, last))")
        }
        if tally.pauses > 0 {
            return Alert(
                kind: .overdue,
                title: "First backup not finished",
                body: "\(opening) The first backup keeps stopping before it finishes."
            )
        }
        return Alert(kind: .overdue, title: "Backups overdue", body: opening)
    }

    /// When the overdue count starts: the last success, or when BackMeUp first ran.
    private var overdueSince: Date? { history.lastSuccess ?? history.monitoringSince }

    /// Whole days from `start` to `end`.
    private func days(_ start: Date, to end: Date) -> Int {
        Int(end.timeIntervalSince(start) / (24 * 60 * 60))
    }

    /// The reason given most often, the one that came up most recently if there's a tie.
    private func mainSkipReason(_ skips: [SinceLastSuccess.Skips]) -> SinceLastSuccess.Skips? {
        skips.max { ($0.count, $0.latest) < ($1.count, $1.latest) }
    }

    // MARK: Wording

    private func failedTitle(_ count: Int) -> String {
        count == 1 ? "Backup failed" : "Backups failed"
    }

    private func failureSentence(_ count: Int, _ last: FailureReason) -> String {
        "\(count == 1 ? "1 backup" : "\(count) backups") didn't finish. \(failureCause ?? last.alertSentence)"
    }

    /// "today", "yesterday", "Friday" within the last week, else "3 January".
    private func dayName(_ date: Date) -> String {
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)).day ?? 0
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        switch days {
        case ...0: return "today"
        case 1: return "yesterday"
        case 2...6: formatter.dateFormat = "EEEE"
        default: formatter.dateFormat = "d MMMM"
        }
        return formatter.string(from: date)
    }
}

extension FailureReason {
    /// How an alert explains this failure, as a sentence.
    var alertSentence: String {
        switch self {
        case .couldNotStart: "Time Machine couldn't be started."
        case let .exitCode(code): "Time Machine stopped with code \(code)."
        case let .result(code): "Time Machine reported error \(code)."
        case .diskUnreachable(isNetworkDisk: false): "The backup disk couldn't be reached."
        case .diskUnreachable(isNetworkDisk: true):
            "The backup disk couldn't be reached. \(FailureReason.networkDiskHint)"
        case .timeMachineStuck(afterRestart: false): "Time Machine is stuck. Restarting your Mac fixes this."
        case .timeMachineStuck(afterRestart: true): "Time Machine is still stuck after a restart."
        case .resultUnreadable: "BackMeUp couldn't read Time Machine's result."
        case .notConfirmed: "BackMeUp couldn't tell whether Time Machine finished the backup."
        }
    }
}
