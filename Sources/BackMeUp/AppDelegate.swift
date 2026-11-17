import AppKit
import BackMeUpCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var menuBar: MenuBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        menuBar = MenuBarController(scheduler: Scheduler(system: RealSystem()))
    }
}
