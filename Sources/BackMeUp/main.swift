import AppKit
import BackMeUpCore

MainActor.assumeIsolated {
    // `BackMeUp --print-status` prints the menu's status line once and exits. It's a smoke test
    // of the real System adapter that needs no clicking.
    if CommandLine.arguments.contains("--print-status") {
        let scheduler = Scheduler(system: RealSystem())
        Task {
            await scheduler.tick()
            print(scheduler.statusLine)
            exit(0)
        }
        RunLoop.main.run()
    }

    // A menu bar-only app: no Dock icon and no main window. The bundle's Info.plist also sets
    // LSUIElement; this covers running the bare binary.
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
