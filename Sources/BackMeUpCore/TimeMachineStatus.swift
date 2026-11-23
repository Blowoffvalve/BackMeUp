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

    /// Whether Time Machine is deleting old backups to make room (`ThinningPreBackup` or
    /// `ThinningPostBackup`). It shows "Cleaning up…" then. A backup can't be started meanwhile,
    /// and on a network disk it can take over an hour.
    public var isCleaningUp: Bool {
        guard case let .running(_, phase?) = self else { return false }
        return phase.hasPrefix("Thinning")
    }
}
