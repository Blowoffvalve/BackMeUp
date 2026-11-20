import Foundation

/// Which Time Machine disk BackMeUp backs up to, and the rules for when that changes: the user
/// chooses, the chosen disk leaves Time Machine, a second disk is added, or a backup runs to the
/// only disk. Pure: the scheduler applies each change and saves it.
///
/// Saved in two places for compatibility with earlier versions: the choice in `BackupSettings`,
/// the rest in `SetupState`.
struct DiskChoiceState: Equatable {
    /// With two or more disks, the ID of the one BackMeUp backs up to. nil until the user chooses.
    private(set) var chosenID: String?
    /// Whether the chosen disk left Time Machine and the user hasn't chosen again. Backups wait,
    /// even with one disk left.
    private(set) var chosenDiskRemoved = false
    /// The disk BackMeUp last backed up to while it was the only disk, so it's kept when a second
    /// one is added. Not the user's choice.
    private(set) var lastUsedDiskID: String?
    /// Whether a second disk was added and the disk BackMeUp was using was kept as the choice,
    /// until the user chooses again.
    private(set) var newDiskAdded = false

    init(settings: BackupSettings, setupState: SetupState) {
        chosenID = settings.destinationID
        chosenDiskRemoved = setupState.chosenDiskRemoved == true
        lastUsedDiskID = setupState.lastUsedDiskID
        newDiskAdded = setupState.newDiskAdded == true
    }

    /// Writes the state into what's saved.
    func save(into settings: inout BackupSettings, _ setupState: inout SetupState) {
        settings.destinationID = chosenID
        setupState.chosenDiskRemoved = chosenDiskRemoved ? true : nil
        setupState.lastUsedDiskID = lastUsedDiskID
        setupState.newDiskAdded = newDiskAdded ? true : nil
    }

    /// The user chose a disk. From here on the choice decides, never the disk BackMeUp used before.
    /// Returns false when it was already chosen.
    mutating func choose(_ id: String?) -> Bool {
        guard id != chosenID else { return false }
        chosenID = id
        chosenDiskRemoved = false
        lastUsedDiskID = nil
        newDiskAdded = false
        return true
    }

    /// What a new reading of Time Machine's disks changed.
    enum ReadingChange: Equatable {
        case none
        /// The chosen disk left Time Machine and the choice was cleared. `disksLeft` is how many
        /// disks Time Machine still has.
        case chosenDiskRemoved(disksLeft: Int)
        /// Several disks, nothing chosen, and the disk BackMeUp last used among them: it was kept
        /// as the choice.
        case keptLastUsedDisk
    }

    /// Follows a new reading of Time Machine's disks. A reading that can't be understood
    /// changes nothing.
    mutating func update(for reading: DestinationInfo) -> ReadingChange {
        guard reading != .unknown else { return .none }
        let disks = reading.disks
        if let chosen = chosenID, !disks.contains(where: { $0.id == chosen }) {
            chosenID = nil
            chosenDiskRemoved = true
            // Never fall back to the disk BackMeUp used before the choice.
            lastUsedDiskID = nil
            newDiskAdded = false
            return .chosenDiskRemoved(disksLeft: disks.count)
        }
        // Versions before the last-used disk was saved left it nil, so after that update it asks.
        if chosenID == nil, !chosenDiskRemoved, let id = lastUsedDiskID,
           case let .several(disks) = reading, disks.contains(where: { $0.id == id }) {
            chosenID = id
            newDiskAdded = true
            // From here on the choice decides. Removing a disk chosen later asks, rather than
            // going back to this one.
            lastUsedDiskID = nil
            return .keptLastUsedDisk
        }
        return .none
    }

    /// The `--destination` to pass for a backup to this disk: only a disk the user chose is
    /// named, so with one disk the command is unchanged.
    func destinationArgument(for diskID: String?) -> String? {
        chosenID == diskID ? diskID : nil
    }

    /// A backup is starting to this disk. With nothing chosen it's the only disk, so it's
    /// remembered as the disk to keep when a second one is added.
    mutating func recordBackupStarting(to diskID: String?) {
        guard chosenID == nil, let diskID else { return }
        lastUsedDiskID = diskID
    }
}
