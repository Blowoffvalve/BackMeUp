import AppKit
import BackMeUpCore

/// The Troubleshoot window: the fix for the first problem found, as numbered steps, then every
/// check with a tick or cross. All decisions live in the Scheduler's `troubleshootReport`; this
/// only draws it.
@MainActor
final class TroubleshootWindowController: NSObject, NSWindowDelegate {
    private let scheduler: Scheduler
    private var window: NSWindow?
    private let stack = NSStackView()
    /// The report last drawn, so the window isn't rebuilt when nothing changed.
    private var drawn: TroubleshootReport?
    private var isChecking = false
    private static let textWidth: CGFloat = 420

    init(scheduler: Scheduler) {
        self.scheduler = scheduler
        super.init()
    }

    var isVisible: Bool { window?.isVisible == true }

    /// Shows the window and runs the checks again.
    func show() {
        if window == nil { window = makeWindow() }
        drawn = nil
        reload()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        checkAgain()
    }

    private func makeWindow() -> NSWindow {
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 300),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Troubleshoot Backups"
        window.contentView = stack
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        return window
    }

    /// Redraws from the scheduler's latest report.
    func reload() {
        guard window != nil else { return }
        let report = scheduler.troubleshootReport
        if drawn != nil, drawn == report { return }
        drawn = report
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }

        if let report {
            if let fix = report.firstFailure {
                stack.addArrangedSubview(text(fix.sentence, bold: true))
                for (number, step) in fix.steps.enumerated() {
                    stack.addArrangedSubview(text("\(number + 1). \(step)"))
                }
            } else {
                stack.addArrangedSubview(text("BackMeUp didn't find a problem.", bold: true))
            }
            stack.addArrangedSubview(text("What BackMeUp checked:", secondary: true))
            for check in report.checks {
                stack.addArrangedSubview(text("\(TroubleshootReport.mark(check.state))  \(check.name): \(check.sentence)"))
            }
        } else {
            stack.addArrangedSubview(text("Checking…", bold: true))
        }

        let checkAgainButton = NSButton(title: isChecking ? "Checking…" : "Check Again", target: self, action: #selector(checkAgainClicked))
        checkAgainButton.isEnabled = !isChecking
        let copyButton = NSButton(title: "Copy Details", target: self, action: #selector(copyDetails))
        copyButton.isEnabled = report != nil
        let logButton = NSButton(title: "Show Log", target: self, action: #selector(showLog))
        let buttons = NSStackView(views: [checkAgainButton, copyButton, logButton])
        buttons.spacing = 8
        stack.addArrangedSubview(buttons)
        window?.setContentSize(stack.fittingSize)
    }

    @objc private func checkAgainClicked() {
        checkAgain()
    }

    private func checkAgain() {
        guard !isChecking else { return }
        isChecking = true
        drawn = nil
        reload()
        Task {
            await scheduler.troubleshoot()
            isChecking = false
            drawn = nil
            reload()
        }
    }

    /// Puts the plain-text summary on the clipboard, to send to whoever set up the backups.
    @objc private func copyDetails() {
        guard let details = scheduler.troubleshootDetails else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(details, forType: .string)
    }

    @objc private func showLog() {
        if !scheduler.showLog() { NSSound.beep() }
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
}
