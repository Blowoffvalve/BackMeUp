import AppKit
import BackMeUpCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var menuBar: MenuBarController?
    private var scheduler: Scheduler?
    private var updater: AppUpdater?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let scheduler = Scheduler(system: RealSystem())
        self.scheduler = scheduler
        let updater = AppUpdater()
        self.updater = updater
        menuBar = MenuBarController(scheduler: scheduler, updater: updater)
    }

    func applicationWillTerminate(_ notification: Notification) {
        scheduler?.prepareToQuit()
    }
}
