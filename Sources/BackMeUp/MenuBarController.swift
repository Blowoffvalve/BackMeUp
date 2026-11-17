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
    private let nextBackupItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let backUpNowItem = NSMenuItem(title: "Back Up Now", action: #selector(backUpNow), keyEquivalent: "")
    private lazy var settingsWindow = SettingsWindowController(scheduler: scheduler)
    private var backgroundTimer: Timer?
    private var openMenuTimer: Timer?
    private var isTicking = false

    init(scheduler: Scheduler) {
        self.scheduler = scheduler
        super.init()

        drawIcon()

        let menu = NSMenu()
        menu.autoenablesItems = false
        statusLineItem.isEnabled = false
        nextBackupItem.isEnabled = false
        backUpNowItem.target = self
        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(statusLineItem)
        menu.addItem(nextBackupItem)
        menu.addItem(.separator())
        menu.addItem(backUpNowItem)
        menu.addItem(settingsItem)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit BackMeUp", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        menu.delegate = self
        statusItem.menu = menu

        scheduler.onChange = { [weak self] in self?.draw() }
        backgroundTimer = makeTimer(every: Scheduler.tickInterval) { [weak self] in self?.tick() }
        tick()
    }

    // MARK: NSMenuDelegate

    nonisolated func menuWillOpen(_ menu: NSMenu) {
        MainActor.assumeIsolated {
            refreshStatus()
            openMenuTimer = makeTimer(every: Self.openMenuRefreshInterval) { [weak self] in self?.refreshStatus() }
        }
    }

    nonisolated func menuDidClose(_ menu: NSMenu) {
        MainActor.assumeIsolated {
            openMenuTimer?.invalidate()
            openMenuTimer = nil
        }
    }

    // MARK: Actions

    @objc private func backUpNow() {
        scheduler.backUpNow()
    }

    @objc private func openSettings() {
        settingsWindow.show()
    }

    // MARK: Refreshing

    /// A timer that also fires while the menu is open (event-tracking run loop mode).
    private func makeTimer(every interval: TimeInterval, _ action: @escaping @MainActor () -> Void) -> Timer {
        let timer = Timer(timeInterval: interval, repeats: true) { _ in
            MainActor.assumeIsolated { action() }
        }
        RunLoop.main.add(timer, forMode: .common)
        return timer
    }

    /// Lets the scheduler start a backup if one is due.
    private func tick() {
        run { await $0.tick() }
    }

    /// Only re-reads Time Machine's state for the open menu.
    private func refreshStatus() {
        run { await $0.refreshStatus() }
    }

    private func run(_ work: @escaping @MainActor (Scheduler) async -> Void) {
        guard !isTicking else { return }
        isTicking = true
        Task {
            await work(scheduler)
            isTicking = false
        }
    }

    private func draw() {
        statusLineItem.title = scheduler.statusLine
        nextBackupItem.title = scheduler.nextBackupLine
        nextBackupItem.isHidden = scheduler.nextBackupLine.isEmpty
        backUpNowItem.isEnabled = !scheduler.isBackingUp
        drawIcon()
    }

    /// A clock normally; a clock with an exclamation mark while backups have a problem.
    private func drawIcon() {
        let problem = scheduler.hasProblem
        let image = NSImage(
            systemSymbolName: problem ? "clock.badge.exclamationmark" : "clock.arrow.circlepath",
            accessibilityDescription: problem ? "BackMeUp: backups need attention" : "BackMeUp"
        )
        image?.isTemplate = true
        statusItem.button?.image = image
    }
}
