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
    /// The menu's last status line, under the strip of dots: when the next backup is planned.
    public private(set) var nextBackupLine = ""
    /// The note under the first line while any Time Machine backup runs, to the chosen disk or
    /// another: the Mac stays awake until it finishes, so don't close the lid. Empty otherwise.
    public private(set) var stayAwakeNote = ""
    /// The strip of dots, between the first line (or the stay-awake note under it) and the next
    /// backup line: which recent hours, days or weeks (the backup interval's unit) were backed up.
    public private(set) var backupStrip = BackupStrip.hidden

    /// The first-run checklist as of the last tick or refresh, or nil before the first one.
    /// Backups are scheduled only while it allows them.
    public private(set) var checklist: Checklist?

    /// Called when the checklist window should be shown: on first launch, at a launch with check
    /// 1, 2 or 6 not done, and whenever a check stops passing.
    public var onShowChecklist: (() -> Void)?

    /// Called whenever the menu's lines may have changed, for example when a backup finishes.
    public var onChange: (() -> Void)?

    private var timeMachineStatus = TimeMachineStatus.unknown
    /// The last stage name Time Machine gave, nil for none, to log when it changes.
    private var lastPhaseName: String?
    private var progress: BackupProgress?
    /// The running backup to the chosen disk, seen copying. Stored as the backup's size once it
    /// succeeds; dropped if it doesn't.
    private var watchedBackup: WatchedBackup?

    private struct WatchedBackup {
        /// Time Machine's total, as last seen while copying.
        var totalBytes: Int64
        /// The disk Time Machine named for it.
        var destinationID: String?
        /// The newest backup on the disk at the first checklist reading after it was seen
        /// (`.distantPast` for none, nil before that reading), to tell whether a new one appears
        /// when it ends.
        var newestBackupBefore: Date?
    }
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
        guard case let .running(runningTo, _) = timeMachineStatus else { return false }
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

    /// Why Back Up Now can't be chosen right now, for the menu to show under it, or nil when it can.
    /// Time Machine refuses a new backup while any backup, or its cleanup, is still running.
    public private(set) var backUpNowUnavailableReason: String?

    /// Why the last due backup was skipped, while that's still the latest news. For alerts.
    public var skipReason: SkipReason? {
        if case let .skipped(reason) = history.attempts.last?.outcome { reason } else { nil }
    }

    /// When the next backup is due: the backup interval after the last success, but no sooner than
    /// the retry interval after a failure or skip. With no success yet, straight away.
    public var nextBackupDue: Date {
        // After a restart while Time Machine was stuck: one backup, a few minutes after launch.
        if let backupAfterRestartDue { return backupAfterRestartDue }
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
        await readTimeMachineStatus()
        currentNetwork = await system.readNetwork()
        await readProgress()
        let isUpdated = isFirstLaunchAfterUpdate
        if !setupState.firstRunDone || isUpdated {
            registerLoginItem()
        }
        await readChecklist()
        noteSizeOfTimeMachinesOwnBackup()
        if isUpdated { askToChooseDiskAfterUpdateIfNeeded() }
        if !setupState.firstRunDone || isUpdated {
            setupState.firstRunDone = true
            setupState.lastLaunchedVersion = system.appVersion
            system.saveSetupState(setupState)
        }
        askToChooseThisNetworkIfNeeded()
        planBackupAfterRestartIfNeeded()
        updateSleepPrevention()
        let isWaitingAfterRestart = backupAfterRestartDue.map { system.now < $0 } ?? false
        if !isBackingUp, !isTimeMachineRunning, !isWaitingAfterRestart,
           system.now >= nextBackupDue || isBackOnAChosenNetwork || isSetupJustFinished || isOtherDiskBackupOver {
            startAttempt(byPerson: false)
        }
        checkAlerts()
        describe()
    }

    /// Re-reads Time Machine's state for the menu without ever starting a backup.
    public func refreshStatus() async {
        guard !isUninstalled else { return }
        await readTimeMachineStatus()
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
        let chosenDiskEntry = Self.chosenDisk(in: preferences, destination)
        chosenDiskBackups = chosenDiskEntry?.snapshotDates ?? []
        // The disk's backups are known only now, so a backup first seen before this reading (as
        // when BackMeUp launches mid-backup) gets its starting point here.
        if chosenDiskEntry != nil, watchedBackup != nil, watchedBackup?.newestBackupBefore == nil {
            watchedBackup?.newestBackupBefore = chosenDiskBackups.max() ?? .distantPast
        }
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
    /// When each backup Time Machine has on the chosen disk was made, as of the last checklist
    /// reading. Empty while no disk is chosen.
    private var chosenDiskBackups: [Date] = []

    /// The chosen disk's entry in Time Machine's preferences: by its ID, or the only entry when
    /// the disks couldn't be read. Never a disk that isn't chosen.
    private static func chosenDisk(
        in preferences: TimeMachinePreferences?, _ destination: DestinationInfo?
    ) -> TimeMachinePreferences.DestinationEntry? {
        switch destination {
        case let .configured(disk)?: preferences?.destination(id: disk.id)
        case .unknown?: preferences?.destination(id: nil)
        case .several?, .notSetUp?, nil: nil
        }
    }

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
        backupStrip = .hidden
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

    // MARK: Troubleshoot

    /// How long after launch the backup after a restart starts: an older Mac may still be busy
    /// starting up.
    static let backupAfterRestartDelay: TimeInterval = 5 * 60
    /// A `RESULT` 26 this soon after `tmutil startbackup` began means Time Machine didn't try to
    /// reach the disk. Seen at well under a second when it was stuck; reaching a server that's
    /// gone takes longer.
    static let stuckFailureSeconds: TimeInterval = 10

    /// What Troubleshoot found the last time it ran: after a failed backup, or from the menu.
    /// nil before it has run, and after a success.
    public private(set) var troubleshootReport: TroubleshootReport?

    /// Whether Troubleshoot found something to fix. The menu then offers "How to Fix This…".
    public var needsFixing: Bool { troubleshootReport?.firstFailure != nil }

    /// Troubleshoot's findings as plain text, for Copy Details. Names no server, network or address.
    public var troubleshootDetails: String? {
        troubleshootReport?.details(
            history: history,
            appVersion: system.appVersion,
            dates: RelativeDate(now: system.now, calendar: calendar)
        )
    }

    /// When the one backup after a restart is due, while it's waiting to start.
    private var backupAfterRestartDue: Date?
    /// Whether this launch has looked for a restart since Time Machine got stuck.
    private var lookedForRestart = false

    /// Runs Troubleshoot's checks now: the network, whether the server answers, and whether Time
    /// Machine is stuck. Never starts a backup. Time Machine counts as stuck from the last backup's
    /// result, since only a backup attempt shows it.
    public func troubleshoot() async {
        guard !isUninstalled else { return }
        currentNetwork = await system.readNetwork()
        // The backup disk as last read: every backup and every tick reads it.
        if destination == nil { await readChecklist() }
        let disk: Destination? = if case let .configured(disk)? = destination { disk } else { nil }
        var serverAnswers: Bool?
        if disk?.kind == .network, let host = disk?.serverHost {
            serverAnswers = await system.serverAnswers(host: host)
        }
        troubleshootReport = TroubleshootReport(
            TroubleshootInputs(disk: disk, network: currentNetwork, networks: networks, serverAnswers: serverAnswers, stuck: history.stuck),
            date: system.now
        )
        describe()
    }

    /// At the first tick after launch: if Time Machine was stuck and the Mac has restarted since,
    /// plans one backup a few minutes from now, under the usual rules, to see whether that fixed it.
    private func planBackupAfterRestartIfNeeded() {
        guard !lookedForRestart else { return }
        lookedForRestart = true
        guard let stuck = history.stuck, stuck.hasRestarted(bootTime: system.bootTime) else { return }
        backupAfterRestartDue = system.now.addingTimeInterval(Self.backupAfterRestartDelay)
        system.log("The Mac has restarted since Time Machine got stuck; backing up in 5 minutes to check")
    }

    /// Whether a fast `RESULT` 26 from a network disk is Time Machine being stuck: the server
    /// answers, and Time Machine's log, if it can be read, shows it had lost the disk's mount.
    private func isTimeMachineStuck(disk: Destination?, commandStarted: Date) async -> Bool {
        let seconds = system.now.timeIntervalSince(commandStarted)
        guard seconds < Self.stuckFailureSeconds, let host = disk?.serverHost,
              await system.serverAnswers(host: host)
        else { return false }
        let lostMount = await system.timeMachineLostItsMount(from: commandStarted, to: system.now)
        system.log("Time Machine couldn't reach the disk after \(Int(seconds)) s with the server answering; "
            + (lostMount == nil ? "its log couldn't be read" : lostMount == true ? "its log shows it lost the disk's mount" : "its log doesn't show a lost mount"))
        return lostMount != false
    }

    /// Records that Time Machine is stuck, noting a restart since the last time. Returns whether
    /// it's still stuck after a restart.
    private func recordStuck(since started: Date) -> Bool {
        let bootTime = system.bootTime
        guard var stuck = history.stuck else {
            history.stuck = StuckRecord(since: started, bootTime: bootTime)
            return false
        }
        if stuck.hasRestarted(bootTime: bootTime) {
            stuck.restartDidNotHelp = true
            stuck.bootTime = bootTime
        }
        history.stuck = stuck
        return stuck.restartDidNotHelp
    }

    /// The sentence naming what Troubleshoot found at fault after a failed backup, when it's the
    /// network or the server, and the report is from after that backup.
    private var failureCause: String? {
        guard case .failed? = history.attempts.last?.outcome, let report = troubleshootReport,
              let last = history.attempts.last, report.date >= last.finished,
              let failure = report.firstFailure, failure.kind != .timeMachine
        else { return nil }
        return failure.sentence
    }

    // MARK: Running a backup

    /// `byPerson`: Back Up Now, rather than the schedule.
    private func startAttempt(byPerson: Bool) {
        guard backupTask == nil else { return }
        backupAfterRestartDue = nil
        backupTask = Task {
            let attempt = await runAttempt(byPerson: byPerson)
            // Uninstalled while Time Machine ran: Time Machine carries on, but nothing is recorded.
            // Nor when Time Machine was already backing up to the disk: nothing was tried.
            guard !isUninstalled, let attempt else {
                backupTask = nil
                describe()
                return
            }
            let isFirstSuccess = history.lastSuccess == nil && attempt.outcome == .succeeded
            let wasStuck = history.stuck != nil
            history.record(attempt, now: system.now, calendar: calendar)
            noteSizeOfOwnBackup(attempt)
            system.log(attempt.outcome.logLine)
            if isFirstSuccess, ntfy.isSetUp { history.firstBackupMessagePending = true }
            system.saveHistory(history)
            switch attempt.outcome {
            case .failed: await troubleshoot()
            case .succeeded: troubleshootReport = nil
            case .skipped, .paused: break
            }
            checkAlerts(fixedByRestart: wasStuck)
            sendFirstBackupMessageIfPending()
            backupTask = nil
            describe()
        }
        describe()
    }

    /// nil when Time Machine was already backing up to the disk, so BackMeUp tried nothing. The
    /// menu shows that backup's progress instead.
    private func runAttempt(byPerson: Bool) async -> BackupAttempt? {
        let started = system.now
        // Nothing starts, not even Back Up Now, until checks 1, 2 and 6 pass.
        await readChecklist()
        if let checklist, let reason = checklist.skipReason {
            return BackupAttempt(started: started, finished: started, outcome: .skipped(reason))
        }
        // Scheduled backups wait for another disk's backup at the tick; Back Up Now is skipped.
        await readTimeMachineStatus()
        if isTimeMachineRunningToAnotherDisk { return skippedForAnotherDisk(started: started) }
        if isTimeMachineRunning { return alreadyBackingUpToTheDisk() }
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
        let commandStarted = system.now
        let exitCode = await system.startBackup(destinationID: destinationArgument)
        backupCommandRunning = false
        updateSleepPrevention()
        // Time Machine started its own backup since the check above. `RESULT` is still the
        // previous backup's, so it says nothing about this one.
        if exitCode == Self.alreadyInProgressExitCode {
            await readTimeMachineStatus()
            if isTimeMachineRunningToAnotherDisk { return skippedForAnotherDisk(started: started) }
            if isTimeMachineRunning { return alreadyBackingUpToTheDisk() }
        }
        let verdict = BackupVerdict(
            before: before,
            exitCode: exitCode,
            after: exitCode == nil ? nil : await system.readPreferences()?.destination(id: destinationID),
            diskKind: disk?.kind,
            isFirstBackup: history.lastSuccess == nil
        )
        var outcome = verdict.outcome
        if outcome == .failed(.diskUnreachable(isNetworkDisk: true)),
           await isTimeMachineStuck(disk: disk, commandStarted: commandStarted) {
            outcome = .failed(.timeMachineStuck(afterRestart: recordStuck(since: started)))
        }
        return BackupAttempt(started: started, finished: system.now, outcome: outcome)
    }

    /// `tmutil startbackup`'s exit code when Time Machine is already backing up, with "Backup
    /// already in progress." Seen on macOS 27.2.
    static let alreadyInProgressExitCode: Int32 = 3

    /// Back Up Now while Time Machine backs up to another disk. Scheduled backups wait for it at
    /// the tick instead.
    private func skippedForAnotherDisk(started: Date) -> BackupAttempt {
        BackupAttempt(started: started, finished: started, outcome: .skipped(.timeMachineBackingUpToAnotherDisk))
    }

    /// Time Machine is already backing up to the disk: nothing to try and nothing to record. The
    /// menu shows that backup's progress.
    private func alreadyBackingUpToTheDisk() -> BackupAttempt? {
        system.log("Backup not started: Time Machine is already backing up to the disk")
        return nil
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
    /// `fixedByRestart`: the backup just recorded was the first success since Time Machine was stuck.
    private func checkAlerts(fixedByRestart: Bool = false) {
        if history.lastAlertSent != nil, let lastSuccess = history.lastSuccess,
           history.attempts.last?.outcome == .succeeded {
            history.lastAlertSent = nil
            system.saveHistory(history)
            hasProblem = false
            send(fixedByRestart
                ? Alert(kind: .workingAgain, title: "Fixed: backing up again", body: "Restarting your Mac fixed Time Machine. Last backup: \(format(lastSuccess))")
                : Alert(kind: .workingAgain, title: "Backups are working again", body: "Last backup: \(format(lastSuccess))"))
            return
        }
        if history.monitoringSince == nil {
            history.monitoringSince = system.now
            system.saveHistory(history)
        }
        let policy = AlertPolicy(history: history, settings: settings.alerts, now: system.now, calendar: calendar, failureCause: failureCause)
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

    // MARK: Time Machine's state

    /// Reads whether Time Machine is running, and logs each change of its stage name, so real
    /// names (including ones the menu doesn't know yet) build up in the log. An unreadable status
    /// says nothing about the stage, so it's not counted as a change.
    private func readTimeMachineStatus() async {
        timeMachineStatus = await system.readTimeMachineStatus()
        guard timeMachineStatus != .unknown else { return }
        let phase = timeMachineStatus.phase
        if phase != lastPhaseName {
            system.log("Phase: \(lastPhaseName ?? "none") -> \(phase ?? "none")")
            lastPhaseName = phase
        }
    }

    // MARK: Progress

    private func readProgress() async {
        guard isTimeMachineRunningToChosenDisk else {
            progress = nil
            progressStart = nil
            if isTimeMachineRunningToAnotherDisk { watchedBackup = nil }
            return
        }
        progress = await system.readBackupProgress()
        if let progress, progress.fraction < progressStart?.fraction ?? .infinity {
            progressStart = (system.now, progress.fraction)
        }
        if case let .running(runningTo, _) = timeMachineStatus, timeMachineStatus.stage == .copying,
           let totalBytes = progress?.totalBytes {
            // The newest backup before stays unknown until a checklist reading has found the
            // disk's backups; see `readChecklist`.
            watchedBackup = WatchedBackup(
                totalBytes: totalBytes, destinationID: runningTo,
                newestBackupBefore: watchedBackup?.newestBackupBefore
            )
        }
    }

    /// A backup BackMeUp watched copying, but didn't start, has ended: if it left a new backup on
    /// the disk, notes its size against that backup's date. BackMeUp's own backups are noted when
    /// their attempt is recorded.
    private func noteSizeOfTimeMachinesOwnBackup() {
        guard let watched = watchedBackup, backupTask == nil, timeMachineStatus != .unknown,
              !isTimeMachineRunningToChosenDisk
        else { return }
        watchedBackup = nil
        guard isChosenDisk(watched.destinationID), !isUninstalled,
              let newestBefore = watched.newestBackupBefore,
              let newest = chosenDiskBackups.max(), newest > newestBefore
        else { return }
        history.recordSize(watched.totalBytes, finished: newest, now: system.now, calendar: calendar)
        system.saveHistory(history)
    }

    /// Whether a backup Time Machine said went to `id` went to the disk whose backups the strip
    /// counts. A disk Time Machine didn't name, or the only one when the disks can't be read, is.
    private func isChosenDisk(_ id: String?) -> Bool {
        switch destination {
        case let .configured(disk)?: id == nil || id == disk.id
        case .unknown?: true
        case .several?, .notSetUp?, nil: false
        }
    }

    /// BackMeUp's own backup has ended as `outcome`: notes its size if it succeeded. A failed or
    /// paused backup keeps none; a resumed one is noted afresh from its own run.
    private func noteSizeOfOwnBackup(_ attempt: BackupAttempt) {
        switch attempt.outcome {
        case .succeeded:
            if let watched = watchedBackup, isChosenDisk(watched.destinationID) {
                history.recordSize(watched.totalBytes, finished: attempt.finished, now: system.now, calendar: calendar)
            }
            watchedBackup = nil
        case .failed, .paused:
            watchedBackup = nil
        case .skipped:
            break
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

    /// The running backup's stage, for the menu. A backup BackMeUp has started is getting ready
    /// until Time Machine reports it running, so the menu shows the request was taken. From then
    /// on the stage is Time Machine's own, so an unknown or missing name gets the neutral line.
    private var backupStage: BackupStage {
        if isBackingUp, !isTimeMachineRunning { return .gettingReady }
        return timeMachineStatus.stage
    }

    private func updateLines() {
        let text = MenuText(
            history: history,
            nextBackupDue: nextBackupDue,
            isBackingUp: isBackingUp || isTimeMachineRunningToChosenDisk,
            isBackingUpToAnotherDisk: !isBackingUp && isTimeMachineRunningToAnotherDisk,
            stage: backupStage,
            progress: progress,
            timeLeft: timeLeft,
            isWaitingForSetup: checklist?.allowsBackups == false,
            currentNetwork: currentNetwork,
            networks: networks,
            dates: RelativeDate(now: system.now, calendar: calendar),
            failureCause: failureCause
        )
        statusLine = text.statusLine
        nextBackupLine = text.nextBackupLine
        stayAwakeNote = text.stayAwakeNote
        backUpNowUnavailableReason = text.backUpNowUnavailableReason
        networkLine = text.networkLine
        backupStrip = BackupStripText(
            history: history,
            interval: settings.backupInterval,
            timeMachineBackups: chosenDiskBackups,
            isShown: !isUninstalled && (checklist?.allowsBackups == true || !chosenDiskBackups.isEmpty),
            isBackingUp: isBackingUp || isTimeMachineRunningToChosenDisk,
            progress: progress,
            now: system.now,
            calendar: calendar
        ).strip
    }

    /// "today 14:02", "yesterday 09:15", "tomorrow 14:02", or "3 Jan 14:02".
    private func format(_ date: Date) -> String {
        RelativeDate(now: system.now, calendar: calendar).describe(date)
    }
}
