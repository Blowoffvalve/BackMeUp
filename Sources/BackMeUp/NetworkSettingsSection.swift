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
    /// Called when the list changes, so the window can fit it.
    var onResize: (() -> Void)?

    init(scheduler: Scheduler) {
        self.scheduler = scheduler
        super.init()
        allNetworksCheckbox.target = self
        allNetworksCheckbox.action = #selector(allNetworksChanged)
        allowButton.target = self
        allowButton.action = #selector(allowCurrentNetwork)
        allowRow.orientation = .vertical
        allowRow.alignment = .leading
        allowRow.spacing = 4
        list.orientation = .vertical
        list.alignment = .leading
        list.spacing = 4

        let title = NSTextField(labelWithString: "Networks for backups to a network disk")
        title.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        let hint = NSTextField.note("Connect to each network you want backups on, such as your home Wi-Fi, and click Allow Backups on This Network. A USB disk backs up on any network.")

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
        onResize?()
    }

    /// The button is there only while backups are limited to chosen networks and the network the
    /// Mac is on isn't chosen yet. It works only when that network can be identified; the note
    /// below it says why not, or that the network is already chosen.
    private func drawAllowRow() {
        allowRow.isHidden = scheduler.networks.allNetworks
        allowButton.isEnabled = scheduler.canAllowCurrentNetwork
        allowButton.isHidden = false
        let note: String
        switch scheduler.currentNetwork {
        case nil:
            note = "Checking the network you're on\u{2026}"
        case let .router(address, _)?:
            if let chosen = scheduler.networks.network(routerAddress: address) {
                allowButton.isHidden = true
                note = "\u{2713} You're on \u{201C}\(chosen.label)\u{201D}, so backups can run here."
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
