import CoreWLAN
import Foundation
import UserNotifications
import SystemConfiguration

/// The System port's adapter for the real Mac.
///
/// Time Machine's state comes from `/usr/bin/tmutil` run as a subprocess, because its
/// preferences can't be read directly without Full Disk Access.
@MainActor
public final class RealSystem: System {
    public init() {}

    /// The power assertion held while a backup runs on AC power. See `setIdleSleepPrevented`.
    var sleepAssertion: IOPMAssertionID?

    public var now: Date { Date() }

    public func readTimeMachineStatus() async -> TimeMachineStatus {
        guard let result = await Command.run("/usr/bin/tmutil", ["status", "-X"]), result.exitCode == 0 else {
            return .unknown
        }
        return TimeMachineStatus(statusOutput: result.stdout)
    }

    public func readBackupProgress() async -> BackupProgress? {
        guard let result = await Command.run("/usr/bin/tmutil", ["status", "-X"]), result.exitCode == 0 else {
            return nil
        }
        return BackupProgress(statusOutput: result.stdout)
    }

    public func readDestinationInfo() async -> DestinationInfo {
        guard let result = await Command.run("/usr/bin/tmutil", ["destinationinfo", "-X"]) else {
            return .unknown
        }
        // tmutil may report "No destinations configured" on standard error, perhaps with a
        // non-zero exit, so the parser sees the output whatever the exit code.
        let output = result.stdout.isEmpty ? result.stderr : result.stdout
        return DestinationInfo(destinationInfoOutput: output)
    }

    public func readPreferences() async -> TimeMachinePreferences? {
        // `defaults` can read this file without Full Disk Access; reading the plist directly can't.
        guard let result = await Command.run("/usr/bin/defaults", ["read", "/Library/Preferences/com.apple.TimeMachine"]),
              result.exitCode == 0
        else { return nil }
        return TimeMachinePreferences(defaultsOutput: result.stdout)
    }

    public func startBackup() async -> Int32? {
        await Command.run("/usr/bin/tmutil", ["startbackup", "--auto", "--block"])?.exitCode
    }

    // MARK: Notifications

    private let notificationDelegate = NotificationDelegate()

    /// Posts a Mac notification. Asks for permission the first time; if it's refused, the
    /// notification is dropped (the menu bar icon still shows the problem).
    public func showNotification(_ alert: Alert) {
        // UNUserNotificationCenter needs an app bundle; outside one (e.g. `swift run`) it traps.
        guard Bundle.main.bundleIdentifier != nil else { return }
        let center = UNUserNotificationCenter.current()
        center.delegate = notificationDelegate
        Task {
            guard (try? await center.requestAuthorization(options: [.alert, .sound])) == true else { return }
            let content = UNMutableNotificationContent()
            content.title = alert.title
            content.body = alert.body
            content.sound = .default
            try? await center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        }
    }

    // MARK: Network identity

    public func readNetwork() async -> NetworkReading {
        // Everything here only reads state macOS already has; nothing is sent on the network.
        guard let routes = await Command.run("/usr/sbin/netstat", ["-rn", "-f", "inet"]), routes.exitCode == 0,
              let route = RoutingTable(netstatOutput: routes.stdout).physicalDefaultRoute
        else { return .none }
        // macOS 15+ hides hardware addresses in the ARP table from apps without Local Network
        // permission (seen on macOS 27.2: `arp -an` run by an app prints nothing), so
        // SystemConfiguration comes first and the ARP table is the fallback.
        if let address = NetworkServiceState.routerHardwareAddress(services: Self.networkServices(), route: route) {
            return .router(address: address, wifiName: wifiName(on: route.interface))
        }
        guard let arp = await Command.run("/usr/sbin/arp", ["-an"]), arp.exitCode == 0,
              let address = ARPTable(arpOutput: arp.stdout).hardwareAddress(of: route.gateway, on: route.interface)
        else { return .routerAddressUnknown }
        return .router(address: address, wifiName: wifiName(on: route.interface))
    }

    /// Every `State:/Network/Service/<id>/IPv4` dictionary in SystemConfiguration's dynamic store.
    private static func networkServices() -> [[String: Any]] {
        guard let store = SCDynamicStoreCreate(nil, "BackMeUp" as CFString, nil, nil),
              let keys = SCDynamicStoreCopyKeyList(store, "State:/Network/Service/.*/IPv4" as CFString) as? [String]
        else { return [] }
        return keys.compactMap { SCDynamicStoreCopyValue(store, $0 as CFString) as? [String: Any] }
    }

    /// The Wi-Fi name, if the default route goes over Wi-Fi. CoreWLAN returns nil without
    /// Location permission; it's only ever used as a label.
    private func wifiName(on interface: String) -> String? {
        guard let wifi = CWWiFiClient.shared().interface(), wifi.interfaceName == interface,
              let name = wifi.ssid(), !name.isEmpty
        else { return nil }
        return name
    }

    // MARK: Settings storage

    private enum Key {
        static let history = "backupHistory"
        static let settings = "backupSettings"
        static let networks = "chosenNetworks"
    }

    public func loadNetworks() -> NetworkSettings? { load(Key.networks) }
    public func saveNetworks(_ networks: NetworkSettings) { save(networks, Key.networks) }

    public func loadHistory() -> BackupHistory? { load(Key.history) }
    public func saveHistory(_ history: BackupHistory) { save(history, Key.history) }
    public func loadSettings() -> BackupSettings? { load(Key.settings) }
    public func saveSettings(_ settings: BackupSettings) { save(settings, Key.settings) }

    private func load<Value: Decodable>(_ key: String) -> Value? {
        UserDefaults.standard.data(forKey: key).flatMap { try? JSONDecoder().decode(Value.self, from: $0) }
    }

    private func save<Value: Encodable>(_ value: Value, _ key: String) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}

/// Runs a command off the main thread and collects its output.
enum Command {
    struct Result: Sendable {
        let exitCode: Int32
        let stdout: String
        let stderr: String
    }

    /// Returns nil if the command couldn't be started.
    static func run(_ path: String, _ arguments: [String]) async -> Result? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: runBlocking(path, arguments))
            }
        }
    }

    private static func runBlocking(_ path: String, _ arguments: [String]) -> Result? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        process.standardInput = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        // Read stderr on another thread so a full pipe can't block the process.
        let errorData = ErrorCollector(handle: stderr.fileHandleForReading)
        let outputData = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return Result(
            exitCode: process.terminationStatus,
            stdout: String(decoding: outputData, as: UTF8.self),
            stderr: String(decoding: errorData.wait(), as: UTF8.self)
        )
    }
}

/// Shows BackMeUp's notifications even while its menu is open, when macOS counts the app as frontmost.
private final class NotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list, .sound])
    }
}

/// Reads a pipe to its end on a background queue.
private final class ErrorCollector: @unchecked Sendable {
    private var data = Data()
    private let done = DispatchSemaphore(value: 0)

    init(handle: FileHandle) {
        DispatchQueue.global(qos: .utility).async {
            self.data = handle.readDataToEndOfFile()
            self.done.signal()
        }
    }

    func wait() -> Data {
        done.wait()
        return data
    }
}
