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

    public init(kind: Kind, id: String?) {
        self.kind = kind
        self.id = id
    }
}

/// The Time Machine destination, from `tmutil destinationinfo -X`.
public enum DestinationInfo: Equatable, Sendable {
    case configured(Destination)
    /// Time Machine has no backup disk.
    case notSetUp
    /// `tmutil` couldn't be run, or its output wasn't understood.
    case unknown
}

extension DestinationInfo {
    /// Parses the plist printed by `tmutil destinationinfo -X`. BackMeUp uses the first
    /// destination only (see the spec's Out of Scope).
    public init(destinationInfoOutput: String) {
        // Without -X's plist, tmutil prints this sentence when no disk is set up.
        if destinationInfoOutput.contains("No destinations configured") {
            self = .notSetUp
            return
        }
        guard let destinations = PlistDictionary(destinationInfoOutput)?.array("Destinations") else {
            self = .unknown
            return
        }
        guard let first = destinations.first else {
            self = .notSetUp
            return
        }
        guard let kind = Destination.Kind(tmutilKind: first.string("Kind"))
        else {
            self = .unknown
            return
        }
        self = .configured(Destination(kind: kind, id: first.string("ID")))
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
