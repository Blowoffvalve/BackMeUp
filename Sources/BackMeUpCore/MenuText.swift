import Foundation

/// The menu's text, worked out from what the scheduler knows. Pure: no reading or writing.
struct MenuText {
    var history: BackupHistory
    var nextBackupDue: Date
    /// Whether a backup is running, BackMeUp's or one Time Machine started itself.
    var isBackingUp: Bool
    /// Whether Time Machine is backing up to a disk other than the chosen one, started from its own menu.
    var isBackingUpToAnotherDisk: Bool = false
    /// The stage of the running backup, to whichever disk it's going: what the line may claim.
    var stage: BackupStage = .unknown
    var progress: BackupProgress?
    /// The time left in the running backup, if it can be told.
    var timeLeft: TimeInterval?
    /// Whether the checklist is holding backups back.
    var isWaitingForSetup: Bool
    var currentNetwork: NetworkReading?
    var networks: NetworkSettings
    var dates: RelativeDate
    /// What Troubleshoot found after the last failed backup, as a sentence, when it found the
    /// network or the server at fault. A stuck Time Machine is named by the failure itself.
    var failureCause: String? = nil

    /// The first line: the last backup, or what went wrong with it.
    var statusLine: String {
        if isBackingUp { return backingUpLine }
        if isBackingUpToAnotherDisk { return anotherDiskLine }
        if isWaitingForSetup { return "Finish setting up: see the checklist" }
        switch history.attempts.last?.outcome {
        case let .failed(reason)?:
            if let failureCause { return "Last backup failed. \(failureCause)" }
            return "Last backup failed: \(reason.statusText)"
        case .skipped(.notOnChosenNetwork)?:
            return "Waiting for a chosen network"
        case let .skipped(reason)?:
            return "Backup skipped: \(reason.description)"
        case .paused?:
            return "First backup paused"
        case .succeeded?, nil:
            return history.lastSuccess.map { "Last backup: \(dates.describe($0))" } ?? "No backups yet"
        }
    }

    /// Shown under the greyed-out Back Up Now item: why it can't be chosen. nil when it can.
    var backUpNowUnavailableReason: String? {
        if isCleaningUp { return "Available once Time Machine finishes cleaning up" }
        if isBackingUp || isBackingUpToAnotherDisk { return "Available once this backup finishes" }
        return nil
    }

    /// The line under the strip of dots: when the next backup is planned. Empty while backing up.
    var nextBackupLine: String {
        if isBackingUp || isBackingUpToAnotherDisk { return "" }
        if isWaitingForSetup { return "Backups start once setup is finished" }
        let label = switch history.attempts.last?.outcome ?? .succeeded {
        case .succeeded: "Next backup"
        case .paused: "Resumes"
        case .failed, .skipped: "Next try"
        }
        return nextBackupDue <= dates.now ? "\(label): now" : "\(label): \(dates.describe(nextBackupDue))"
    }

    /// The note under the first line while any Time Machine backup runs, whoever started it and
    /// whichever disk it goes to. Time Machine keeps the Mac from idle sleep for the whole backup,
    /// on battery too; only closing the lid stops it. Empty otherwise.
    var stayAwakeNote: String {
        isBackingUp || isBackingUpToAnotherDisk ? "Your Mac will stay awake until this backup finishes. Don't close the lid." : ""
    }

    /// The network line: the current network's label and whether backups may run on it. Never
    /// shows the router's hardware address. Empty before the network has been read.
    var networkLine: String {
        switch currentNetwork {
        case nil:
            return ""
        case .none?:
            return "Network: not connected"
        case .routerAddressUnknown?:
            return "Network: not identified yet"
        case let .router(address, wifiName)?:
            let chosen = networks.network(routerAddress: address)
            let label = chosen?.label ?? wifiName ?? "this network"
            let state = if chosen != nil { "backups allowed" }
                else if networks.allNetworks { "all networks allowed" }
                else { "not chosen" }
            return "Network: \(label) (\(state))"
        }
    }

    /// Whether Time Machine is deleting old backups, to whichever disk it's backing up to.
    private var isCleaningUp: Bool { stage == .cleaningUp }

    private var isFirstBackup: Bool { history.lastSuccess == nil }

    /// A backup to the chosen disk, in BackMeUp's words but never claiming more than Time Machine's
    /// stage does. "First backup" in every stage until a backup has succeeded.
    private var backingUpLine: String {
        switch stage {
        case .gettingReady: isFirstBackup ? "Getting ready for first backup" : "Getting ready to back up"
        case .copying: progressLine
        case .cleaningUp: "Time Machine is cleaning up old backups"
        case .unknown: isFirstBackup ? "Time Machine is working on the first backup" : "Time Machine is working on a backup"
        }
    }

    /// A backup to a disk other than the chosen one. Its progress isn't shown.
    private var anotherDiskLine: String {
        switch stage {
        case .gettingReady: "Time Machine is getting ready to back up to another disk"
        case .copying: "Time Machine is backing up to another disk"
        case .cleaningUp: "Time Machine is cleaning up another disk"
        case .unknown: "Time Machine is working on another disk"
        }
    }

    /// While copying: "First backup: 35.0%, about 3 hours left", or "Backing up" before Time
    /// Machine gives a percent.
    private var progressLine: String {
        let label = isFirstBackup ? "First backup" : "Backing up"
        guard let progress else { return label }
        let percent = "\(label): \(progress.percentText)"
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
}

/// Dates as the menu and alerts word them, relative to now: "today 14:02", "yesterday 09:15",
/// "tomorrow 14:02", or "3 Jan 14:02", 24-hour, in the given calendar's time zone.
struct RelativeDate {
    var now: Date
    var calendar: Calendar

    func describe(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "HH:mm"
        let time = formatter.string(from: date)
        let today = calendar.startOfDay(for: now)
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
