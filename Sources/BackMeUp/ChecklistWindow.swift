import AppKit
import BackMeUpCore

/// The first-run checklist window: the six checks, each with a plain sentence and a button.
/// All decisions live in the Scheduler's `checklist`; this only draws it.
@MainActor
final class ChecklistWindowController: NSObject, NSWindowDelegate {
    /// How often the checks are re-read while the window is open, in seconds, so that a change
    /// made in System Settings shows here straight away rather than at the next background tick.
    private static let refreshInterval: TimeInterval = 2

    private let scheduler: Scheduler
    private let openBackMeUpSettings: () -> Void
    /// Asks the scheduler to re-read the checks; the window redraws when it's done.
    private let refresh: () -> Void
    private var window: NSWindow?
    private let stack = NSStackView()
    private var refreshTimer: Timer?
    /// What the window last drew, so that unchanged checks aren't rebuilt under the pointer.
    private var drawn: (checklist: Checklist?, tip: String?)?
    /// Check 1's "Back up to" pop-up, when Time Machine has two or more disks.
    private lazy var diskPopUp = DiskPopUp(scheduler: scheduler)
    private static let textWidth: CGFloat = 420

    init(scheduler: Scheduler, openBackMeUpSettings: @escaping () -> Void, refresh: @escaping () -> Void) {
        self.scheduler = scheduler
        self.openBackMeUpSettings = openBackMeUpSettings
        self.refresh = refresh
        super.init()
    }

    var isVisible: Bool { window?.isVisible == true }

    func show() {
        if window == nil { window = makeWindow() }
        reload()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        startRefreshing()
    }

    // MARK: Refreshing while open

    private func startRefreshing() {
        refresh()
        guard refreshTimer == nil else { return }
        let timer = Timer(timeInterval: Self.refreshInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        RunLoop.main.add(timer, forMode: .common)
        refreshTimer = timer
    }

    nonisolated func windowDidBecomeKey(_ notification: Notification) {
        // Coming back from System Settings: re-read now rather than at the next timer fire.
        MainActor.assumeIsolated { refresh() }
    }

    nonisolated func windowWillClose(_ notification: Notification) {
        MainActor.assumeIsolated {
            refreshTimer?.invalidate()
            refreshTimer = nil
        }
    }

    private func makeWindow() -> NSWindow {
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 400),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Set Up BackMeUp"
        window.contentView = stack
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        return window
    }

    /// Redraws the checks from the scheduler's latest reading.
    func reload() {
        guard window != nil else { return }
        let latest = (checklist: scheduler.checklist, tip: scheduler.checklistTip)
        if let drawn, drawn.checklist == latest.checklist, drawn.tip == latest.tip { return }
        drawn = latest
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        stack.addArrangedSubview(text(
            scheduler.checklist?.allowsBackups == false
                ? "Backups start once checks 1, 2 and 6 are done."
                : "Backups are ready to run. The other checks help them keep running.",
            bold: true
        ))
        for item in scheduler.checklist?.items ?? [] {
            stack.addArrangedSubview(row(item))
        }
        if let tip = scheduler.checklistTip {
            stack.addArrangedSubview(text(tip, secondary: true))
        }
        window?.setContentSize(stack.fittingSize)
    }

    private func row(_ item: ChecklistItem) -> NSView {
        let mark = NSTextField(labelWithString: "\(item.check.rawValue). \(Self.mark(item.state))")
        mark.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        mark.setContentHuggingPriority(.required, for: .horizontal)

        var lines: [NSView] = [text(item.sentence)]
        if !item.diskChoices.isEmpty {
            // One pop-up kept across redraws, so the refresh doesn't reset it under the pointer.
            diskPopUp.reload(choices: item.diskChoices, chosen: item.chosenDiskID)
            lines.append(diskPopUp.view)
        }
        if item.showsDirections {
            lines.append(text(item.directions, secondary: true))
        }
        let button = NSButton(title: item.buttonTitle, target: self, action: #selector(buttonClicked(_:)))
        button.tag = item.check.rawValue
        lines.append(button)
        let column = NSStackView(views: lines)
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 4

        let row = NSStackView(views: [mark, column])
        row.alignment = .top
        return row
    }

    private static func mark(_ state: ChecklistItem.State) -> String {
        switch state {
        case .passed: "✓"
        case .notNeeded: "–"
        case .failed: "✗"
        case .warning: "!"
        case .unknown: "?"
        }
    }

    private func text(_ string: String, bold: Bool = false, secondary: Bool = false) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: string)
        field.preferredMaxLayoutWidth = Self.textWidth
        field.widthAnchor.constraint(lessThanOrEqualToConstant: Self.textWidth).isActive = true
        if bold { field.font = .boldSystemFont(ofSize: NSFont.systemFontSize) }
        if secondary {
            field.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            field.textColor = .secondaryLabelColor
        }
        return field
    }

    @objc private func buttonClicked(_ sender: NSButton) {
        guard let check = ChecklistItem.Check(rawValue: sender.tag),
              let item = scheduler.checklist?.item(check)
        else { return }
        if item.action == .openBackMeUpSettings {
            openBackMeUpSettings()
            return
        }
        Task { await scheduler.performAction(for: check) }
    }
}
