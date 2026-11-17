import AppKit
import BackMeUpCore

/// The menu bar icon and its menu. All decisions live in the Scheduler; this only draws them.
@MainActor
final class MenuBarController: NSObject, NSMenuDelegate {
    /// How often the menu refreshes while it's open, in seconds.
    private static let openMenuRefreshInterval: TimeInterval = 2

    private let scheduler: Scheduler
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let statusLineItem = NSMenuItem(title: "Checking Time Machine…", action: nil, keyEquivalent: "")
    private var backgroundTimer: Timer?
    private var openMenuTimer: Timer?
    private var isTicking = false

    init(scheduler: Scheduler) {
        self.scheduler = scheduler
        super.init()

        statusItem.button?.image = NSImage(
            systemSymbolName: "clock.arrow.circlepath",
            accessibilityDescription: "BackMeUp"
        )

        let menu = NSMenu()
        menu.autoenablesItems = false
        statusLineItem.isEnabled = false
        menu.addItem(statusLineItem)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit BackMeUp", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        menu.delegate = self
        statusItem.menu = menu

        backgroundTimer = makeTimer(every: Scheduler.tickInterval)
        refresh()
    }

    // MARK: NSMenuDelegate

    nonisolated func menuWillOpen(_ menu: NSMenu) {
        MainActor.assumeIsolated {
            refresh()
            openMenuTimer = makeTimer(every: Self.openMenuRefreshInterval)
        }
    }

    nonisolated func menuDidClose(_ menu: NSMenu) {
        MainActor.assumeIsolated {
            openMenuTimer?.invalidate()
            openMenuTimer = nil
        }
    }

    // MARK: Refreshing

    /// A timer that also fires while the menu is open (event-tracking run loop mode).
    private func makeTimer(every interval: TimeInterval) -> Timer {
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        RunLoop.main.add(timer, forMode: .common)
        return timer
    }

    private func refresh() {
        guard !isTicking else { return }
        isTicking = true
        Task {
            await scheduler.tick()
            statusLineItem.title = scheduler.statusLine
            isTicking = false
        }
    }
}
