import AppKit
import BackMeUpCore

/// The Settings window: which Time Machine disk to back up to (with two or more), how often to
/// back up, how soon to retry, whether to back up on battery, and when to alert.
///
/// Plain AppKit: SwiftUI's `@State` is a macro whose plugin the Command Line Tools don't ship.
@MainActor
final class SettingsWindowController: NSObject {
    private let scheduler: Scheduler
    private let updater: AppUpdater
    private var window: NSWindow?
    /// Everything in the window, inside a scroll view so it fits on short screens.
    private var stack: NSStackView?

    private let intervalField = NSTextField()
    private let intervalStepper = NSStepper()
    private let unitPopUp = NSPopUpButton()
    private let retryField = NSTextField()
    private let retryStepper = NSStepper()
    private let failuresField = NSTextField()
    private let failuresStepper = NSStepper()
    private let daysField = NSTextField()
    private let daysStepper = NSStepper()
    private lazy var networkSection = NetworkSettingsSection(scheduler: scheduler)
    private lazy var diskPopUp = DiskPopUp(scheduler: scheduler)
    private let diskNote = NSTextField.note("Time Machine has more than one disk. BackMeUp backs up to this one only.")
    private lazy var ntfySection = NtfySettingsSection(scheduler: scheduler)
    private lazy var updateSection = UpdateSettingsSection(updater: updater)
    private let batteryCheckbox = NSButton(checkboxWithTitle: "Allow backups on battery", target: nil, action: nil)

    private static let units: [(BackupInterval.Unit, String)] = [(.hours, "hours"), (.days, "days"), (.weeks, "weeks")]

    init(scheduler: Scheduler, updater: AppUpdater) {
        self.scheduler = scheduler
        self.updater = updater
        super.init()
    }

    func show() {
        let isNew = window == nil
        if isNew { window = makeWindow() }
        load()
        fitWindow()
        if isNew { window?.center() }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        // The network may have changed since the last reading; redraw once it's read again.
        Task {
            await scheduler.refreshStatus()
            networkSection.reload()
            reloadDisks()
        }
    }

    var isVisible: Bool { window?.isVisible ?? false }

    /// Redraws the networks part, so it follows the network the Mac is on and networks added from
    /// the menu while the window is open.
    func reloadNetworks() {
        networkSection.reload()
    }

    /// Redraws the "Back up to" pop-up from the latest reading of Time Machine's disks.
    func reloadDisks() {
        let wasHidden = diskPopUp.view.isHidden
        diskPopUp.reload(scheduler.checklist?.item(.diskSetUp))
        diskNote.isHidden = diskPopUp.view.isHidden
        // Fit the window as the pop-up appears or goes.
        if wasHidden != diskPopUp.view.isHidden { fitWindow() }
    }

    /// Sizes the window to its settings, but no taller than the screen it's on; the rest scrolls.
    /// The user can make it taller, up to the height of all the settings.
    private func fitWindow() {
        guard let window, let stack else { return }
        stack.layoutSubtreeIfNeeded()
        let fitting = stack.fittingSize
        let screen = (window.screen ?? NSScreen.main)?.visibleFrame
        let screenHeight = screen.map { window.contentRect(forFrameRect: $0).height } ?? fitting.height
        let height = min(fitting.height, screenHeight)
        // Scroll bars that always show take room from the settings; add it back.
        let scrollerWidth = height < fitting.height && NSScroller.preferredScrollerStyle == .legacy
            ? NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy) : 0
        let size = NSSize(width: fitting.width + scrollerWidth, height: height)
        window.contentMinSize = NSSize(width: size.width, height: min(200, height))
        window.contentMaxSize = NSSize(width: size.width, height: fitting.height)

        // Keep the top left corner where it was, then move the window back onto the screen.
        var frame = window.frameRect(forContentRect: NSRect(origin: .zero, size: size))
        frame.origin = NSPoint(x: window.frame.minX, y: window.frame.maxY - frame.height)
        if let screen {
            frame.origin.y = min(max(frame.minY, screen.minY), screen.maxY - frame.height)
            frame.origin.x = min(max(frame.minX, screen.minX), screen.maxX - frame.width)
        }
        window.setFrame(frame, display: true)
    }

    // MARK: Building the window

    private func makeWindow() -> NSWindow {
        configure(intervalField, intervalStepper, range: 1...999, step: 1)
        configure(retryField, retryStepper, range: Double(BackupSettings.minimumRetryMinutes)...10_080, step: 15)
        configure(failuresField, failuresStepper, range: 1...99, step: 1)
        configure(daysField, daysStepper, range: 1...365, step: 1)
        unitPopUp.addItems(withTitles: Self.units.map(\.1))
        unitPopUp.target = self
        unitPopUp.action = #selector(controlChanged(_:))

        let intervalRow = NSStackView(views: [label("Back up every"), intervalField, intervalStepper, unitPopUp])
        let retryRow = NSStackView(views: [label("If a backup can't run, try again every"), retryField, retryStepper, label("minutes")])
        batteryCheckbox.target = self
        batteryCheckbox.action = #selector(controlChanged(_:))
        let failuresRow = NSStackView(views: [label("Alert me after"), failuresField, failuresStepper, label("failed backups in a row")])
        let daysRow = NSStackView(views: [label("or after"), daysField, daysStepper, label("days without a backup")])
        let stack = NSStackView(views: [
            diskPopUp.view,
            diskNote,
            intervalRow,
            NSTextField.note("Counted from the last successful backup."),
            retryRow,
            NSTextField.note("At least \(BackupSettings.minimumRetryMinutes) minutes."),
            batteryCheckbox,
            NSTextField.note("While a backup runs on power, BackMeUp keeps your Mac awake. Closing the lid still sleeps it."),
            failuresRow,
            daysRow,
            NSTextField.note("Skipped backups never count as failures, but they do count towards days without a backup."),
        ])
        stack.addArrangedSubview(networkSection.view)
        stack.setCustomSpacing(20, after: stack.arrangedSubviews[stack.arrangedSubviews.count - 2])
        stack.addArrangedSubview(ntfySection.view)
        stack.setCustomSpacing(20, after: networkSection.view)
        stack.addArrangedSubview(updateSection.view)
        stack.setCustomSpacing(20, after: ntfySection.view)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        self.stack = stack
        networkSection.onResize = { [weak self] in self?.fitWindow() }

        // The stack fills the scroll view's width and scrolls up and down.
        let document = FlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        stack.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(stack)
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.documentView = document
        let clip = scrollView.contentView
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: document.topAnchor),
            stack.bottomAnchor.constraint(equalTo: document.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            document.topAnchor.constraint(equalTo: clip.topAnchor),
            document.leadingAnchor.constraint(equalTo: clip.leadingAnchor),
            document.trailingAnchor.constraint(equalTo: clip.trailingAnchor),
        ])

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 290),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "BackMeUp Settings"
        window.contentView = scrollView
        window.isReleasedWhenClosed = false
        return window
    }

    private func configure(_ field: NSTextField, _ stepper: NSStepper, range: ClosedRange<Double>, step: Double) {
        let formatter = NumberFormatter()
        formatter.allowsFloats = false
        formatter.minimum = NSNumber(value: range.lowerBound)
        formatter.maximum = NSNumber(value: range.upperBound)
        field.formatter = formatter
        field.alignment = .right
        field.widthAnchor.constraint(equalToConstant: 60).isActive = true
        field.target = self
        field.action = #selector(controlChanged(_:))
        stepper.minValue = range.lowerBound
        stepper.maxValue = range.upperBound
        stepper.increment = step
        stepper.valueWraps = false
        stepper.target = self
        stepper.action = #selector(stepperChanged(_:))
    }

    private func label(_ text: String) -> NSTextField {
        NSTextField(labelWithString: text)
    }

    // MARK: Reading and saving

    private func load() {
        let settings = scheduler.settings
        intervalField.integerValue = settings.backupInterval.count
        intervalStepper.integerValue = settings.backupInterval.count
        unitPopUp.selectItem(at: Self.units.firstIndex { $0.0 == settings.backupInterval.unit } ?? 1)
        retryField.integerValue = settings.retryMinutes
        retryStepper.integerValue = settings.retryMinutes
        failuresField.integerValue = settings.alerts.failuresInARow
        failuresStepper.integerValue = settings.alerts.failuresInARow
        daysField.integerValue = settings.alerts.daysWithoutBackup
        daysStepper.integerValue = settings.alerts.daysWithoutBackup
        reloadDisks()
        networkSection.reload()
        ntfySection.reload()
        updateSection.reload()
        batteryCheckbox.state = settings.allowBackupsOnBattery ? .on : .off
    }

    @objc private func stepperChanged(_ sender: NSStepper) {
        if sender === intervalStepper { intervalField.integerValue = sender.integerValue }
        if sender === retryStepper { retryField.integerValue = sender.integerValue }
        if sender === failuresStepper { failuresField.integerValue = sender.integerValue }
        if sender === daysStepper { daysField.integerValue = sender.integerValue }
        save()
    }

    @objc private func controlChanged(_ sender: Any) {
        save()
    }

    private func save() {
        let unit = Self.units[max(0, unitPopUp.indexOfSelectedItem)].0
        var settings = BackupSettings(
            backupInterval: BackupInterval(count: intervalField.integerValue, unit: unit),
            retryMinutes: retryField.integerValue,
            allowBackupsOnBattery: batteryCheckbox.state == .on
        )
        settings.alerts = AlertSettings(
            failuresInARow: failuresField.integerValue,
            daysWithoutBackup: daysField.integerValue
        )
        scheduler.updateSettings(settings)
        // Show the minimums the scheduler applied.
        load()
    }
}

/// Lays its content out from the top, so a scroll view starts at the first setting.
private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}
