import Foundation

/// Whether Time Machine is backing up right now, from `tmutil status -X`.
public enum TimeMachineStatus: Equatable, Sendable {
    case idle
    /// Backing up to the disk with this ID (`DestinationID`), or to a disk it doesn't name, in
    /// the phase Time Machine names (`BackupPhase`), such as `Copying` or `ThinningPostBackup`.
    case running(destinationID: String?, phase: String? = nil)
    /// `tmutil` couldn't be run, or its output wasn't understood. Never treated as idle or running.
    case unknown
}

extension TimeMachineStatus {
    /// Parses the plist printed by `tmutil status -X`. The format is undocumented, so anything
    /// unexpected becomes `.unknown`.
    public init(statusOutput: String) {
        guard let status = PlistDictionary(statusOutput), let running = status.bool("Running") else {
            self = .unknown
            return
        }
        self = running
            ? .running(destinationID: status.string("DestinationID"), phase: status.string("BackupPhase"))
            : .idle
    }

    /// The stage name Time Machine gives while running (`BackupPhase`), or nil.
    public var phase: String? {
        guard case let .running(_, phase) = self else { return nil }
        return phase
    }

    /// The group the running backup's stage falls into. `.unknown` when nothing runs.
    public var stage: BackupStage { BackupStage(phase: phase) }
}

/// The stages of a Time Machine backup, grouped as the menu words them. Apple doesn't document
/// `BackupPhase`; names are matched by how they start, so variants such as
/// `MountingBackupVolForHealthCheck` fall into the same group.
public enum BackupStage: Equatable, Sendable {
    /// Before copying starts. Time Machine's menu says "Preparing to back up".
    case gettingReady
    /// Copying files (`Copying`). Only then does Time Machine give a percent.
    case copying
    /// Deleting old backups (`Thinning…`). A backup can't be started meanwhile, and on a network
    /// disk it can take over an hour.
    case cleaningUp
    /// Any other name, or none: the menu claims nothing about it.
    case unknown

    /// Every name these match comes before copying, so "getting ready" never overstates.
    private static let gettingReadyPrefixes = ["Starting", "Mounting", "HealthCheck", "Calculating", "Finding", "Preparing"]

    public init(phase: String?) {
        guard let phase else {
            self = .unknown
            return
        }
        if phase == "Copying" {
            self = .copying
        } else if phase.hasPrefix("Thinning") {
            self = .cleaningUp
        } else if Self.gettingReadyPrefixes.contains(where: phase.hasPrefix) {
            self = .gettingReady
        } else {
            self = .unknown
        }
    }
}
