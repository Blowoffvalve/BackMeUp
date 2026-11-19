import AppKit

/// The Settings window's updates part: whether to install updates without asking, and
/// "Check Now", and which version this is.
@MainActor
final class UpdateSettingsSection: NSObject {
    private let updater: AppUpdater
    private let automaticCheckbox = NSButton(checkboxWithTitle: "Install updates automatically", target: nil, action: nil)

    let view = NSStackView()

    init(updater: AppUpdater) {
        self.updater = updater
        super.init()

        let title = NSTextField(labelWithString: "Updates")
        title.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        automaticCheckbox.target = self
        automaticCheckbox.action = #selector(automaticChanged)
        let checkNow = NSButton(title: "Check Now", target: self, action: #selector(checkNow))

        let note: NSTextField
        if updater.isAvailable {
            note = NSTextField.note("BackMeUp checks for updates once a day. Unless this is on, it asks before installing one.")
        } else {
            note = NSTextField.note("This copy of BackMeUp can't update itself. Download new versions from GitHub.")
            automaticCheckbox.isEnabled = false
            checkNow.isEnabled = false
        }

        view.orientation = .vertical
        view.alignment = .leading
        view.spacing = 8
        // Release builds carry the release's version; scripts/build-app.sh labels others as development builds.
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
        let versionLabel = NSTextField(labelWithString: "This is BackMeUp \(version).")
        versionLabel.isSelectable = true
        for subview in [title, versionLabel, NSStackView(views: [automaticCheckbox, checkNow]), note] {
            view.addArrangedSubview(subview)
        }
        reload()
    }

    func reload() {
        automaticCheckbox.state = updater.installsAutomatically ? .on : .off
    }

    @objc private func automaticChanged() {
        updater.installsAutomatically = automaticCheckbox.state == .on
        reload()
    }

    @objc private func checkNow() {
        updater.checkForUpdates()
    }
}
