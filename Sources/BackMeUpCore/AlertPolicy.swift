import Foundation

/// Decides which alert, if any, is due, from the backup history and the alert settings alone.
///
/// - Failure alert: the last `failuresInARow` started backups didn't finish. Skips neither count
///   nor break the run.
/// - Overdue alert: no success for `daysWithoutBackup` days, counted from the last success or, before
///   the first one, from when BackMeUp first ran. It names the most common skip reason since then,
///   or the failures if there were more of those.
/// - Either repeats at most once every 24 hours while the problem lasts.
struct AlertPolicy {
    /// While a problem lasts, alerts repeat no more often than this.
    static let repeatInterval: TimeInterval = 24 * 60 * 60

    var history: BackupHistory
    var settings: AlertSettings
    var now: Date
    var calendar: Calendar

    /// The alert to send now, if any.
    func alertDue() -> Alert? {
        if let lastAlertSent = history.lastAlertSent, now < lastAlertSent.addingTimeInterval(Self.repeatInterval) {
            return nil
        }
        return problem()
    }

    /// The alert describing the current problem, if there is one.
    func problem() -> Alert? {
        let failures = attemptsSinceLastSuccess.compactMap(\.failure)
        if let last = failures.last, failures.count >= settings.failuresInARow {
            return Alert(kind: .failed, title: failedTitle(failures.count), body: failureSentence(failures.count, last))
        }
        return overdue()
    }

    // MARK: Overdue

    private func overdue() -> Alert? {
        guard let since = history.lastSuccess ?? history.monitoringSince else { return nil }
        let days = Int(now.timeIntervalSince(since) / (24 * 60 * 60))
        guard days >= settings.daysWithoutBackup else { return nil }
        let opening = "No backup for \(days) \(days == 1 ? "day" : "days")."

        let attempts = attemptsSinceLastSuccess
        let failures = attempts.compactMap(\.failure)
        let skips = attempts.compactMap(\.skip)
        if let reason = mainSkipReason(skips.map(\.reason)), skips.count >= failures.count {
            let firstSkip = skips.first { $0.reason == reason }!.date
            return Alert(
                kind: .overdue,
                title: "Backups skipped",
                body: "\(opening) \(reason.alertSentence(since: dayName(firstSkip)))"
            )
        }
        let pauses = attempts.filter { $0.outcome == .paused }.count
        if let last = failures.last, failures.count >= pauses {
            return Alert(kind: .overdue, title: failedTitle(failures.count), body: "\(opening) \(failureSentence(failures.count, last))")
        }
        if pauses > 0 {
            return Alert(
                kind: .overdue,
                title: "First backup not finished",
                body: "\(opening) The first backup keeps stopping before it finishes."
            )
        }
        return Alert(kind: .overdue, title: "Backups overdue", body: opening)
    }

    /// The reason given most often, the latest of those if there's a tie.
    private func mainSkipReason(_ reasons: [SkipReason]) -> SkipReason? {
        func count(_ reason: SkipReason) -> Int { reasons.filter { $0 == reason }.count }
        // `max` keeps the first of equal elements, so search newest first.
        return reasons.reversed().max { count($0) < count($1) }
    }

    // MARK: Wording

    private func failedTitle(_ count: Int) -> String {
        count == 1 ? "Backup failed" : "Backups failed"
    }

    private func failureSentence(_ count: Int, _ last: FailureReason) -> String {
        "\(count == 1 ? "1 backup" : "\(count) backups") didn't finish. \(last.alertSentence)"
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

    // MARK: History

    private var attemptsSinceLastSuccess: ArraySlice<BackupAttempt> {
        let start = history.attempts.lastIndex { $0.outcome == .succeeded }.map { $0 + 1 } ?? 0
        return history.attempts[start...]
    }
}

private extension BackupAttempt {
    var failure: FailureReason? {
        if case let .failed(reason) = outcome { reason } else { nil }
    }

    var skip: (reason: SkipReason, date: Date)? {
        if case let .skipped(reason) = outcome { (reason, started) } else { nil }
    }
}

extension FailureReason {
    /// How an alert explains this failure, as a sentence.
    var alertSentence: String {
        switch self {
        case .couldNotStart: "Time Machine couldn't be started."
        case let .exitCode(code): "Time Machine stopped with code \(code)."
        case let .result(code): "Time Machine reported error \(code)."
        case .resultUnreadable: "BackMeUp couldn't read Time Machine's result."
        }
    }
}
