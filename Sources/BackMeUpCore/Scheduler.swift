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

    /// Whether Time Machine is backing up, to any disk. No backup starts while it is.
    private var isTimeMachineRunning: Bool {
        if case .running = timeMachineStatus { true } else { false }
    }

    /// Whether Time Machine is backing up to the chosen disk, for the status line and progress.
    /// With no disk chosen, or when Time Machine doesn't say which disk, any backup counts.
    private var isTimeMachineRunningToChosenDisk: Bool {
        guard case let .running(runningTo) = timeMachineStatus else { return false }
        guard let chosen = diskChoice.chosenID, let runningTo else { return true }
        return runningTo == chosen
    }
    /// Whether Time Machine is backing up to a disk other than the chosen one.
    private var isTimeMachineRunningToAnotherDisk: Bool {
        isTimeMachineRunning && !isTimeMachineRunningToChosenDisk
    }

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
        // Unplugging lets the Mac sleep straight away, not at the next tick.
        self.system.watchPowerSource { [weak self] in self?.updateSleepPrevention() }
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
        if isUpdated { askToChooseDiskAfterUpdateIfNeeded() }
        if !setupState.firstRunDone || isUpdated {
            setupState.firstRunDone = true
            setupState.lastLaunchedVersion = system.appVersion
            system.saveSetupState(setupState)
        }
        askToChooseThisNetworkIfNeeded()
        updateSleepPrevention()
        if !isBackingUp, !isTimeMachineRunning,
           system.now >= nextBackupDue || isBackOnAChosenNetwork || isSetupJustFinished || isOtherDiskBackupOver {
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
        let reading = await system.readDestinationInfo()
        let preferences = await system.readPreferences()
        let notifications = await system.readNotificationPermission()
        // The saved choice is read only after every await, so a disk chosen while this reading
        // was in flight is the one it uses.
        let choiceCleared = followDiskChoice(reading)
        destination = reading.choosing(diskChoice.chosenID)
        let checklist = Checklist(ChecklistInputs(
            destination: reading,
            chosenDiskID: diskChoice.chosenID,
            chosenDiskRemoved: diskChoice.chosenDiskRemoved,
            newDiskAdded: diskChoice.newDiskAdded,
            preferences: preferences,
            now: system.now,
            networks: networks,
            loginItem: system.readLoginItemStatus(),
            notifications: notifications,
            linkFailed: linkFailed
        ))
        self.checklist = checklist
        let diskCheckPassed = checklist.item(.diskSetUp)?.state == .passed
        disks = reading.disks.map { disk in
            ListedDisk(
                label: DiskChoice.label(disk, preferences: preferences, now: system.now),
                isBackupDisk: diskCheckPassed && destination == .configured(disk)
            )
        }
        let problems = checklist.problems
        let shouldShow = if choiceCleared && problems.contains(.diskSetUp) {
            true
        } else if let previousProblems {
            !problems.subtracting(previousProblems).isEmpty
        } else {
            !setupState.firstRunDone || problems.contains { $0.isRequired }
                // After an update, say so if BackMeUp no longer opens at login.
                || (isFirstLaunchAfterUpdate && problems.contains(.opensAtLogin))
        }
        previousProblems = problems
        if shouldShow { onShowChecklist?() }
    }

    // MARK: Choosing the backup disk

    /// The disks for the "Back up to" pop-up, when Time Machine has two or more. Empty otherwise,
    /// and before the first reading.
    public var diskChoices: [DiskChoice] { checklist?.item(.diskSetUp)?.diskChoices ?? [] }

    /// Every Time Machine disk as of the last reading, even when there's only one, and which one
    /// BackMeUp backs up to. For `--print-status`.
    public private(set) var disks: [ListedDisk] = []

    /// "Back up to": saves the disk BackMeUp backs up to, by its Time Machine ID, and re-reads
    /// the checklist straight away.
    public func chooseDisk(id: String?) async {
        guard !isUninstalled, changeDiskChoice({ $0.choose(id) }) else { return }
        system.log("Chose the backup disk")
        await readChecklist()
        describe()
    }

    /// Which disk BackMeUp backs up to, with the rules for changing it. Saved in the settings and
    /// the setup state; `changeDiskChoice` keeps them in step.
    private lazy var diskChoice = DiskChoiceState(settings: settings, setupState: setupState)

    /// Applies a change to the disk choice and saves whatever it changed.
    private func changeDiskChoice<Result>(_ change: (inout DiskChoiceState) -> Result) -> Result {
        var state = diskChoice
        let result = change(&state)
        guard state != diskChoice else { return result }
        diskChoice = state
        var newSettings = settings, newSetupState = setupState
        state.save(into: &newSettings, &newSetupState)
        if newSettings != settings {
            settings = newSettings
            system.saveSettings(settings)
        }
        if newSetupState != setupState {
            setupState = newSetupState
            system.saveSetupState(setupState)
        }
        return result
    }

    /// Follows a new reading of Time Machine's disks: clears the choice when that disk left Time
    /// Machine, sending the "choose a backup disk" alert once if there's a disk left to choose,
    /// or keeps the disk BackMeUp used when a second one was added, with no alert. Returns
    /// whether the choice was cleared. Backups wait until the user chooses again, however many
    /// disks are left.
    private func followDiskChoice(_ reading: DestinationInfo) -> Bool {
        switch changeDiskChoice({ $0.update(for: reading) }) {
        case .none:
            return false
        case let .chosenDiskRemoved(disksLeft):
            system.log("The chosen backup disk is no longer in Time Machine\(disksLeft == 0 ? "" : "; asking which disk to back up to")")
            if disksLeft > 0 {
                sendChooseDiskAlert("The disk you chose is no longer in Time Machine, so backups are paused. Choose a disk in BackMeUp's checklist to start them again.")
            }
            return true
        case .keptLastUsedDisk:
            system.log("Time Machine has a new disk; still backing up to the disk BackMeUp used")
            return false
        }
    }

    /// At the first launch after an update, when Time Machine has several disks and none is
    /// chosen, backups wait for check 1 and the "choose a backup disk" alert is sent. Only that
    /// launch counts as the update, so it's sent once.
    private func askToChooseDiskAfterUpdateIfNeeded() {
        guard !diskChoice.chosenDiskRemoved, case .several = destination,
              checklist?.item(.diskSetUp)?.needsDiskChoice == true else { return }
        system.log("Several Time Machine disks and none chosen after an update; asking which disk to back up to")
        sendChooseDiskAlert("Time Machine has more than one disk, so backups are paused until you choose which one BackMeUp backs up to. Choose it in BackMeUp's checklist.")
    }

    /// The "Choose a backup disk" alert, on every channel.
    private func sendChooseDiskAlert(_ body: String) {
        send(Alert(kind: .chooseDisk, title: "Choose a backup disk", body: body))
    }

    /// A backup held back by an unfinished checklist starts as soon as the checklist allows it,
    /// rather than at the next retry, if it was due by the backup interval.
    private var isSetupJustFinished: Bool {
        guard let reason = skipReason, reason.isSetupReason, checklist?.allowsBackups == true else { return false }
        return system.now >= dueByInterval
    }

    /// A Back Up Now skipped for another disk's backup doesn't hold back a backup due by the
    /// backup interval: it starts as soon as that backup ends, rather than at the next retry.
    private var isOtherDiskBackupOver: Bool {
        guard skipReason == .timeMachineBackingUpToAnotherDisk, !isTimeMachineRunning else { return false }
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

    /// Time Machine's backup disk as of the last checklist reading.
    private var destination: DestinationInfo?

    /// Story 35: after a new router, the home network has a new address and no longer counts as
    /// chosen. If the network disk is mounted (so the Mac can reach it) on a network that isn't
    /// chosen, asks once per network, with a Mac notification, whether to allow backups on it.
    /// Before any network is chosen, checklist check 6 asks instead.
    private func askToChooseThisNetworkIfNeeded() {
        guard !networks.allNetworks, !networks.chosen.isEmpty,
              case let .router(address, _)? = currentNetwork, networks.network(routerAddress: address) == nil,
              case let .configured(disk)? = destination, disk.kind == .network, disk.mountPoint != nil,
              setupState.networksAskedAbout?.contains(address) != true
        else { return }
        setupState.networksAskedAbout = (setupState.networksAskedAbout ?? []) + [address]
        system.saveSetupState(setupState)
        system.log("Asked whether to allow backups on a network that isn't chosen")
        system.showNotification(Alert(
            kind: .chooseNetwork,
            title: "Back up on this network?",
            body: "Your backup disk can be reached on this network, but it isn't one you chose, so backups are waiting. If it's your network with a new router, choose \u{201C}Allow backups on this network\u{201D} in the BackMeUp menu."
        ))
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
    /// After Uninstall…, it deletes the settings and the log once more, in case macOS or a framework saved
    /// something for BackMeUp while the reminder was showing.
    public func prepareToQuit() {
        backupCommandRunning = false
        updateSleepPrevention()
        if isUninstalled {
            system.deleteAllSettings()
            system.deleteLog()
        }
    }

    // MARK: Uninstall

    /// Whether Uninstall… has run. From then on BackMeUp starts no backups, sends no alerts and
    /// saves nothing, while the app shows its reminder and quits. `UninstallableSystem` enforces
    /// it for every save; the scheduler's entry points (ticks, refreshes, Back Up Now) also stop
    /// reading the Mac, so the checklist isn't shown again.
    public var isUninstalled: Bool { system.isUninstalled }

    /// Uninstall…: removes BackMeUp from Login Items and deletes its settings, its log and every
    /// Keychain item it made. Time Machine's settings and backups are never touched.
    public func uninstall() {
        system.uninstall()
        backupCommandRunning = false
        updateSleepPrevention()
        system.unregisterLoginItem()
        system.deleteAllSettings()
        system.deleteLog()
        for secret in Secret.allCases {
            system.saveSecret(nil, as: secret)
        }
    }

    /// Show Log: opens the log file. Returns false if it couldn't be opened.
    public func showLog() -> Bool {
        system.openLog()
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

    /// Saves new settings, raised to the minimums. The chosen disk stays as it is: only
    /// `chooseDisk(id:)` changes it.
    public func updateSettings(_ newSettings: BackupSettings) {
        let destinationID = settings.destinationID
        settings = newSettings.validated
        settings.destinationID = destinationID
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
            system.log(attempt.outcome.logLine)
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
        // Scheduled backups wait for another disk's backup at the tick; Back Up Now is skipped.
        timeMachineStatus = await system.readTimeMachineStatus()
        if isTimeMachineRunningToAnotherDisk {
            return BackupAttempt(started: started, finished: started, outcome: .skipped(.timeMachineBackingUpToAnotherDisk))
        }
        if !byPerson, !settings.allowBackupsOnBattery, system.powerSource == .battery {
            return BackupAttempt(started: started, finished: started, outcome: .skipped(.onBattery))
        }
        // The disk the checklist was just read for: the chosen one, with several.
        let destination = self.destination ?? .unknown
        switch destination {
        case .several:
            // Several disks and none chosen: check 1 holds this back first.
            return BackupAttempt(started: started, finished: started, outcome: .skipped(.setupNotFinished))
        case .notSetUp:
            return BackupAttempt(started: started, finished: started, outcome: .skipped(.noDiskSetUp))
        case .configured, .unknown:
            break
        }
        // nil when Time Machine's disks can't be read: let Time Machine try, and judge it by its result.
        let disk = destination.disks.first
        if let disk, disk.kind == .local, disk.mountPoint == nil {
            return BackupAttempt(started: started, finished: started, outcome: .skipped(.diskNotConnected))
        }
        let destinationID = disk?.id

        // Network rules hold back network disks, and a disk we can't identify, but never a local one.
        if disk?.kind != .local {
            let network = await system.readNetwork()
            currentNetwork = network
            if let reason = networks.skipReason(on: network) {
                return BackupAttempt(started: started, finished: started, outcome: .skipped(reason))
            }
        }

        let before = BackupVerdict.Before(await system.readPreferences(), destinationID: destinationID)
        backupCommandRunning = true
        updateSleepPrevention()
        let destinationArgument = diskChoice.destinationArgument(for: destinationID)
        changeDiskChoice { $0.recordBackupStarting(to: destinationID) }
        let exitCode = await system.startBackup(destinationID: destinationArgument)
        backupCommandRunning = false
        updateSleepPrevention()
        let verdict = BackupVerdict(
            before: before,
            exitCode: exitCode,
            after: exitCode == nil ? nil : await system.readPreferences()?.destination(id: destinationID),
            diskKind: disk?.kind,
            isFirstBackup: history.lastSuccess == nil
        )
        return BackupAttempt(started: started, finished: system.now, outcome: verdict.outcome)
    }

    /// Keeps the Mac awake only while BackMeUp's backup runs on AC power. On battery it sleeps as
    /// normal. Checked again whenever the power source changes, and at every tick.
    private func updateSleepPrevention() {
        system.setIdleSleepPrevented(backupCommandRunning && system.powerSource != .battery)
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
        system.log("Alert sent: \(alert.title)")
        system.showNotification(alert)
        let tag = switch alert.kind {
        case .failed, .overdue, .chooseNetwork, .chooseDisk: NtfyTag.warning
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
        guard isTimeMachineRunningToChosenDisk else {
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
            isBackingUp: isBackingUp || isTimeMachineRunningToChosenDisk,
            isBackingUpToAnotherDisk: !isBackingUp && isTimeMachineRunningToAnotherDisk,
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
