import AppKit
import BackMeUpCore

/// The "Back up to" pop-up, in checklist check 1 and in Settings: the Time Machine disks, when
/// there are two or more. Choosing one saves it through the scheduler, which re-reads the checklist.
@MainActor
final class DiskPopUp: NSObject {
    private let scheduler: Scheduler
    private let popUp = NSPopUpButton()
    /// What the pop-up last showed, so it's only rebuilt when that changes.
    private var drawn: (choices: [DiskChoice], chosen: String?)?
    /// The pop-up with its "Back up to" label. Hidden while there's nothing to choose.
    let view: NSStackView

    init(scheduler: Scheduler) {
        self.scheduler = scheduler
        view = NSStackView(views: [NSTextField(labelWithString: "Back up to"), popUp])
        super.init()
        popUp.autoenablesItems = false
        popUp.target = self
        popUp.action = #selector(chosen(_:))
    }

    /// Shows `choices`, with `chosen` selected, or a "Choose a disk" placeholder until one is.
    func reload(choices: [DiskChoice], chosen: String?) {
        view.isHidden = choices.isEmpty
        if let drawn, drawn.choices == choices, drawn.chosen == chosen { return }
        drawn = (choices, chosen)
        popUp.removeAllItems()
        let needsChoice = !choices.contains { $0.id == chosen }
        if needsChoice {
            let placeholder = NSMenuItem(title: "Choose a disk…", action: nil, keyEquivalent: "")
            placeholder.isEnabled = false
            popUp.menu?.addItem(placeholder)
        }
        // Added to the menu directly: `addItem(withTitle:)` would drop a second disk with the same label.
        for choice in choices {
            let item = NSMenuItem(title: choice.label, action: nil, keyEquivalent: "")
            item.representedObject = choice.id
            popUp.menu?.addItem(item)
            if choice.id == chosen { popUp.select(item) }
        }
        if needsChoice { popUp.selectItem(at: 0) }
    }

    @objc private func chosen(_ sender: NSPopUpButton) {
        guard let id = sender.selectedItem?.representedObject as? String else { return }
        Task { await scheduler.chooseDestination(id: id) }
    }
}
