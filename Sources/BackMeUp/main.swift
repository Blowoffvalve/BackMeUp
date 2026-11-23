import AppKit
import BackMeUpCore

MainActor.assumeIsolated {
    // `BackMeUp --print-status` prints the menu's status lines once and exits. It's a smoke test
    // of the real System adapter that needs no clicking. It never starts a backup.
    if CommandLine.arguments.contains("--print-status") {
        let system = RealSystem()
        let scheduler = Scheduler(system: system)
        Task {
            await scheduler.refreshStatus()
            print(scheduler.statusLine)
            print(scheduler.nextBackupLine)
            print(scheduler.networkLine)
            print("Back Up Now: " + (scheduler.backUpNowUnavailableReason.map { "unavailable (\($0))" } ?? "available"))
            for item in scheduler.checklist?.items ?? [] {
                print("Check \(item.check.rawValue) (\(item.state)): \(item.sentence)")
            }
            // Every Time Machine disk, even just one, and the one BackMeUp backs up to.
            for disk in scheduler.disks {
                print("Disk: \(disk.label)\(disk.isBackupDisk ? " (chosen)" : "")")
            }
            if !scheduler.disks.isEmpty, !scheduler.disks.contains(where: \.isBackupDisk) {
                print("No disk chosen")
            }
            // Troubleshoot's checks, read live. Never names the server or the network.
            await scheduler.troubleshoot()
            for check in scheduler.troubleshootReport?.checks ?? [] {
                print("Troubleshoot \(TroubleshootReport.mark(check.state)) \(check.name): \(check.sentence)")
            }
            // Also checks that Time Machine's preferences can be read and parsed.
            let preferences = await system.readPreferences()
            print(preferences == nil ? "Can't read Time Machine's preferences" : "Read Time Machine's preferences")
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
    EditMenu.install(on: app)
    app.run()
}
