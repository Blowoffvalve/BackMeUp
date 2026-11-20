import Foundation

public struct Destination: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case network
        case local
    }

    public var kind: Kind
    /// Time Machine's ID for the destination. Matches `DestinationID` in `tmutil status -X`
    /// and the destination entries in Time Machine's preferences.
    public var id: String?
    /// The disk's name as Time Machine shows it (`Name`), for labelling it.
    public var name: String?
    /// Where the disk is mounted, if it is. Network disks are usually not mounted between backups;
    /// Time Machine mounts them itself.
    public var mountPoint: String?

    public init(kind: Kind, id: String?, name: String? = nil, mountPoint: String? = nil) {
        self.kind = kind
        self.id = id
        self.name = name
        self.mountPoint = mountPoint
    }
}

extension Destination {
    /// The disk's name for the user, or "Unnamed disk" when it has none.
    var displayName: String {
        name.flatMap { $0.isEmpty ? nil : $0 } ?? "Unnamed disk"
    }
}

/// The Time Machine destinations, from `tmutil destinationinfo -X`.
public enum DestinationInfo: Equatable, Sendable {
    /// One disk: BackMeUp backs up to it.
    case configured(Destination)
    /// Two or more disks, in the order Time Machine lists them. The user chooses one.
    case several([Destination])
    /// Time Machine has no backup disk.
    case notSetUp
    /// `tmutil` couldn't be run, or its output wasn't understood.
    case unknown
}

extension DestinationInfo {
    /// Parses the plist printed by `tmutil destinationinfo -X`.
    public init(destinationInfoOutput: String) {
        // Without -X's plist, tmutil prints this sentence when no disk is set up.
        if destinationInfoOutput.contains("No destinations configured") {
            self = .notSetUp
            return
        }
        guard let entries = PlistDictionary(destinationInfoOutput)?.array("Destinations") else {
            self = .unknown
            return
        }
        if entries.isEmpty {
            self = .notSetUp
            return
        }
        // A disk of a kind we don't know is left out, rather than guessed at.
        var disks = entries.compactMap { entry in
            Destination.Kind(tmutilKind: entry.string("Kind")).map {
                Destination(kind: $0, id: entry.string("ID"), name: entry.string("Name"), mountPoint: entry.string("MountPoint"))
            }
        }
        // With several, a disk without an ID can't be chosen (`--destination` needs one).
        if disks.count > 1 {
            disks.removeAll { $0.id == nil }
        }
        switch disks.count {
        // No disk understood: can't tell.
        case 0: self = .unknown
        case 1: self = .configured(disks[0])
        default: self = .several(disks)
        }
    }
}

extension DestinationInfo {
    /// Every disk read, in Time Machine's order: one when configured, none when not set up or
    /// unknown.
    public var disks: [Destination] {
        switch self {
        case let .configured(disk): [disk]
        case let .several(disks): disks
        case .notSetUp, .unknown: []
        }
    }

    /// The disk BackMeUp backs up to: with several disks, the one with this ID, if it's among
    /// them. Otherwise the reading as it is, so several disks with none chosen stay `.several`.
    public func choosing(_ id: String?) -> DestinationInfo {
        guard case let .several(disks) = self, let id, let disk = disks.first(where: { $0.id == id }) else { return self }
        return .configured(disk)
    }
}

/// A disk in the "Back up to" pop-up.
public struct DiskChoice: Equatable, Sendable {
    /// Time Machine's ID for the disk, saved as the choice.
    public var id: String
    /// Its name and kind, whether it's encrypted when that's known, and when it was last backed
    /// up to: "Backups (Network disk, encrypted, last backup 3 days ago)".
    public var label: String

    public init(id: String, label: String) {
        self.id = id
        self.label = label
    }

    /// nil for a disk without an ID, which can't be chosen. The parser leaves those out when
    /// there are several.
    init?(_ disk: Destination, preferences: TimeMachinePreferences?, now: Date) {
        guard let id = disk.id else { return nil }
        self.init(id: id, label: Self.label(disk, preferences: preferences, now: now))
    }

    /// "Backups (Network disk, encrypted, last backup 3 days ago)".
    static func label(_ disk: Destination, preferences: TimeMachinePreferences?, now: Date) -> String {
        let entry = disk.id.flatMap { id in preferences?.destinations.first { $0.id == id } }
        var details = [disk.kind == .network ? "Network disk" : "USB disk"]
        switch entry?.encryption {
        case .encrypted?: details.append("encrypted")
        case .notEncrypted?: details.append("not encrypted")
        case .unknown?, nil: break
        }
        details.append(entry?.latestSnapshot.map { "last backup \(describe(age: now.timeIntervalSince($0)))" } ?? "never backed up")
        return "\(disk.displayName) (\(details.joined(separator: ", ")))"
    }

    /// "less than a minute ago", "45 minutes ago", "5 hours ago", "3 days ago", "4 months ago".
    /// Rounded down, so "1 day ago" means at least a whole day. A snapshot dated after now (a
    /// clock that moved back) counts as just made.
    private static func describe(age seconds: TimeInterval) -> String {
        func ago(_ count: Double, _ unit: String) -> String {
            let count = Int(count.rounded(.down))
            return "\(count) \(unit)\(count == 1 ? "" : "s") ago"
        }
        let minutes = seconds / 60, hours = minutes / 60, days = hours / 24
        if minutes < 1 { return "less than a minute ago" }
        if hours < 1 { return ago(minutes, "minute") }
        if days < 1 { return ago(hours, "hour") }
        if days < 60 { return ago(days, "day") }
        return ago(days / 30, "month")
    }
}

/// A Time Machine disk as `--print-status` lists it.
public struct ListedDisk: Equatable, Sendable {
    /// Labelled as in the "Back up to" pop-up.
    public var label: String
    /// Whether BackMeUp backs up to it: the only disk, or the chosen one of several.
    public var isBackupDisk: Bool

    public init(label: String, isBackupDisk: Bool) {
        self.label = label
        self.isBackupDisk = isBackupDisk
    }
}

extension Destination.Kind {
    init?(tmutilKind: String?) {
        switch tmutilKind {
        case "Network": self = .network
        case "Local": self = .local
        default: return nil
        }
    }
}
