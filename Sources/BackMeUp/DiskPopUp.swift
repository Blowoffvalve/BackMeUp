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

    /// Shows check 1's disk choices, with the chosen one selected, or a "Choose a disk…"
    /// placeholder while the check needs a choice. Hidden without check 1 or without choices.
    func reload(_ item: ChecklistItem?) {
        let choices = item?.diskChoices ?? []
        view.isHidden = choices.isEmpty
        guard let item else { return }
        if let drawn, drawn.choices == choices, drawn.chosen == item.chosenDiskID { return }
        drawn = (choices, item.chosenDiskID)
        popUp.removeAllItems()
        if item.needsDiskChoice {
            let placeholder = NSMenuItem(title: "Choose a disk…", action: nil, keyEquivalent: "")
            placeholder.isEnabled = false
            popUp.menu?.addItem(placeholder)
        }
        // Added to the menu directly: `addItem(withTitle:)` would drop a second disk with the same label.
        for choice in choices {
            let menuItem = NSMenuItem(title: choice.label, action: nil, keyEquivalent: "")
            menuItem.representedObject = choice.id
            popUp.menu?.addItem(menuItem)
            if choice.id == item.chosenDiskID { popUp.select(menuItem) }
        }
        if item.needsDiskChoice { popUp.selectItem(at: 0) }
    }

    @objc private func chosen(_ sender: NSPopUpButton) {
        guard let id = sender.selectedItem?.representedObject as? String else { return }
        Task { await scheduler.chooseDisk(id: id) }
    }
}
