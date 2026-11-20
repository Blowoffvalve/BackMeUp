import Foundation

/// Whether Time Machine is backing up right now, from `tmutil status -X`.
public enum TimeMachineStatus: Equatable, Sendable {
    case idle
    case running
    /// `tmutil` couldn't be run, or its output wasn't understood. Never treated as idle or running.
    case unknown
}

extension TimeMachineStatus {
    /// Parses the plist printed by `tmutil status -X`. The format is undocumented, so anything
    /// unexpected becomes `.unknown`.
    public init(statusOutput: String) {
        guard let running = PlistDictionary(statusOutput)?.bool("Running") else {
            self = .unknown
            return
        }
        self = running ? .running : .idle
    }
}
