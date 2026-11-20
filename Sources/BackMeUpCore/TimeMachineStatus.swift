import Foundation

/// Whether Time Machine is backing up right now, from `tmutil status -X`.
public enum TimeMachineStatus: Equatable, Sendable {
    case idle
    /// Backing up to the disk with this ID (`DestinationID`), or to a disk it doesn't name.
    case running(destinationID: String?)
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
        self = running ? .running(destinationID: status.string("DestinationID")) : .idle
    }
}
