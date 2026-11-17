import AppKit
import BackMeUpCore

/// The Settings window's phone alerts part: the ntfy server, topic and optional access token, and a
/// "Send test message" button. The topic and token are saved to the Keychain by the scheduler.
@MainActor
final class NtfySettingsSection: NSObject, NSTextFieldDelegate {
    private let scheduler: Scheduler
    private let serverField = NSTextField()
    private let topicField = NSTextField()
    private let tokenField = NSSecureTextField()
    private let testButton = NSButton(title: "Send test message", target: nil, action: nil)
    private let testResult = NSTextField(labelWithString: "")

    let view = NSStackView()

    init(scheduler: Scheduler) {
        self.scheduler = scheduler
        super.init()

        let title = NSTextField(labelWithString: "Phone alerts (optional)")
        title.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        let hint = Self.note("Install the ntfy app on your phone and subscribe to a topic, then enter it here. Every alert is also sent there. Use a topic that's hard to guess: anyone who knows it can read your alerts.")

        for field in [serverField, topicField, tokenField] {
            field.delegate = self
            field.target = self
            field.action = #selector(fieldsChanged)
            field.widthAnchor.constraint(equalToConstant: 300).isActive = true
        }
        serverField.placeholderString = NtfySettings.defaultServer
        topicField.placeholderString = "Topic"
        tokenField.placeholderString = "Only if your topic needs one"
        testButton.target = self
        testButton.action = #selector(sendTest)
        testResult.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        testResult.preferredMaxLayoutWidth = 420
        testResult.lineBreakMode = .byWordWrapping
        testResult.maximumNumberOfLines = 0

        let grid = NSGridView(views: [
            [NSTextField(labelWithString: "Server"), serverField],
            [NSTextField(labelWithString: "Topic"), topicField],
            [NSTextField(labelWithString: "Access token"), tokenField],
        ])
        grid.column(at: 0).xPlacement = .trailing
        grid.rowSpacing = 6

        view.orientation = .vertical
        view.alignment = .leading
        view.spacing = 8
        for subview in [title, hint, grid, testButton, testResult] {
            view.addArrangedSubview(subview)
        }
    }

    /// Shows the saved settings.
    func reload() {
        let ntfy = scheduler.ntfy
        serverField.stringValue = ntfy.server
        topicField.stringValue = ntfy.topic
        tokenField.stringValue = ntfy.token ?? ""
        testResult.stringValue = ""
    }

    // Save as the user types, so closing the window never loses an edit.
    func controlTextDidChange(_ notification: Notification) {
        save()
    }

    @objc private func fieldsChanged() {
        save()
    }

    private func save() {
        scheduler.updateNtfy(NtfySettings(
            server: serverField.stringValue,
            topic: topicField.stringValue,
            token: tokenField.stringValue
        ))
    }

    @objc private func sendTest() {
        save()
        testButton.isEnabled = false
        testResult.textColor = .secondaryLabelColor
        testResult.stringValue = "Sending…"
        Task {
            let result = await scheduler.sendTestMessage()
            testButton.isEnabled = true
            testResult.textColor = result.succeeded ? .secondaryLabelColor : .systemRed
            testResult.stringValue = result.message
        }
    }

    private static func note(_ text: String) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        field.textColor = .secondaryLabelColor
        field.preferredMaxLayoutWidth = 420
        field.lineBreakMode = .byWordWrapping
        field.maximumNumberOfLines = 0
        return field
    }
}
