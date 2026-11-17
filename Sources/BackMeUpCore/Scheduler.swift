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
    private var progress: BackupProgress?
    /// The first progress seen in the running backup, to estimate the time left from.
    private var progressStart: (date: Date, fraction: Double)?
    private var backupTask: Task<Void, Never>?
    /// Whether Time Machine's backup command is running for BackMeUp right now.
    private var backupCommandRunning = false

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
        await readProgress()
        updateSleepPrevention()
        if !isBackingUp, timeMachineStatus != .running, system.now >= nextBackupDue {
            startAttempt(byPerson: false)
        }
        describe()
    }

    /// Re-reads Time Machine's state for the menu without ever starting a backup.
    public func refreshStatus() async {
        timeMachineStatus = await system.readTimeMachineStatus()
        await readProgress()
        describe()
    }

    /// Back Up Now: starts a backup straight away, whatever the schedule says. Does nothing while
    /// one BackMeUp started is still running. It runs on battery even when scheduled backups on
    /// battery are off.
    public func backUpNow() {
        startAttempt(byPerson: true)
    }

    /// Called as the app quits: lets the Mac sleep again. Time Machine carries on with any backup
    /// already running.
    public func prepareToQuit() {
        backupCommandRunning = false
        updateSleepPrevention()
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

    /// `byPerson`: Back Up Now, rather than the schedule.
    private func startAttempt(byPerson: Bool) {
        guard backupTask == nil else { return }
        backupTask = Task {
            let attempt = await runAttempt(byPerson: byPerson)
            history.record(attempt)
            system.saveHistory(history)
            backupTask = nil
            describe()
        }
        describe()
    }

    private func runAttempt(byPerson: Bool) async -> BackupAttempt {
        let started = system.now
        if !byPerson, !settings.allowBackupsOnBattery, system.powerSource == .battery {
            return BackupAttempt(started: started, finished: started, outcome: .skipped(.onBattery))
        }
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

        backupCommandRunning = true
        updateSleepPrevention()
        let exitCode = await system.startBackup()
        backupCommandRunning = false
        updateSleepPrevention()
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
        if history.lastSuccess == nil {
            return BackupAttempt(
                started: started,
                finished: system.now,
                outcome: await firstBackupOutcome(outcome, destinationID: destinationID)
            )
        }
        return BackupAttempt(started: started, finished: system.now, outcome: outcome)
    }

    /// Before the first success, a backup that stopped without Time Machine reporting an error
    /// result is paused: the long first backup is often cut short by closing the lid, and resumes
    /// at the next try.
    private func firstBackupOutcome(_ outcome: BackupAttempt.Outcome, destinationID: String?) async -> BackupAttempt.Outcome {
        switch outcome {
        case .failed(.exitCode):
            let result = await system.readPreferences()?.destination(id: destinationID)?.result
            if let result, result != 0 { return .failed(.result(result)) }
            return .paused
        case .failed(.resultUnreadable):
            return .paused
        default:
            return outcome
        }
    }

    /// Keeps the Mac awake only while BackMeUp's backup runs on AC power. On battery it sleeps as
    /// normal. Checked again at every tick, so unplugging releases it within a minute.
    private func updateSleepPrevention() {
        system.setIdleSleepPrevented(backupCommandRunning && system.powerSource != .battery)
    }

    /// `tmutil` has been seen exiting 0 for a cancelled backup, so only `RESULT` 0 is a success.
    private static func judge(result: Int?) -> BackupAttempt.Outcome {
        switch result {
        case 0: .succeeded
        case let code?: .failed(.result(code))
        case nil: .failed(.resultUnreadable)
        }
    }

    // MARK: Progress

    private func readProgress() async {
        guard timeMachineStatus == .running else {
            progress = nil
            progressStart = nil
            return
        }
        progress = await system.readBackupProgress()
        if let progress, progress.fraction < progressStart?.fraction ?? .infinity {
            progressStart = (system.now, progress.fraction)
        }
    }

    /// Time Machine's estimate, or failing that, the rate so far carried on to the end.
    private var timeLeft: TimeInterval? {
        guard let progress else { return nil }
        if let timeRemaining = progress.timeRemaining { return timeRemaining }
        guard let start = progressStart, progress.fraction > start.fraction else { return nil }
        let elapsed = system.now.timeIntervalSince(start.date)
        return (1 - progress.fraction) * elapsed / (progress.fraction - start.fraction)
    }

    /// "First backup: 35%, about 3 hours left", or "Backing up now" before Time Machine says.
    private var progressLine: String {
        guard let progress else { return "Backing up now" }
        let label = history.lastSuccess == nil ? "First backup" : "Backing up"
        let percent = "\(label): \(Int(progress.fraction * 100))%"
        return timeLeft.map { "\(percent), \(Self.describe(timeLeft: $0))" } ?? percent
    }

    /// "less than a minute left", "about 45 minutes left", "about 3 hours left", "about 3 days left".
    private static func describe(timeLeft seconds: TimeInterval) -> String {
        func about(_ count: Double, _ unit: String) -> String {
            let count = Int(count.rounded())
            return "about \(count) \(unit)\(count == 1 ? "" : "s") left"
        }
        if seconds < 60 { return "less than a minute left" }
        if (seconds / 60).rounded() < 60 { return about(seconds / 60, "minute") }
        if (seconds / 3600).rounded() < 48 { return about(max(1, seconds / 3600), "hour") }
        return about(seconds / 86400, "day")
    }

    // MARK: Describing it for the menu

    private func describe() {
        updateLines()
        onChange?()
    }

    private func updateLines() {
        if isBackingUp || timeMachineStatus == .running {
            statusLine = progressLine
            nextBackupLine = ""
            return
        }
        let lastBackup = history.lastSuccess.map { "Last backup: \(format($0))" } ?? "No backups yet"
        switch history.attempts.last?.outcome {
        case let .failed(reason)?:
            statusLine = "Last backup failed: \(reason.description)"
        case let .skipped(reason)?:
            statusLine = "Backup skipped: \(reason.description)"
        case .paused?:
            statusLine = "First backup paused"
        case .succeeded?, nil:
            statusLine = lastBackup
        }
        let due = nextBackupDue
        let lastOutcome = history.attempts.last?.outcome ?? .succeeded
        let label = switch lastOutcome {
        case .succeeded: "Next backup"
        case .paused: "Resumes"
        case .failed, .skipped: "Next try"
        }
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
