import Foundation

/// Decides how a backup BackMeUp started turned out, from what Time Machine recorded before and
/// after it. Anything BackMeUp can't confirm counts as "can't tell", never as a success.
struct BackupVerdict {
    /// What Time Machine had recorded for the disk just before the backup started.
    enum Before: Equatable {
        /// Time Machine's preferences couldn't be read.
        case unreadable
        /// The newest backup on the disk then, or nil if there was none.
        case latestSnapshot(Date?)

        init(_ preferences: TimeMachinePreferences?, destinationID: String?) {
            guard let preferences else {
                self = .unreadable
                return
            }
            self = .latestSnapshot(preferences.destination(id: destinationID)?.latestSnapshot)
        }
    }

    var before: Before
    /// `tmutil startbackup`'s exit code, or nil if it couldn't be run.
    var exitCode: Int32?
    /// The disk's entry in Time Machine's preferences once the command returned.
    var after: TimeMachinePreferences.DestinationEntry?
    /// Whether BackMeUp has recorded a success yet. Before the first, an interrupted backup is
    /// paused, not failed.
    var isFirstBackup: Bool

    var outcome: BackupAttempt.Outcome {
        let outcome = completedOutcome
        return isFirstBackup ? firstBackupOutcome(outcome) : outcome
    }

    /// `tmutil` has been seen exiting 0 for a cancelled backup, so only `RESULT` 0 is a success,
    /// and `RESULT` says nothing about which backup it's from, so a new snapshot must show that
    /// this backup finished.
    private var completedOutcome: BackupAttempt.Outcome {
        guard let exitCode else { return .failed(.couldNotStart) }
        guard exitCode == 0 else { return .failed(.exitCode(exitCode)) }
        switch after?.result {
        case nil: return .failed(.resultUnreadable)
        case let code? where code != 0: return .failed(.result(code))
        default: return hasNewSnapshot ? .succeeded : .failed(.notConfirmed)
        }
    }

    /// Whether the disk's newest backup is newer than it was before this one started.
    private var hasNewSnapshot: Bool {
        guard case let .latestSnapshot(earlier) = before, let latest = after?.latestSnapshot else { return false }
        return earlier.map { latest > $0 } ?? true
    }

    /// Before the first success, a backup that stopped without Time Machine reporting an error
    /// result is paused: the long first backup is often cut short by closing the lid, and resumes
    /// at the next try.
    private func firstBackupOutcome(_ outcome: BackupAttempt.Outcome) -> BackupAttempt.Outcome {
        switch outcome {
        case .failed(.exitCode):
            if let result = after?.result, result != 0 { return .failed(.result(result)) }
            return .paused
        case .failed(.resultUnreadable), .failed(.notConfirmed):
            return .paused
        default:
            return outcome
        }
    }
}
