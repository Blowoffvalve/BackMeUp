import AppKit
import CoreLocation

/// Asks for Location permission, which macOS requires before it reveals the Wi-Fi name. BackMeUp
/// only uses the name as a label for chosen networks; backups never depend on it.
@MainActor
final class LocationPermission: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private var waiting: [CheckedContinuation<Void, Never>] = []

    override init() {
        super.init()
        manager.delegate = self
    }

    /// Asks once, if the user hasn't answered yet, and waits for the answer (at most a minute).
    func requestIfNeeded() async {
        guard manager.authorizationStatus == .notDetermined else { return }
        manager.requestWhenInUseAuthorization()
        Task {
            try? await Task.sleep(for: .seconds(60))
            resumeAll()
        }
        await withCheckedContinuation { waiting.append($0) }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        MainActor.assumeIsolated {
            if status != .notDetermined { resumeAll() }
        }
    }

    private func resumeAll() {
        let continuations = waiting
        waiting = []
        continuations.forEach { $0.resume() }
    }
}
