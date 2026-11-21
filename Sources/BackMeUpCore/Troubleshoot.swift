import Foundation

/// One of Troubleshoot's checks, as the window shows it.
public struct TroubleshootCheck: Equatable, Sendable {
    public enum Kind: Equatable, Sendable, CaseIterable {
        /// The Mac is on a network where backups are allowed.
        case network
        /// The backup server answers on its file-sharing port.
        case server
        /// Time Machine isn't stuck.
        case timeMachine
    }

    public enum State: Equatable, Sendable {
        case passed
        case failed
        /// Doesn't apply to this backup disk, for example the server check for a USB disk.
        case notNeeded
        /// BackMeUp couldn't check.
        case unknown
    }

    public var kind: Kind
    public var state: State
    /// What was found, as a sentence: "The backup server is answering."
    public var sentence: String
    /// What to do about it, as numbered steps. Empty unless the check failed.
    public var steps: [String]

    public init(kind: Kind, state: State, sentence: String, steps: [String] = []) {
        self.kind = kind
        self.state = state
        self.sentence = sentence
        self.steps = steps
    }

    /// The check's name: "Network", "Backup server", "Time Machine".
    public var name: String {
        switch kind {
        case .network: "Network"
        case .server: "Backup server"
        case .timeMachine: "Time Machine"
        }
    }
}

/// What Troubleshoot reads before it decides.
struct TroubleshootInputs {
    /// The backup disk, or nil if Time Machine's disks couldn't be read or none is chosen.
    var disk: Destination?
    var network: NetworkReading?
    var networks: NetworkSettings
    /// Whether the server answered, or nil if it wasn't tried (no network disk, or no address).
    var serverAnswers: Bool?
    var stuck: StuckRecord?
}

/// Troubleshoot's result: every check, in order, and the fix for the first one that failed.
public struct TroubleshootReport: Equatable, Sendable {
    public var checks: [TroubleshootCheck]
    /// When the checks were run.
    public var date: Date

    public init(checks: [TroubleshootCheck], date: Date) {
        self.checks = checks
        self.date = date
    }

    /// The first failed check: its fix goes at the top of the window.
    public var firstFailure: TroubleshootCheck? { checks.first { $0.state == .failed } }

    init(_ inputs: TroubleshootInputs, date: Date) {
        self.init(checks: [Self.network(inputs), Self.server(inputs), Self.timeMachine(inputs)], date: date)
    }

    // MARK: The checks

    private static func network(_ inputs: TroubleshootInputs) -> TroubleshootCheck {
        if inputs.disk?.kind == .local {
            return TroubleshootCheck(kind: .network, state: .notNeeded, sentence: "Your backup disk plugs into your Mac, so the network doesn't matter.")
        }
        guard let network = inputs.network else {
            return TroubleshootCheck(kind: .network, state: .unknown, sentence: "BackMeUp couldn't read which network your Mac is on.")
        }
        switch inputs.networks.skipReason(on: network) {
        case nil:
            return TroubleshootCheck(kind: .network, state: .passed, sentence: "Your Mac is on a network where backups are allowed.")
        case .networkUnidentified?:
            return TroubleshootCheck(
                kind: .network,
                state: .failed,
                sentence: "BackMeUp can't identify the network your Mac is on.",
                steps: ["Check your Mac is connected to Wi-Fi or a network cable.", "Then choose Back Up Now in the BackMeUp menu."]
            )
        default:
            return TroubleshootCheck(
                kind: .network,
                state: .failed,
                sentence: "Your Mac isn't on a network you chose for backups.",
                steps: [
                    "Join the network your backup disk is on, usually your home Wi-Fi.",
                    "If you're already on it, choose \u{201C}Allow backups on this network\u{201D} in the BackMeUp menu.",
                ]
            )
        }
    }

    private static func server(_ inputs: TroubleshootInputs) -> TroubleshootCheck {
        if inputs.disk?.kind == .local {
            return TroubleshootCheck(kind: .server, state: .notNeeded, sentence: "Your backup disk plugs into your Mac, so there's no server to check.")
        }
        switch inputs.serverAnswers {
        case true?:
            return TroubleshootCheck(kind: .server, state: .passed, sentence: "The backup server is answering.")
        case false?:
            return TroubleshootCheck(
                kind: .server,
                state: .failed,
                sentence: "The backup server isn't answering.",
                steps: [
                    "Check the backup server is switched on.",
                    "If you're away from home, connect to the VPN you use to reach it.",
                    "Then choose Back Up Now in the BackMeUp menu.",
                ]
            )
        case nil:
            return TroubleshootCheck(kind: .server, state: .unknown, sentence: "BackMeUp couldn't find the backup server's address to check it.")
        }
    }

    private static func timeMachine(_ inputs: TroubleshootInputs) -> TroubleshootCheck {
        guard let stuck = inputs.stuck else {
            return TroubleshootCheck(kind: .timeMachine, state: .passed, sentence: "Time Machine isn't stuck.")
        }
        if stuck.restartDidNotHelp {
            return TroubleshootCheck(
                kind: .timeMachine,
                state: .failed,
                sentence: "Time Machine is still stuck after a restart.",
                steps: [
                    "Choose Copy Details below and send them to whoever set up your backups.",
                    "Choose Show Log if they ask for BackMeUp's log.",
                ]
            )
        }
        return TroubleshootCheck(
            kind: .timeMachine,
            state: .failed,
            sentence: "Time Machine is stuck. Your backup disk is fine, but Time Machine has lost track of it.",
            steps: Self.restartSteps
        )
    }

    /// How to restart, for someone who may never have done it on purpose.
    static let restartSteps = [
        "Save your work and close your documents.",
        "Choose Apple menu \u{F8FF} > Restart, then click Restart.",
        "Log in as usual. About 5 minutes later, BackMeUp starts a backup and tells you whether it worked.",
    ]

    // MARK: Copy Details

    /// A plain-text summary to send to whoever set up the backups. Never names the server, the
    /// network or any address.
    func details(history: BackupHistory, appVersion: String?, dates: RelativeDate) -> String {
        var lines = ["BackMeUp \(appVersion ?? "(unknown version)") troubleshooting, \(dates.describe(date))"]
        lines.append("Last successful backup: \(history.lastSuccess.map(dates.describe) ?? "never")")
        if let failure = history.sinceLastSuccess.lastFailure {
            lines.append("Latest problem: \(failure.description) (\(history.sinceLastSuccess.failures) failed since the last success)")
        }
        if let stuck = history.stuck {
            lines.append("Time Machine stuck since: \(dates.describe(stuck.since))\(stuck.restartDidNotHelp ? "; a restart didn't help" : "")")
        }
        lines.append("Checks:")
        for check in checks {
            lines.append("\(Self.mark(check.state)) \(check.name): \(check.sentence)")
        }
        return lines.joined(separator: "\n")
    }

    /// ✓, ✗, – or ?.
    public static func mark(_ state: TroubleshootCheck.State) -> String {
        switch state {
        case .passed: "✓"
        case .failed: "✗"
        case .notNeeded: "–"
        case .unknown: "?"
        }
    }
}
