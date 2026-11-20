import Foundation

/// One line of the first-run checklist.
public struct ChecklistItem: Equatable, Sendable {
    /// The six checks, in the order the checklist shows them.
    public enum Check: Int, CaseIterable, Sendable {
        case diskSetUp = 1
        case automaticBackupsOff
        case diskEncrypted
        case opensAtLogin
        case notificationsAllowed
        case networkChosen

        /// Checks 1, 2 and 6: backups are scheduled only while all of these pass.
        public var isRequired: Bool {
            self == .diskSetUp || self == .automaticBackupsOff || self == .networkChosen
        }
    }

    public enum State: Equatable, Sendable {
        case passed
        case failed
        /// Failing, but only a warning: it never holds backups back (check 3).
        case warning
        /// BackMeUp can't tell. For a required check, backups wait, as they would for a failure.
        case unknown
        /// Doesn't apply to this Mac, such as a chosen network for a USB disk.
        case notNeeded
    }

    /// What the item's button does.
    public enum Action: Equatable, Sendable {
        /// Open Settings: a System Settings screen.
        case openSystemSettings(SystemSettingsPane)
        /// Ask macOS to let BackMeUp show notifications.
        case allowNotifications
        /// Open BackMeUp's own Settings window (chosen networks).
        case openBackMeUpSettings
    }

    public var check: Check
    public var state: State
    /// One plain sentence saying what's set up, or what to do.
    public var sentence: String
    public var action: Action
    /// Step-by-step directions in plain text, for when the button can't do the job.
    public var directions: String
    /// Whether to show `directions`: the Settings link failed to open, or the user has to do it by hand.
    public var showsDirections = false
    /// Check 1 with two or more Time Machine disks: the disks for its "Back up to" pop-up, in
    /// Time Machine's order. Empty otherwise.
    public var diskChoices: [DiskChoice] = []
    /// The disk chosen in the pop-up, or nil until the user chooses.
    public var chosenDiskID: String?

    /// Whether the pop-up shows a "Choose a disk…" placeholder: there are disks to choose from,
    /// and the chosen one isn't among them.
    public var needsDiskChoice: Bool {
        !diskChoices.isEmpty && !diskChoices.contains { $0.id == chosenDiskID }
    }

    /// Whether the check is done, or doesn't apply.
    public var isSatisfied: Bool { state == .passed || state == .notNeeded }

    /// The button's title.
    public var buttonTitle: String {
        action == .allowNotifications ? "Allow Notifications" : "Open Settings"
    }
}

/// What the checklist reads to decide each check.
struct ChecklistInputs {
    /// Time Machine's disks as read.
    var destination: DestinationInfo
    /// The disk the user chose, when Time Machine has several.
    var chosenDiskID: String?
    /// Whether the chosen disk left Time Machine and the user hasn't chosen again.
    var chosenDiskRemoved: Bool
    /// Whether a second disk was added and the disk BackMeUp was using was kept as the choice,
    /// until the user chooses again.
    var newDiskAdded = false
    var preferences: TimeMachinePreferences?
    /// The scheduler's clock, for how long ago each disk was last backed up to.
    var now: Date
    var networks: NetworkSettings
    var loginItem: LoginItemStatus
    var notifications: NotificationPermission
    /// Checks whose Settings link failed to open.
    var linkFailed: Set<ChecklistItem.Check>
}

/// The first-run checklist: six checks, decided from the real state of the Mac.
public struct Checklist: Equatable, Sendable {
    public var items: [ChecklistItem]

    /// Scheduling runs only while checks 1, 2 and 6 pass.
    public var allowsBackups: Bool {
        items.allSatisfy { !$0.check.isRequired || $0.isSatisfied }
    }

    /// Why backups are held back, or nil when checks 1, 2 and 6 pass.
    var skipReason: SkipReason? {
        if allowsBackups { return nil }
        // A disk to choose is setup still to finish, not a missing disk.
        guard let disk = item(.diskSetUp), disk.state == .failed, disk.diskChoices.isEmpty else { return .setupNotFinished }
        return .noDiskSetUp
    }

    /// The checks that aren't done (failing, a warning, or can't tell).
    var problems: Set<ChecklistItem.Check> {
        Set(items.filter { !$0.isSatisfied }.map(\.check))
    }

    public func item(_ check: ChecklistItem.Check) -> ChecklistItem? {
        items.first { $0.check == check }
    }

    init(_ inputs: ChecklistInputs) {
        // Checks 1, 3 and 6 are about the chosen disk.
        let destination = inputs.destination.choosing(inputs.chosenDiskID)
        let disks = inputs.destination.disks
        // The chosen disk left Time Machine: ask, even with one disk left.
        let chosenDiskGone = inputs.chosenDiskRemoved && !disks.isEmpty
        var diskSetUp = chosenDiskGone
            ? Self.chosenDiskGone
            : Self.diskSetUp(destination, newDiskAdded: inputs.newDiskAdded && disks.count > 1)
        if disks.count > 1 || chosenDiskGone {
            diskSetUp.diskChoices = disks.compactMap { DiskChoice($0, preferences: inputs.preferences, now: inputs.now) }
            if case .configured = destination { diskSetUp.chosenDiskID = inputs.chosenDiskID }
        }
        items = [
            diskSetUp,
            Self.automaticBackupsOff(inputs.preferences),
            Self.diskEncrypted(destination, inputs.preferences),
            Self.opensAtLogin(inputs.loginItem),
            Self.notificationsAllowed(inputs.notifications),
            Self.networkChosen(destination, inputs.networks),
        ]
        for index in items.indices where inputs.linkFailed.contains(items[index].check) {
            items[index].showsDirections = true
        }
    }

    // MARK: The checks

    private static let timeMachine = ChecklistItem.Action.openSystemSettings(.timeMachine)
    private static let timeMachineDirections = "Open System Settings, then General > Time Machine."

    private static let diskSetUpDirections = "\(timeMachineDirections) Click Add Backup Disk and choose your backup disk."

    /// Check 1 when the chosen disk left Time Machine, until the user chooses again.
    private static let chosenDiskGone = ChecklistItem(
        check: .diskSetUp,
        state: .failed,
        sentence: "The disk you chose is no longer in Time Machine. Choose a disk to start backups again.",
        action: timeMachine,
        directions: diskSetUpDirections
    )

    private static func diskSetUp(_ destination: DestinationInfo, newDiskAdded: Bool) -> ChecklistItem {
        let directions = diskSetUpDirections
        return switch destination {
        case let .configured(disk):
            ChecklistItem(
                check: .diskSetUp,
                state: .passed,
                sentence: newDiskAdded
                    ? "Time Machine has a new disk. BackMeUp still backs up to \(disk.displayName)."
                    : "A Time Machine disk is set up.",
                action: timeMachine,
                directions: directions
            )
        case .several:
            ChecklistItem(
                check: .diskSetUp,
                state: .failed,
                sentence: "Choose which disk BackMeUp backs up to.",
                action: timeMachine,
                directions: directions
            )
        case .notSetUp:
            ChecklistItem(
                check: .diskSetUp,
                state: .failed,
                sentence: "Set up a Time Machine disk: add your backup disk in Time Machine settings. Backups can't start without one.",
                action: timeMachine,
                directions: directions
            )
        case .unknown:
            ChecklistItem(
                check: .diskSetUp,
                state: .unknown,
                sentence: "BackMeUp can't tell whether a Time Machine disk is set up. Check Time Machine settings.",
                action: timeMachine,
                directions: directions
            )
        }
    }

    private static func automaticBackupsOff(_ preferences: TimeMachinePreferences?) -> ChecklistItem {
        let directions = "\(timeMachineDirections) Click Options and set Back up frequency to Manually."
        return switch preferences?.autoBackup {
        case false?:
            ChecklistItem(check: .automaticBackupsOff, state: .passed, sentence: "Time Machine's automatic backups are off.",
                          action: timeMachine, directions: directions)
        case true?:
            ChecklistItem(
                check: .automaticBackupsOff,
                state: .failed,
                sentence: "Turn off Time Machine's automatic backups, so that BackMeUp's schedule is the one that runs.",
                action: timeMachine,
                directions: directions
            )
        case nil:
            ChecklistItem(
                check: .automaticBackupsOff,
                state: .unknown,
                sentence: "BackMeUp can't tell whether Time Machine's automatic backups are off. Check Time Machine settings.",
                action: timeMachine,
                directions: directions
            )
        }
    }

    private static func diskEncrypted(_ destination: DestinationInfo, _ preferences: TimeMachinePreferences?) -> ChecklistItem {
        let directions = "\(timeMachineDirections) Encrypting a disk that's already set up means removing it and adding it again with Encrypt Backup turned on."
        let id: String? = if case let .configured(disk) = destination { disk.id } else { nil }
        let encryption = preferences?.destination(id: id)?.encryption ?? .unknown
        return switch encryption {
        case .encrypted:
            ChecklistItem(check: .diskEncrypted, state: .passed, sentence: "Your backup disk is encrypted.",
                          action: timeMachine, directions: directions)
        case .notEncrypted:
            ChecklistItem(
                check: .diskEncrypted,
                state: .warning,
                sentence: "Your backup disk isn't encrypted, so anyone who gets hold of it can read your files. You can choose to encrypt it in Time Machine settings.",
                action: timeMachine,
                directions: directions
            )
        case .unknown:
            ChecklistItem(
                check: .diskEncrypted,
                state: .unknown,
                sentence: "BackMeUp can't tell yet whether your backup disk is encrypted.",
                action: timeMachine,
                directions: directions
            )
        }
    }

    private static func opensAtLogin(_ status: LoginItemStatus) -> ChecklistItem {
        let action = ChecklistItem.Action.openSystemSettings(.loginItems)
        let directions = "Open System Settings, then General > Login Items & Extensions. Under \"Open at Login\", click + and choose BackMeUp in your Applications folder."
        switch status {
        case .enabled:
            return ChecklistItem(check: .opensAtLogin, state: .passed, sentence: "BackMeUp opens at login.",
                                 action: action, directions: directions)
        case .requiresApproval:
            return ChecklistItem(
                check: .opensAtLogin,
                state: .failed,
                sentence: "Allow BackMeUp in Login Items, so that backups keep running after a restart.",
                action: action,
                directions: directions,
                showsDirections: true
            )
        case .notRegistered, .notFound:
            return ChecklistItem(
                check: .opensAtLogin,
                state: .failed,
                sentence: "BackMeUp couldn't add itself to Login Items. Add it by hand, so that backups keep running after a restart.",
                action: action,
                directions: directions,
                showsDirections: true
            )
        }
    }

    private static func notificationsAllowed(_ permission: NotificationPermission) -> ChecklistItem {
        let directions = "Open System Settings, then Notifications. Choose BackMeUp and turn on Allow notifications."
        return switch permission {
        case .allowed:
            ChecklistItem(check: .notificationsAllowed, state: .passed, sentence: "Notifications are allowed.",
                          action: .openSystemSettings(.notifications), directions: directions)
        case .notDetermined:
            ChecklistItem(
                check: .notificationsAllowed,
                state: .failed,
                sentence: "Allow notifications, so that BackMeUp can tell you when backups stop.",
                action: .allowNotifications,
                directions: directions
            )
        case .denied:
            ChecklistItem(
                check: .notificationsAllowed,
                state: .failed,
                sentence: "Notifications are off for BackMeUp. Turn them on, so that you find out when backups stop.",
                action: .openSystemSettings(.notifications),
                directions: directions
            )
        }
    }

    private static func networkChosen(_ destination: DestinationInfo, _ networks: NetworkSettings) -> ChecklistItem {
        let directions = "While you're on your home network, open the BackMeUp menu and choose \"Allow backups on this network\". Or turn on any network in BackMeUp Settings."
        func item(_ state: ChecklistItem.State, _ sentence: String) -> ChecklistItem {
            ChecklistItem(check: .networkChosen, state: state, sentence: sentence,
                          action: .openBackMeUpSettings, directions: directions)
        }
        if case let .configured(disk) = destination, disk.kind == .local {
            return item(.notNeeded, "Your backup disk is a USB disk, so backups run on any network.")
        }
        if networks.allNetworks {
            return item(.passed, "Backups may run on any network.")
        }
        if !networks.chosen.isEmpty {
            return item(.passed, "At least one network is chosen for backups.")
        }
        var failed = item(.failed, "Choose a network for backups: on your home network, choose \"Allow backups on this network\" in the menu.")
        failed.showsDirections = true
        return failed
    }
}
