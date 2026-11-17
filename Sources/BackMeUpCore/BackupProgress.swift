import Foundation

/// How far a running backup has got, from `tmutil status -X`.
public struct BackupProgress: Equatable, Sendable {
    /// From 0 to 1.
    public var fraction: Double
    /// Time Machine's own estimate, in seconds, when it gives one.
    public var timeRemaining: TimeInterval?

    public init(fraction: Double, timeRemaining: TimeInterval? = nil) {
        self.fraction = fraction
        self.timeRemaining = timeRemaining
    }
}

extension BackupProgress {
    /// Parses the plist printed by `tmutil status -X`. nil unless a backup is running and its
    /// progress is known: early phases report `Percent` -1 and no `Progress` dictionary.
    ///
    /// The format is undocumented. In the Copying phase on macOS 27.2, `Progress` held `Percent`
    /// (a fraction) and sometimes `TimeRemaining` (seconds), with no top-level `Percent`.
    public init?(statusOutput: String) {
        guard let status = PlistDictionary(statusOutput), status.bool("Running") == true else { return nil }
        let details = status.dictionary("Progress")
        guard let fraction = details?.double("Percent") ?? status.double("Percent"),
              (0...1).contains(fraction)
        else { return nil }
        let timeRemaining = details?.double("TimeRemaining") ?? status.double("TimeRemaining")
        self.init(fraction: fraction, timeRemaining: timeRemaining.flatMap { $0 >= 0 ? $0 : nil })
    }
}
