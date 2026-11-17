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
    /// Chosen networks and the "all networks" switch, for the Settings window.
    public private(set) var networks: NetworkSettings
    /// The network the Mac was on at the last tick or refresh, or nil before the first one.
    public private(set) var currentNetwork: NetworkReading?
    /// The menu's network line: the current network's label and whether backups may run on it.
    /// Never shows the router's hardware address.
    public private(set) var networkLine = ""

    /// The menu's first line: the last backup, or what went wrong with it.
    public private(set) var statusLine = ""
    /// The menu's second line: when the next backup is planned.
    public private(set) var nextBackupLine = ""

    /// The first-run checklist as of the last tick or refresh, or nil before the first one.
    /// Backups are scheduled only while it allows them.
    public private(set) var checklist: Checklist?

    /// Called when the checklist window should be shown: on first launch, at a launch with check
    /// 1, 2 or 6 not done, and whenever a check stops passing.
    public var onShowChecklist: (() -> Void)?

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
        networks = system.loadNetworks() ?? NetworkSettings()
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
        currentNetwork = await system.readNetwork()
        await readProgress()
        if !setupState.firstRunDone {
            registerLoginItem()
        }
        await readChecklist()
        if !setupState.firstRunDone {
            setupState.firstRunDone = true
            system.saveSetupState(setupState)
        }
        updateSleepPrevention()
        if !isBackingUp, timeMachineStatus != .running,
           system.now >= nextBackupDue || isBackOnAChosenNetwork || isSetupJustFinished {
            startAttempt(byPerson: false)
        }
        checkAlerts()
        describe()
    }

    /// Re-reads Time Machine's state for the menu without ever starting a backup.
    public func refreshStatus() async {
        timeMachineStatus = await system.readTimeMachineStatus()
        currentNetwork = await system.readNetwork()
        await readProgress()
        await readChecklist()
        describe()
    }

    // MARK: Checklist

    private lazy var setupState = system.loadSetupState() ?? SetupState()
    /// The checks that weren't done at the last reading, or nil before the first one since launch.
    private var previousProblems: Set<ChecklistItem.Check>?
    /// Checks whose Settings link failed to open, so they show plain-text directions instead.
    private var linkFailed: Set<ChecklistItem.Check> = []

    /// While no backup has succeeded yet: advice for the long first backup.
    public var checklistTip: String? {
        guard history.lastSuccess == nil else { return nil }
        return "Do your first backup with your Mac plugged in, and at home or with the USB disk attached, so that it has the best chance of finishing."
    }

    /// Adds BackMeUp to Login Items. Done once on first run; if macOS refuses or wants approval,
    /// check 4 says how to add it by hand.
    public func registerLoginItem() {
        _ = system.registerLoginItem()
    }

    /// The item's button: asks for notification permission, or opens its System Settings screen.
    /// If the screen can't be opened, the item shows plain-text directions instead.
    /// `.openBackMeUpSettings` is left to the app.
    public func performAction(for check: ChecklistItem.Check) async {
        if checklist == nil { await readChecklist() }
        guard let item = checklist?.item(check) else { return }
        switch item.action {
        case .allowNotifications:
            _ = await system.requestNotificationPermission()
        case let .openSystemSettings(pane):
            if system.openSystemSettings(pane) {
                linkFailed.remove(check)
            } else {
                linkFailed.insert(check)
            }
        case .openBackMeUpSettings:
            return
        }
        await readChecklist()
        describe()
    }

    /// Re-reads everything the checklist checks, and asks for the checklist to be shown if
    /// something needs the user.
    private func readChecklist() async {
        let checklist = Checklist(ChecklistInputs(
            destination: await system.readDestinationInfo(),
            preferences: await system.readPreferences(),
            networks: networks,
            loginItem: system.readLoginItemStatus(),
            notifications: await system.readNotificationPermission(),
            linkFailed: linkFailed
        ))
        self.checklist = checklist
        let problems = checklist.problems
        let shouldShow = if let previousProblems {
            !problems.subtracting(previousProblems).isEmpty
        } else {
            !setupState.firstRunDone || problems.contains { $0.isRequired }
        }
        previousProblems = problems
        if shouldShow { onShowChecklist?() }
    }

    /// A backup held back by an unfinished checklist starts as soon as the checklist allows it,
    /// rather than at the next retry, if it was due by the backup interval.
    private var isSetupJustFinished: Bool {
        guard let reason = skipReason, reason.isSetupReason, checklist?.allowsBackups == true else { return false }
        let scheduled = history.lastSuccess.map { settings.backupInterval.date(after: $0, in: calendar) } ?? .distantPast
        return system.now >= scheduled
    }

    // MARK: Networks

    /// Whether the menu should offer "Allow backups on this network": the current network is
    /// identified, isn't chosen yet, and "all networks" is off.
    public var canAllowCurrentNetwork: Bool {
        guard !networks.allNetworks, case let .router(address, _)? = currentNetwork else { return false }
        return networks.network(routerAddress: address) == nil
    }

    /// The current network's Wi-Fi name, when Location permission allows it. Without one, the app
    /// asks the user to name the network.
    public var currentNetworkWiFiName: String? {
        if case let .router(_, wifiName)? = currentNetwork { wifiName } else { nil }
    }

    /// "Allow backups on this network": adds the current network under `label`. Does nothing if
    /// it can't be identified or is already chosen. A backup waiting for it starts at the next tick.
    public func allowCurrentNetwork(label: String) {
        guard canAllowCurrentNetwork, case let .router(address, _)? = currentNetwork else { return }
        networks.chosen.append(ChosenNetwork(routerAddress: address, label: label))
        system.saveNetworks(networks)
        describe()
    }

    /// Saves chosen networks (renamed or removed in Settings) and the "all networks" switch.
    public func updateNetworks(_ newNetworks: NetworkSettings) {
        networks = newNetworks
        system.saveNetworks(networks)
        describe()
    }

    /// A backup skipped for the network can start as soon as the Mac is on a chosen network,
    /// rather than at the next retry, if it was due by the backup interval.
    private var isBackOnAChosenNetwork: Bool {
        guard let reason = skipReason, reason.isNetworkReason, let currentNetwork,
              networks.skipReason(on: currentNetwork) == nil
        else { return false }
        let scheduled = history.lastSuccess.map { settings.backupInterval.date(after: $0, in: calendar) } ?? .distantPast
        return system.now >= scheduled
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
            checkAlerts()
            backupTask = nil
            describe()
        }
        describe()
    }

    private func runAttempt(byPerson: Bool) async -> BackupAttempt {
        let started = system.now
        // Nothing starts, not even Back Up Now, until checks 1, 2 and 6 pass.
        await readChecklist()
        if let checklist, let reason = checklist.skipReason {
            return BackupAttempt(started: started, finished: started, outcome: .skipped(reason))
        }
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

        // Network rules hold back network disks, and a disk we can't identify, but never a local one.
        if case let .configured(disk) = destination, disk.kind == .local {
            // No network rule.
        } else {
            let network = await system.readNetwork()
            currentNetwork = network
            if let reason = networks.skipReason(on: network) {
                return BackupAttempt(started: started, finished: started, outcome: .skipped(reason))
            }
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
        updateNetworkLine()
        if isBackingUp || timeMachineStatus == .running {
            statusLine = progressLine
            nextBackupLine = ""
            return
        }
        if checklist?.allowsBackups == false {
            statusLine = "Finish setting up: see the checklist"
            nextBackupLine = "Backups start once setup is finished"
            return
        }
        let lastBackup = history.lastSuccess.map { "Last backup: \(format($0))" } ?? "No backups yet"
        switch history.attempts.last?.outcome {
        case let .failed(reason)?:
            statusLine = "Last backup failed: \(reason.description)"
        case .skipped(.notOnChosenNetwork)?:
            statusLine = "Waiting for a chosen network"
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

    private func updateNetworkLine() {
        switch currentNetwork {
        case nil:
            networkLine = ""
        case .none?:
            networkLine = "Network: not connected"
        case .routerAddressUnknown?:
            networkLine = "Network: not identified yet"
        case let .router(address, wifiName)?:
            let chosen = networks.network(routerAddress: address)
            let label = chosen?.label ?? wifiName ?? "this network"
            let state = if chosen != nil { "backups allowed" }
                else if networks.allNetworks { "all networks allowed" }
                else { "not chosen" }
            networkLine = "Network: \(label) (\(state))"
        }
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
