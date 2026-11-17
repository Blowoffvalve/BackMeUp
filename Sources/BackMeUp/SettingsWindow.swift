import AppKit
import BackMeUpCore

/// The Settings window: how often to back up, and how soon to retry.
///
/// Plain AppKit: SwiftUI's `@State` is a macro whose plugin the Command Line Tools don't ship.
@MainActor
final class SettingsWindowController: NSObject {
    private let scheduler: Scheduler
    private var window: NSWindow?

    private let intervalField = NSTextField()
    private let intervalStepper = NSStepper()
    private let unitPopUp = NSPopUpButton()
    private let retryField = NSTextField()
    private let retryStepper = NSStepper()
    private lazy var networkSection = NetworkSettingsSection(scheduler: scheduler)

    private static let units: [(BackupInterval.Unit, String)] = [(.hours, "hours"), (.days, "days"), (.weeks, "weeks")]

    init(scheduler: Scheduler) {
        self.scheduler = scheduler
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
        unitPopUp.addItems(withTitles: Self.units.map(\.1))
        unitPopUp.target = self
        unitPopUp.action = #selector(controlChanged(_:))

        let intervalRow = NSStackView(views: [label("Back up every"), intervalField, intervalStepper, unitPopUp])
        let retryRow = NSStackView(views: [label("If a backup can't run, try again every"), retryField, retryStepper, label("minutes")])
        let stack = NSStackView(views: [
            intervalRow,
            note("Counted from the last successful backup."),
            retryRow,
            note("At least \(BackupSettings.minimumRetryMinutes) minutes."),
        ])
        stack.addArrangedSubview(networkSection.view)
        stack.setCustomSpacing(20, after: stack.arrangedSubviews[stack.arrangedSubviews.count - 2])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 160),
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
        networkSection.reload()
    }

    @objc private func stepperChanged(_ sender: NSStepper) {
        if sender === intervalStepper { intervalField.integerValue = sender.integerValue }
        if sender === retryStepper { retryField.integerValue = sender.integerValue }
        save()
    }

    @objc private func controlChanged(_ sender: Any) {
        save()
    }

    private func save() {
        let unit = Self.units[max(0, unitPopUp.indexOfSelectedItem)].0
        scheduler.updateSettings(BackupSettings(
            backupInterval: BackupInterval(count: intervalField.integerValue, unit: unit),
            retryMinutes: retryField.integerValue
        ))
        // Show the minimums the scheduler applied.
        load()
    }
}
