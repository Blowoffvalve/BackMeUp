import Foundation

/// The core decision engine. On each tick it reads Time Machine's state, starts a backup when one
/// is due (counted from the last success, or the retry interval after a failure or skip), records
/// the outcome, and describes it all for the menu.
@MainActor
public final class Scheduler {
    /// How often the app ticks the scheduler in the background, in seconds.
    public static let tickInterval: TimeInterval = 60

    private let system: any System
    private let calendar: Calendar

    public private(set) var settings: BackupSettings
    public private(set) var history: BackupHistory

    /// The menu's first line: the last backup, or what went wrong with it.
    public private(set) var statusLine = ""
    /// The menu's second line: when the next backup is planned.
    public private(set) var nextBackupLine = ""

    /// Called whenever the menu's lines may have changed, for example when a backup finishes.
    public var onChange: (() -> Void)?

    private var timeMachineStatus = TimeMachineStatus.unknown
    private var backupTask: Task<Void, Never>?

    public init(system: any System, calendar: Calendar = .current) {
        self.system = system
        self.calendar = calendar
        settings = system.loadSettings()?.validated ?? .standard
        history = system.loadHistory() ?? BackupHistory()
        describe()
    }

    /// Whether a backup started by BackMeUp is running.
    public var isBackingUp: Bool { backupTask != nil }

    /// Why the last due backup was skipped, while that's still the latest news. For alerts.
    public var skipReason: SkipReason? {
        if case let .skipped(reason) = history.attempts.last?.outcome { reason } else { nil }
    }

    /// When the next backup is due: the backup interval after the last success, but no sooner than
    /// the retry interval after a failure or skip. With no success yet, straight away.
    public var nextBackupDue: Date {
        var due = Date.distantPast
        if let lastSuccess = history.lastSuccess {
            due = settings.backupInterval.date(after: lastSuccess, in: calendar)
        }
        if let last = history.attempts.last, last.outcome != .succeeded {
            due = max(due, last.finished.addingTimeInterval(TimeInterval(settings.retryMinutes * 60)))
        }
        return due
    }

    /// Called by the app's timer, and by the test harness at each step of simulated time.
    public func tick() async {
        timeMachineStatus = await system.readTimeMachineStatus()
        if !isBackingUp, timeMachineStatus != .running, system.now >= nextBackupDue {
            startAttempt()
        }
        checkAlerts()
        describe()
    }

    /// Re-reads Time Machine's state for the menu without ever starting a backup.
    public func refreshStatus() async {
        timeMachineStatus = await system.readTimeMachineStatus()
        describe()
    }

    /// Back Up Now: starts a backup straight away, whatever the schedule says. Does nothing while
    /// one BackMeUp started is still running.
    public func backUpNow() {
        startAttempt()
    }

    /// Waits until the backup BackMeUp started, if any, has finished and been recorded.
    public func waitForBackup() async {
        await backupTask?.value
    }

    /// Saves new settings, raised to the minimums.
    public func updateSettings(_ newSettings: BackupSettings) {
        settings = newSettings.validated
        system.saveSettings(settings)
        describe()
    }

    // MARK: Running a backup

    private func startAttempt() {
        guard backupTask == nil else { return }
        backupTask = Task {
            let attempt = await runAttempt()
            history.record(attempt)
            system.saveHistory(history)
            checkAlerts()
            backupTask = nil
            describe()
        }
        describe()
    }

    private func runAttempt() async -> BackupAttempt {
        let started = system.now
        let destination = await system.readDestinationInfo()
        let destinationID: String?
        switch destination {
        case .notSetUp:
            return BackupAttempt(started: started, finished: started, outcome: .skipped(.noDiskSetUp))
        case let .configured(disk) where disk.kind == .local && disk.mountPoint == nil:
            return BackupAttempt(started: started, finished: started, outcome: .skipped(.diskNotConnected))
        case let .configured(disk):
            destinationID = disk.id
        case .unknown:
            // Can't tell which disk: let Time Machine try, and judge it by its result.
            destinationID = nil
        }

        let exitCode = await system.startBackup()
        let outcome: BackupAttempt.Outcome
        if let exitCode {
            if exitCode != 0 {
                outcome = .failed(.exitCode(exitCode))
            } else {
                outcome = Self.judge(result: await system.readPreferences()?.destination(id: destinationID)?.result)
            }
        } else {
            outcome = .failed(.couldNotStart)
        }
        return BackupAttempt(started: started, finished: system.now, outcome: outcome)
    }

    /// `tmutil` has been seen exiting 0 for a cancelled backup, so only `RESULT` 0 is a success.
    private static func judge(result: Int?) -> BackupAttempt.Outcome {
        switch result {
        case 0: .succeeded
        case let code?: .failed(.result(code))
        case nil: .failed(.resultUnreadable)
        }
    }

    // MARK: Alerts

    /// Whether backups have a problem worth an alert right now: enough failures in a row, or
    /// overdue. The menu bar icon shows it.
    public private(set) var hasProblem = false

    /// Sends an alert if one is due, or "working again" on the first success after an alert.
    private func checkAlerts() {
        if history.lastAlertSent != nil, let lastSuccess = history.lastSuccess,
           history.attempts.last?.outcome == .succeeded {
            history.lastAlertSent = nil
            system.saveHistory(history)
            hasProblem = false
            send(Alert(kind: .workingAgain, title: "Backups are working again", body: "Last backup: \(format(lastSuccess))"))
            return
        }
        if history.monitoringSince == nil {
            history.monitoringSince = system.now
            system.saveHistory(history)
        }
        let policy = AlertPolicy(history: history, settings: settings.alerts, now: system.now, calendar: calendar)
        hasProblem = policy.problem() != nil
        guard let alert = policy.alertDue() else { return }
        history.lastAlertSent = system.now
        system.saveHistory(history)
        send(alert)
    }

    /// Delivers an alert on every channel: a Mac notification now; other channels, such as ntfy,
    /// are added here, all with the same `Alert`.
    private func send(_ alert: Alert) {
        system.showNotification(alert)
    }

    // MARK: Describing it for the menu

    private func describe() {
        updateLines()
        onChange?()
    }

    private func updateLines() {
        if isBackingUp || timeMachineStatus == .running {
            statusLine = "Backing up now"
            nextBackupLine = ""
            return
        }
        let lastBackup = history.lastSuccess.map { "Last backup: \(format($0))" } ?? "No backups yet"
        switch history.attempts.last?.outcome {
        case let .failed(reason)?:
            statusLine = "Last backup failed: \(reason.description)"
        case let .skipped(reason)?:
            statusLine = "Backup skipped: \(reason.description)"
        case .succeeded?, nil:
            statusLine = lastBackup
        }
        let due = nextBackupDue
        let lastWentWell = history.attempts.last.map { $0.outcome == .succeeded } ?? true
        let label = lastWentWell ? "Next backup" : "Next try"
        nextBackupLine = due <= system.now ? "\(label): now" : "\(label): \(format(due))"
    }

    /// "today 14:02", "yesterday 09:15", "tomorrow 14:02", or "3 Jan 14:02".
    private func format(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "HH:mm"
        let time = formatter.string(from: date)
        let today = calendar.startOfDay(for: system.now)
        let days = calendar.dateComponents([.day], from: today, to: calendar.startOfDay(for: date)).day ?? 0
        switch days {
        case 0: return "today \(time)"
        case -1: return "yesterday \(time)"
        case 1: return "tomorrow \(time)"
        default:
            formatter.dateFormat = "d MMM HH:mm"
            return formatter.string(from: date)
        }
    }
}
