import Foundation

/// The menu's text, worked out from what the scheduler knows. Pure: no reading or writing.
struct MenuText {
    var history: BackupHistory
    var nextBackupDue: Date
    /// Whether a backup is running, BackMeUp's or one Time Machine started itself.
    var isBackingUp: Bool
    var progress: BackupProgress?
    /// The time left in the running backup, if it can be told.
    var timeLeft: TimeInterval?
    /// Whether the checklist is holding backups back.
    var isWaitingForSetup: Bool
    var currentNetwork: NetworkReading?
    var networks: NetworkSettings
    var dates: RelativeDate

    /// The first line: the last backup, or what went wrong with it.
    var statusLine: String {
        if isBackingUp { return progressLine }
        if isWaitingForSetup { return "Finish setting up: see the checklist" }
        switch history.attempts.last?.outcome {
        case let .failed(reason)?:
            return "Last backup failed: \(reason.description)"
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

    /// The second line: when the next backup is planned. Empty while backing up.
    var nextBackupLine: String {
        if isBackingUp { return "" }
        if isWaitingForSetup { return "Backups start once setup is finished" }
        let label = switch history.attempts.last?.outcome ?? .succeeded {
        case .succeeded: "Next backup"
        case .paused: "Resumes"
        case .failed, .skipped: "Next try"
        }
        return nextBackupDue <= dates.now ? "\(label): now" : "\(label): \(dates.describe(nextBackupDue))"
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
