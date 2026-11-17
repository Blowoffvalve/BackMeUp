import Foundation

/// The core decision engine. On each tick it reads Time Machine's state, starts a backup when one
/// is due (counted from the last success, or the retry interval after a failure or skip), records
/// the outcome, and describes it all for the menu.
@MainActor
public final class Scheduler {
    /// How often the app ticks the scheduler in the background, in seconds.
    public static let tickInterval: TimeInterval = 60

    /// The outside world. After Uninstall… it drops every save, backup start and message.
    private let system: UninstallableSystem
    private let calendar: Calendar
    private var ntfySender: NtfySender { NtfySender(system: system) }

    public private(set) var settings: BackupSettings
    public private(set) var history: BackupHistory
    /// Chosen networks and the "all networks" switch, for the Settings window.
    public private(set) var networks: NetworkSettings
    /// Where phone alerts go through ntfy, if anywhere.
    public private(set) var ntfy: NtfySettings
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
        self.system = UninstallableSystem(system)
        self.calendar = calendar
        settings = system.loadSettings()?.validated ?? .standard
        history = system.loadHistory() ?? BackupHistory()
        networks = system.loadNetworks() ?? NetworkSettings()
        ntfy = NtfySettings(
            server: system.loadNtfyServer() ?? NtfySettings.defaultServer,
            topic: system.loadSecret(.ntfyTopic) ?? "",
            token: system.loadSecret(.ntfyToken)
        )
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
        var due = dueByInterval
        if let last = history.attempts.last, last.outcome != .succeeded {
            due = max(due, last.finished.addingTimeInterval(TimeInterval(settings.retryMinutes * 60)))
        }
        return due
    }

    /// When the next backup is due by the backup interval alone: the interval after the last
    /// success, or straight away with no success yet. Retries don't move it.
    private var dueByInterval: Date {
        history.lastSuccess.map { settings.backupInterval.date(after: $0, in: calendar) } ?? .distantPast
    }

    /// Called by the app's timer, and by the test harness at each step of simulated time.
    public func tick() async {
        guard !isUninstalled else { return }
        timeMachineStatus = await system.readTimeMachineStatus()
        currentNetwork = await system.readNetwork()
        await readProgress()
        let isUpdated = isFirstLaunchAfterUpdate
        if !setupState.firstRunDone || isUpdated {
            registerLoginItem()
        }
        await readChecklist()
        if !setupState.firstRunDone || isUpdated {
            setupState.firstRunDone = true
            setupState.lastLaunchedVersion = system.appVersion
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
        guard !isUninstalled else { return }
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

    /// Whether this is the first tick since Sparkle installed a new version. After an update,
    /// BackMeUp adds itself to Login Items again and re-reads the checklist.
    private var isFirstLaunchAfterUpdate: Bool {
        guard setupState.firstRunDone, let version = system.appVersion else { return false }
        return setupState.lastLaunchedVersion != version
    }

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
                // After an update, say so if BackMeUp no longer opens at login.
                || (isFirstLaunchAfterUpdate && problems.contains(.opensAtLogin))
        }
        previousProblems = problems
        if shouldShow { onShowChecklist?() }
    }

    /// A backup held back by an unfinished checklist starts as soon as the checklist allows it,
    /// rather than at the next retry, if it was due by the backup interval.
    private var isSetupJustFinished: Bool {
        guard let reason = skipReason, reason.isSetupReason, checklist?.allowsBackups == true else { return false }
        return system.now >= dueByInterval
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
        return system.now >= dueByInterval
    }

    /// Back Up Now: starts a backup straight away, whatever the schedule says. Does nothing while
    /// one BackMeUp started is still running. It runs on battery even when scheduled backups on
    /// battery are off.
    public func backUpNow() {
        guard !isUninstalled else { return }
        startAttempt(byPerson: true)
    }

    /// Called as the app quits: lets the Mac sleep again. Time Machine carries on with any backup
    /// already running.
    /// After Uninstall…, it deletes the settings once more, in case macOS or a framework saved
    /// something for BackMeUp while the reminder was showing.
    public func prepareToQuit() {
        backupCommandRunning = false
        updateSleepPrevention()
        if isUninstalled { system.deleteAllSettings() }
    }

    // MARK: Uninstall

    /// Whether Uninstall… has run. From then on BackMeUp starts no backups, sends no alerts and
    /// saves nothing, while the app shows its reminder and quits. `UninstallableSystem` enforces
    /// it for every save; the scheduler's entry points (ticks, refreshes, Back Up Now) also stop
    /// reading the Mac, so the checklist isn't shown again.
    public var isUninstalled: Bool { system.isUninstalled }

    /// Uninstall…: removes BackMeUp from Login Items and deletes its settings and every Keychain
    /// item it made. Time Machine's settings and backups are never touched.
    public func uninstall() {
        system.uninstall()
        backupCommandRunning = false
        updateSleepPrevention()
        system.unregisterLoginItem()
        system.deleteAllSettings()
        for secret in Secret.allCases {
            system.saveSecret(nil, as: secret)
        }
    }

    /// The uninstall reminder's button: opens Time Machine settings so the user can turn its
    /// automatic backups back on. Returns false if it couldn't be opened; the reminder then shows
    /// `Uninstall.reminderDirections`. Only opens the screen; it changes nothing there.
    public func openTimeMachineSettings() -> Bool {
        system.openSystemSettings(.timeMachine)
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
            // Uninstalled while Time Machine ran: Time Machine carries on, but nothing is recorded.
            guard !isUninstalled else {
                backupTask = nil
                return
            }
            let isFirstSuccess = history.lastSuccess == nil && attempt.outcome == .succeeded
            history.record(attempt)
            if isFirstSuccess, ntfy.isSetUp { history.firstBackupMessagePending = true }
            system.saveHistory(history)
            checkAlerts()
            sendFirstBackupMessageIfPending()
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

    /// Delivers an alert on every channel: a Mac notification, and ntfy when it's set up.
    private func send(_ alert: Alert) {
        system.showNotification(alert)
        let tag = switch alert.kind {
        case .failed, .overdue: NtfyTag.warning
        case .workingAgain: NtfyTag.success
        }
        ntfySender.send(title: alert.title, body: alert.body, tag: tag, with: ntfy)
    }

    // MARK: ntfy

    /// Saves where phone alerts go. The topic and token go to the Keychain.
    public func updateNtfy(_ newSettings: NtfySettings) {
        ntfy = newSettings.cleaned
        system.saveNtfyServer(ntfy.server)
        system.saveSecret(ntfy.isSetUp ? ntfy.topic : nil, as: .ntfyTopic)
        system.saveSecret(ntfy.token, as: .ntfyToken)
    }

    /// The Settings window's "Send test message" button: sends a test message with the saved
    /// ntfy settings, and says whether it worked.
    public func sendTestMessage() async -> NtfyTestResult {
        await ntfySender.sendTestMessage(with: ntfy)
    }

    /// Whether the "First backup finished" message is being sent right now.
    private var sendingFirstBackupMessage = false

    /// Sends the one-time "First backup finished" message, if it's still to be sent. A failed send
    /// is tried again after the next backup attempt.
    private func sendFirstBackupMessageIfPending() {
        guard history.firstBackupMessagePending == true, ntfy.isSetUp, !sendingFirstBackupMessage,
              let lastSuccess = history.attempts.first(where: { $0.outcome == .succeeded })?.finished ?? history.lastSuccess
        else { return }
        sendingFirstBackupMessage = true
        ntfySender.send(
            title: "First backup finished",
            body: "Your Mac's first backup finished \(format(lastSuccess)).",
            tag: .success,
            with: ntfy
        ) { [weak self] result in
            guard let self else { return }
            sendingFirstBackupMessage = false
            if result == .sent {
                history.firstBackupMessagePending = nil
                system.saveHistory(history)
            }
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

    // MARK: Describing it for the menu

    private func describe() {
        updateLines()
        onChange?()
    }

    private func updateLines() {
        let text = MenuText(
            history: history,
            nextBackupDue: nextBackupDue,
            isBackingUp: isBackingUp || timeMachineStatus == .running,
            progress: progress,
            timeLeft: timeLeft,
            isWaitingForSetup: checklist?.allowsBackups == false,
            currentNetwork: currentNetwork,
            networks: networks,
            dates: RelativeDate(now: system.now, calendar: calendar)
        )
        statusLine = text.statusLine
        nextBackupLine = text.nextBackupLine
        networkLine = text.networkLine
    }

    /// "today 14:02", "yesterday 09:15", "tomorrow 14:02", or "3 Jan 14:02".
    private func format(_ date: Date) -> String {
        RelativeDate(now: system.now, calendar: calendar).describe(date)
    }
}
