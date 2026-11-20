import Foundation

/// How far a running backup has got, from `tmutil status -X`.
public struct BackupProgress: Equatable, Sendable {
    /// From 0 to 1, as Time Machine's own menu shows it.
    public var fraction: Double
    /// Time Machine's own estimate, in seconds, when it gives one.
    public var timeRemaining: TimeInterval?

    public init(fraction: Double, timeRemaining: TimeInterval? = nil) {
        self.fraction = fraction
        self.timeRemaining = timeRemaining
    }

    /// "20.8%", with one decimal as Time Machine's menu shows it.
    public var percentText: String {
        String(format: "%.1f%%", locale: Locale(identifier: "en_US_POSIX"), fraction * 100)
    }
}

extension BackupProgress {
    /// Parses the plist printed by `tmutil status -X`. nil unless a backup is running and its
    /// progress is known: early phases report `Percent` -1 and no `Progress` dictionary.
    ///
    /// `fraction` matches Time Machine's menu, not the raw `Percent`: the phase fills only the last
    /// `FractionOfProgressBar` of its bar. Seen on macOS 27.2: `Percent` 0.1197 with
    /// `FractionOfProgressBar` 0.9 showed as "20.8% done" (10% + 0.9 x 11.97%).
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
        self.init(fraction: Self.progressBarFraction(percent: fraction, share: status.double("FractionOfProgressBar")), timeRemaining: timeRemaining.flatMap { $0 >= 0 ? $0 : nil })
    }

    /// Where `percent` of a phase that fills the last `share` of the bar puts the bar. Without a
    /// usable share, `percent` as it is.
    static func progressBarFraction(percent: Double, share: Double?) -> Double {
        guard let share, share > 0, share <= 1 else { return percent }
        return (1 - share) + percent * share
    }
}
