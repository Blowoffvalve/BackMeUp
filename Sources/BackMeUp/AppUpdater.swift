import AppKit
import BackMeUpCore
import Sparkle

/// In-app updates through Sparkle. It checks the appcast on GitHub Releases once a day (the
/// `SUScheduledCheckInterval` in Info.plist) and asks before installing, unless the user has
/// turned on automatic installs in Settings. Sparkle checks each update's EdDSA signature
/// against `SUPublicEDKey` before installing it.
///
/// Builds whose Info.plist still has the placeholder key, and the bare binary, never start
/// Sparkle: it would only fail to verify anything.
@MainActor
final class AppUpdater: NSObject, SPUStandardUserDriverDelegate {
    private var controller: SPUStandardUpdaterController?

    override init() {
        super.init()
        let key = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String
        guard UpdateKey.isUsable(key) else { return }
        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: self
        )
    }

    /// Whether this build can update itself.
    var isAvailable: Bool { controller != nil }

    /// Checks now and shows the result, for "Check for Updates…".
    func checkForUpdates() {
        NSApp.activate(ignoringOtherApps: true)
        controller?.checkForUpdates(nil)
    }

    /// Whether updates download and install without asking. Off by default; Sparkle keeps the
    /// choice in BackMeUp's user defaults (`SUAutomaticallyUpdate`).
    var installsAutomatically: Bool {
        get { controller?.updater.automaticallyDownloadsUpdates ?? false }
        set { controller?.updater.automaticallyDownloadsUpdates = newValue }
    }

    // MARK: SPUStandardUserDriverDelegate

    // BackMeUp has no Dock icon, so a scheduled update's window could open behind other apps.
    // Bring BackMeUp forward whenever Sparkle shows one.

    nonisolated var supportsGentleScheduledUpdateReminders: Bool { true }

    nonisolated func standardUserDriverShouldHandleShowingScheduledUpdate(
        _ update: SUAppcastItem,
        andInImmediateFocus immediateFocus: Bool
    ) -> Bool {
        true
    }

    nonisolated func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool,
        forUpdate update: SUAppcastItem,
        state: SPUUserUpdateState
    ) {
        MainActor.assumeIsolated {
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}
