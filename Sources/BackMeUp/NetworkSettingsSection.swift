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

/// "Allow backups on this network", from the menu or the Settings window. Labels the network with
/// its Wi-Fi name when Location permission allows it, and otherwise asks the user to name it.
@MainActor
enum AllowNetworkFlow {
    private static let locationPermission = LocationPermission()

    static func run(scheduler: Scheduler) async {
        await locationPermission.requestIfNeeded()
        await scheduler.refreshStatus()
        guard scheduler.canAllowCurrentNetwork else { return }
        if let wifiName = scheduler.currentNetworkWiFiName {
            scheduler.allowCurrentNetwork(label: wifiName)
        } else if let name = NetworkNamePrompt.ask() {
            scheduler.allowCurrentNetwork(label: name)
        }
    }
}

/// The Settings window's networks part: the chosen networks, with Rename and Remove, and the
/// "all networks" switch. Router hardware addresses are never shown.
@MainActor
final class NetworkSettingsSection: NSObject {
    private let scheduler: Scheduler
    private let allNetworksCheckbox = NSButton(checkboxWithTitle: "Back up to a network disk on any network", target: nil, action: nil)
    private let list = NSStackView()
    private let allowButton = NSButton(title: "Allow Backups on This Network", target: nil, action: nil)
    private let currentNetworkNote = NSTextField.note("")
    private lazy var allowRow = NSStackView(views: [allowButton, currentNetworkNote])

    let view = NSStackView()

    init(scheduler: Scheduler) {
        self.scheduler = scheduler
        super.init()
        allNetworksCheckbox.target = self
        allNetworksCheckbox.action = #selector(allNetworksChanged)
        allowButton.target = self
        allowButton.action = #selector(allowCurrentNetwork)
        currentNetworkNote.preferredMaxLayoutWidth = 200
        list.orientation = .vertical
        list.alignment = .leading
        list.spacing = 4

        let title = NSTextField(labelWithString: "Networks for backups to a network disk")
        title.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        let hint = NSTextField.note("Connect to your home network, then click Allow Backups on This Network. It's in the menu too. A USB disk backs up on any network.")

        view.orientation = .vertical
        view.alignment = .leading
        view.spacing = 8
        [title, list, allowRow, allNetworksCheckbox, hint].forEach(view.addArrangedSubview)
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
        drawAllowRow()
        // Fit the window to the list as networks are added and removed.
        if let window = view.window, let content = window.contentView {
            content.layoutSubtreeIfNeeded()
            window.setContentSize(content.fittingSize)
        }
    }

    /// The button is there only while backups are limited to chosen networks, and works only when
    /// the network the Mac is on can be identified and isn't chosen yet. The note says why not.
    private func drawAllowRow() {
        allowRow.isHidden = scheduler.networks.allNetworks
        allowButton.isEnabled = scheduler.canAllowCurrentNetwork
        let note: String
        switch scheduler.currentNetwork {
        case nil:
            note = "Checking the network you're on\u{2026}"
        case let .router(address, _)?:
            if let chosen = scheduler.networks.network(routerAddress: address) {
                note = "You're on \u{201C}\(chosen.label)\u{201D}, which is already chosen."
            } else {
                note = ""
            }
        default:
            note = "BackMeUp can't identify the network you're on. Check you're connected to Wi-Fi or Ethernet."
        }
        currentNetworkNote.stringValue = note
        currentNetworkNote.isHidden = note.isEmpty
    }

    @objc private func allowCurrentNetwork() {
        allowButton.isEnabled = false
        Task {
            await AllowNetworkFlow.run(scheduler: scheduler)
            reload()
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
