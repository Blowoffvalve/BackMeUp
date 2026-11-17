import AppKit
import BackMeUpCore

/// The Settings window: how often to back up, how soon to retry, whether to back up on battery,
/// and when to alert.
///
/// Plain AppKit: SwiftUI's `@State` is a macro whose plugin the Command Line Tools don't ship.
@MainActor
final class SettingsWindowController: NSObject {
    private let scheduler: Scheduler
    private let updater: AppUpdater
    private var window: NSWindow?

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
        if window == nil { window = makeWindow() }
        load()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
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
            intervalRow,
            note("Counted from the last successful backup."),
            retryRow,
            note("At least \(BackupSettings.minimumRetryMinutes) minutes."),
            batteryCheckbox,
            note("While a backup runs on power, BackMeUp keeps your Mac awake. Closing the lid still sleeps it."),
            failuresRow,
            daysRow,
            note("Skipped backups never count as failures, but they do count towards days without a backup."),
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

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 290),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "BackMeUp Settings"
        window.contentView = stack
        window.isReleasedWhenClosed = false
        window.center()
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

    private func note(_ text: String) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        field.textColor = .secondaryLabelColor
        return field
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
