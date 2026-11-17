import AppKit
import BackMeUpCore

/// Asks the user to name a network, for when the Wi-Fi name can't be read (no Location
/// permission, or Ethernet).
@MainActor
enum NetworkNamePrompt {
    /// Returns the trimmed name, or nil if the user cancelled or left it empty.
    static func ask(
        message: String = "Name this network",
        info: String = "BackMeUp can't read this network's Wi-Fi name. Give it a name you'll recognise, such as Home.",
        current: String = ""
    ) -> String? {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = info
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.stringValue = current
        field.placeholderString = "Home"
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }
}

/// The Settings window's networks part: the chosen networks, with Rename and Remove, and the
/// "all networks" switch. Router hardware addresses are never shown.
@MainActor
final class NetworkSettingsSection: NSObject {
    private let scheduler: Scheduler
    private let allNetworksCheckbox = NSButton(checkboxWithTitle: "Back up to a network disk on any network", target: nil, action: nil)
    private let list = NSStackView()

    let view = NSStackView()

    init(scheduler: Scheduler) {
        self.scheduler = scheduler
        super.init()
        allNetworksCheckbox.target = self
        allNetworksCheckbox.action = #selector(allNetworksChanged)
        list.orientation = .vertical
        list.alignment = .leading
        list.spacing = 4

        let title = NSTextField(labelWithString: "Networks for backups to a network disk")
        title.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        let hint = NSTextField.note("Add the network you're on with \u{201C}Allow backups on this network\u{201D} in the menu. A USB disk backs up on any network.")

        view.orientation = .vertical
        view.alignment = .leading
        view.spacing = 8
        [title, list, allNetworksCheckbox, hint].forEach(view.addArrangedSubview)
        reload()
    }

    /// Redraws from the scheduler's current settings.
    func reload() {
        let networks = scheduler.networks
        allNetworksCheckbox.state = networks.allNetworks ? .on : .off
        list.arrangedSubviews.forEach { $0.removeFromSuperview() }
        if networks.chosen.isEmpty {
            list.addArrangedSubview(NSTextField(labelWithString: "No networks chosen yet."))
        }
        for (index, network) in networks.chosen.enumerated() {
            let name = NSTextField(labelWithString: network.label)
            name.widthAnchor.constraint(greaterThanOrEqualToConstant: 200).isActive = true
            let rename = NSButton(title: "Rename…", target: self, action: #selector(rename(_:)))
            let remove = NSButton(title: "Remove", target: self, action: #selector(remove(_:)))
            rename.tag = index
            remove.tag = index
            list.addArrangedSubview(NSStackView(views: [name, rename, remove]))
        }
        // Fit the window to the list as networks are added and removed.
        if let window = view.window, let content = window.contentView {
            content.layoutSubtreeIfNeeded()
            window.setContentSize(content.fittingSize)
        }
    }

    @objc private func allNetworksChanged() {
        var networks = scheduler.networks
        networks.allNetworks = allNetworksCheckbox.state == .on
        scheduler.updateNetworks(networks)
        reload()
    }

    @objc private func rename(_ sender: NSButton) {
        var networks = scheduler.networks
        guard networks.chosen.indices.contains(sender.tag),
              let name = NetworkNamePrompt.ask(
                  message: "Rename network",
                  info: "Choose a name you'll recognise.",
                  current: networks.chosen[sender.tag].label
              )
        else { return }
        networks.chosen[sender.tag].label = name
        scheduler.updateNetworks(networks)
        reload()
    }

    @objc private func remove(_ sender: NSButton) {
        var networks = scheduler.networks
        guard networks.chosen.indices.contains(sender.tag) else { return }
        networks.chosen.remove(at: sender.tag)
        scheduler.updateNetworks(networks)
        reload()
    }
}
