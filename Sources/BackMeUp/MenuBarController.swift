import AppKit
import BackMeUpCore

/// The menu bar icon and its menu. All decisions live in the Scheduler; this only draws them.
@MainActor
final class MenuBarController: NSObject, NSMenuDelegate {
    /// How often the menu refreshes while it's open, in seconds.
    private static let openMenuRefreshInterval: TimeInterval = 2

    private let scheduler: Scheduler
    private let updater: AppUpdater
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let statusLineItem = NSMenuItem(title: "Checking Time Machine…", action: nil, keyEquivalent: "")
    private let nextBackupItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    /// The strip of dots: which recent days were backed up.
    private let stripItem = NSMenuItem()
    private let stripView = BackupStripView()
    private let backUpNowItem = NSMenuItem(title: "Back Up Now", action: #selector(backUpNow), keyEquivalent: "")
    private let networkItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let allowNetworkItem = NSMenuItem(
        title: "Allow backups on this network",
        action: #selector(allowCurrentNetwork),
        keyEquivalent: ""
    )
    /// "Troubleshoot…", or "How to Fix This…" when Troubleshoot found a problem.
    private let troubleshootItem = NSMenuItem(title: "Troubleshoot…", action: #selector(openTroubleshoot), keyEquivalent: "")
    private lazy var troubleshootWindow = TroubleshootWindowController(scheduler: scheduler)
    private lazy var settingsWindow = SettingsWindowController(scheduler: scheduler, updater: updater)
    private lazy var checklistWindow = ChecklistWindowController(
        scheduler: scheduler,
        openBackMeUpSettings: { [weak self] in self?.openSettings() },
        refresh: { [weak self] in self?.refreshStatus() }
    )
    private var backgroundTimer: Timer?
    private var openMenuTimer: Timer?
    private var isTicking = false

    init(scheduler: Scheduler, updater: AppUpdater) {
        self.scheduler = scheduler
        self.updater = updater
        super.init()

        drawIcon()

        let menu = NSMenu()
        menu.autoenablesItems = false
        statusLineItem.isEnabled = false
        nextBackupItem.isEnabled = false
        backUpNowItem.target = self
        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        let checklistItem = NSMenuItem(title: "Setup Checklist…", action: #selector(openChecklist), keyEquivalent: "")
        checklistItem.target = self
        stripItem.view = stripView
        stripItem.isHidden = true
        menu.addItem(statusLineItem)
        menu.addItem(stripItem)
        menu.addItem(nextBackupItem)
        menu.addItem(.separator())
        networkItem.isEnabled = false
        allowNetworkItem.target = self
        menu.addItem(networkItem)
        menu.addItem(allowNetworkItem)
        menu.addItem(.separator())
        menu.addItem(backUpNowItem)
        troubleshootItem.target = self
        menu.addItem(troubleshootItem)
        menu.addItem(checklistItem)
        menu.addItem(settingsItem)
        if updater.isAvailable {
            let updateItem = NSMenuItem(title: "Check for Updates…", action: #selector(checkForUpdates), keyEquivalent: "")
            updateItem.target = self
            menu.addItem(updateItem)
        }
        let showLogItem = NSMenuItem(title: "Show Log", action: #selector(showLog), keyEquivalent: "")
        showLogItem.target = self
        menu.addItem(showLogItem)
        menu.addItem(.separator())
        let uninstallItem = NSMenuItem(title: "Uninstall…", action: #selector(uninstall), keyEquivalent: "")
        uninstallItem.target = self
        menu.addItem(uninstallItem)
        menu.addItem(NSMenuItem(title: "Quit BackMeUp", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        menu.delegate = self
        statusItem.menu = menu

        scheduler.onChange = { [weak self] in self?.draw() }
        scheduler.onShowChecklist = { [weak self] in self?.openChecklist() }
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
            stripView.clearHover()
        }
    }

    // MARK: Actions

    @objc private func backUpNow() {
        scheduler.backUpNow()
    }

    @objc private func allowCurrentNetwork() {
        Task { await AllowNetworkFlow.run(scheduler: scheduler) }
    }

    @objc private func openChecklist() {
        checklistWindow.show()
    }

    @objc private func openTroubleshoot() {
        troubleshootWindow.show()
    }

    @objc private func checkForUpdates() {
        updater.checkForUpdates()
    }

    @objc private func openSettings() {
        settingsWindow.show()
    }

    @objc private func showLog() {
        if !scheduler.showLog() { NSSound.beep() }
    }

    @objc private func uninstall() {
        UninstallFlow.run(scheduler: scheduler) { [statusItem] in
            NSStatusBar.system.removeStatusItem(statusItem)
        }
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
        stripView.strip = scheduler.backupStrip
        stripItem.isHidden = !scheduler.backupStrip.isShown
        nextBackupItem.isHidden = scheduler.nextBackupLine.isEmpty
        backUpNowItem.isEnabled = !scheduler.isBackingUp
        networkItem.title = scheduler.networkLine
        networkItem.isHidden = scheduler.networkLine.isEmpty
        allowNetworkItem.isHidden = !scheduler.canAllowCurrentNetwork
        troubleshootItem.title = scheduler.needsFixing ? "How to Fix This…" : "Troubleshoot…"
        if troubleshootWindow.isVisible { troubleshootWindow.reload() }
        if checklistWindow.isVisible { checklistWindow.reload() }
        if settingsWindow.isVisible {
            settingsWindow.reloadNetworks()
            settingsWindow.reloadDisks()
        }
        drawIcon()
    }

    /// BackMeUp's house mark normally; with an exclamation mark while backups have a problem.
    private func drawIcon() {
        statusItem.button?.image = Logo.menuBarImage(problem: scheduler.hasProblem)
    }
}
