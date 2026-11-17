import Foundation

/// The core decision engine. For now it only reads Time Machine's state and describes it for the
/// menu; later tickets make it decide when to start backups and which alerts to send.
@MainActor
public final class Scheduler {
    /// How often the app ticks the scheduler in the background, in seconds.
    public static let tickInterval: TimeInterval = 60

    private let system: any System

    public private(set) var statusLine = ""

    public init(system: any System) {
        self.system = system
    }

    /// Called by the app's timer, and by the test harness at each step of simulated time.
    public func tick() async {
        let status = await system.readTimeMachineStatus()
        let destination = await system.readDestinationInfo()
        statusLine = Self.describe(status: status, destination: destination)
    }

    private static func describe(status: TimeMachineStatus, destination: DestinationInfo) -> String {
        let disk: Destination
        switch destination {
        case let .configured(configured): disk = configured
        case .notSetUp: return "No Time Machine disk set up"
        case .unknown: return "Can't read Time Machine's settings"
        }
        let kind = switch disk.kind {
        case .network: "network disk"
        case .local: "local disk"
        }
        let activity = switch status {
        case .idle: "Time Machine idle"
        case .running: "Backing up now"
        case .unknown: "Can't tell what Time Machine is doing"
        }
        return "\(activity) · \(kind)"
    }
}
