import AppKit
import BackMeUpCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var menuBar: MenuBarController?
    private var scheduler: Scheduler?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let scheduler = Scheduler(system: RealSystem())
        self.scheduler = scheduler
        menuBar = MenuBarController(scheduler: scheduler)
    }

    func applicationWillTerminate(_ notification: Notification) {
        scheduler?.prepareToQuit()
    }
}
