import Foundation

/// Whether Time Machine last saw the backup disk encrypted (`LastKnownEncryptionState`).
public enum EncryptionState: Equatable, Sendable {
    case encrypted
    case notEncrypted
    /// Missing or a value we don't know.
    case unknown
}

/// Time Machine's preferences, from `defaults read /Library/Preferences/com.apple.TimeMachine`.
///
/// None of these keys are documented. Anything missing or unexpected is nil or `.unknown`,
/// never a guess.
public struct TimeMachinePreferences: Equatable, Sendable {
    public struct DestinationEntry: Equatable, Sendable {
        public var id: String?
        public var encryption: EncryptionState
        /// `RESULT`: Time Machine's result code for the last backup to this disk. 0 means success.
        public var result: Int?

        public init(id: String?, encryption: EncryptionState = .unknown, result: Int?) {
            self.id = id
            self.encryption = encryption
            self.result = result
        }
    }

    /// `AutoBackup`: whether Time Machine's own automatic backups are on.
    public var autoBackup: Bool?
    public var destinations: [DestinationEntry]

    public init(autoBackup: Bool?, destinations: [DestinationEntry]) {
        self.autoBackup = autoBackup
        self.destinations = destinations
    }

    /// The destination with this Time Machine ID (`DestinationID`, the same as `ID` in
    /// `tmutil destinationinfo -X`). With no ID, the only destination, if there's just one.
    public func destination(id: String?) -> DestinationEntry? {
        guard let id else { return destinations.count == 1 ? destinations[0] : nil }
        return destinations.first { $0.id == id }
    }
}

extension TimeMachinePreferences {
    /// Parses the old-style plist text that `defaults read` prints. Returns nil if it can't be read.
    public init?(defaultsOutput: String) {
        // `defaults read` prints data values as `{length = 246, bytes = 0x0000 ... ffff }`, which
        // isn't valid plist syntax. None of them matter here, so they become empty strings.
        let cleaned = defaultsOutput.replacingOccurrences(
            of: #"\{length = \d+, bytes = 0x[0-9a-fA-F .]*\}"#,
            with: "\"\"",
            options: .regularExpression
        )
        guard let plist = PlistDictionary(cleaned) else { return nil }
        autoBackup = plist.flag("AutoBackup")
        destinations = (plist.array("Destinations") ?? []).map { entry in
            DestinationEntry(
                id: entry.string("DestinationID"),
                encryption: EncryptionState(preferenceValue: entry.string("LastKnownEncryptionState")),
                result: entry.integer("RESULT")
            )
        }
    }
}

extension EncryptionState {
    init(preferenceValue: String?) {
        switch preferenceValue {
        case "Encrypted": self = .encrypted
        case "NotEncrypted": self = .notEncrypted
        default: self = .unknown
        }
    }
}

extension PlistDictionary {
    /// An integer from a number, or from the text of one, as old-style plists store numbers.
    func integer(_ key: String) -> Int? {
        switch values[key] {
        case let value as NSNumber: value.intValue
        case let value as String: Int(value)
        default: nil
        }
    }

    /// A 0/1 flag stored as a number, boolean or text.
    func flag(_ key: String) -> Bool? {
        switch integer(key) {
        case 0: false
        case 1: true
        default: bool(key)
        }
    }
}
