import Foundation

/// The strip of dots in the menu, between the status line and the next-backup line: one slot per
/// recent hour, day or week (the backup interval's unit), newest on the right, each saying whether
/// it was backed up. The scheduler works it out; the menu only draws it.
public struct BackupStrip: Equatable, Sendable {
    public struct Slot: Equatable, Sendable {
        /// What the slot's dot shows. Each kind has its own shape, so colour is never needed.
        public enum Kind: Equatable, Sendable {
            /// ● A backup was made in the slot.
            case backedUp
            /// ○ No backup was made in the slot.
            case skipped
        }

        /// When the slot begins, by the scheduler's calendar.
        public var start: Date
        public var kind: Kind
        /// Whether the slot is the one now is in. The menu rings it.
        public var isCurrent: Bool
        /// What the slot says while hovered, e.g. "Wed 19 Nov: backed up 09:14". Never names a
        /// network, server or disk.
        public var caption: String

        public init(start: Date, kind: Kind, isCurrent: Bool, caption: String) {
            self.start = start
            self.kind = kind
            self.isCurrent = isCurrent
            self.caption = caption
        }
    }

    /// Whether the menu shows the strip at all.
    public var isShown: Bool
    /// What the caption line says with nothing hovered, e.g. "Backed up 12 of the last 14 days".
    public var summary: String
    /// Oldest first, ending with the current slot.
    public var slots: [Slot]

    public init(isShown: Bool, summary: String, slots: [Slot]) {
        self.isShown = isShown
        self.summary = summary
        self.slots = slots
    }

    /// No strip: before setup allows backups and before any backup exists, and after Uninstall….
    public static let hidden = BackupStrip(isShown: false, summary: "", slots: [])
}

/// Works out the strip from what the scheduler knows. Pure, like `MenuText`.
struct BackupStripText {
    var history: BackupHistory
    /// When each backup Time Machine still has on the chosen disk was made (its `SnapshotDates`).
    var timeMachineBackups: [Date]
    /// The backup interval's unit, which sets the slots' size and number.
    var intervalUnit: BackupInterval.Unit
    /// Whether there's anything worth showing yet; see `BackupStrip.hidden`.
    var isShown: Bool
    var now: Date
    var calendar: Calendar

    var strip: BackupStrip {
        guard isShown else { return .hidden }
        let unit = SlotUnit(intervalUnit)
        let successes = self.successes
        let intervals = slotIntervals(unit)
        let slots = intervals.enumerated().map { index, interval -> BackupStrip.Slot in
            let start = interval.start
            let isCurrent = index == intervals.count - 1
            let latest = successes.last { $0 >= start && $0 < interval.end }
            let label = unit.label(start, format)
            if let latest {
                return .init(start: start, kind: .backedUp, isCurrent: isCurrent,
                             caption: "\(label): backed up \(format(latest, unit.backupTimeFormat))")
            }
            return .init(start: start, kind: .skipped, isCurrent: isCurrent, caption: "\(label): not backed up")
        }
        let backedUp = slots.filter { $0.kind == .backedUp }.count
        return BackupStrip(
            isShown: true,
            summary: "Backed up \(backedUp) of the last \(unit.count) \(unit.plural)",
            slots: slots
        )
    }

    /// The strip's slots, oldest first, ending with the one now is in. Each slot is found from the
    /// moment just before the next one starts, so a daylight-saving change can't drop or repeat one.
    private func slotIntervals(_ unit: SlotUnit) -> [DateInterval] {
        guard var slot = calendar.dateInterval(of: unit.component, for: now) else { return [] }
        var slots = [slot]
        while slots.count < unit.count,
              let previous = calendar.dateInterval(of: unit.component, for: slot.start.addingTimeInterval(-1)) {
            slot = previous
            slots.insert(slot, at: 0)
        }
        return slots
    }

    /// Every backup known to have finished, oldest first: Time Machine's, so ones BackMeUp didn't
    /// start count, and BackMeUp's own, so ones Time Machine has since thinned count.
    private var successes: [Date] {
        let own = history.attempts.filter { $0.outcome == .succeeded }.map(\.finished)
        return (timeMachineBackups + own + [history.lastSuccess].compactMap { $0 }).sorted()
    }

    private func format(_ date: Date, _ format: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = format
        return formatter.string(from: date)
    }

    /// How long each slot is, how many the strip has, and how they're worded. Follows the
    /// interval's unit, whatever its count: "every 6 hours" still gives hour slots.
    private struct SlotUnit {
        var component: Calendar.Component
        var count: Int
        var plural: String
        var labelFormat: String
        var labelPrefix = ""
        /// How a backup's time is given in a backed-up slot's caption.
        var backupTimeFormat: String

        init(_ unit: BackupInterval.Unit) {
            switch unit {
            case .hours:
                component = .hour; count = 24; plural = "hours"
                labelFormat = "EEE d MMM HH:mm"; backupTimeFormat = "HH:mm"
            case .days:
                component = .day; count = 14; plural = "days"
                labelFormat = "EEE d MMM"; backupTimeFormat = "HH:mm"
            case .weeks:
                component = .weekOfYear; count = 12; plural = "weeks"
                labelFormat = "d MMM"; labelPrefix = "week of "; backupTimeFormat = "EEE d MMM HH:mm"
            }
        }

        /// "Tue 18 Nov 14:00", "Tue 18 Nov" or "week of 17 Nov".
        func label(_ start: Date, _ format: (Date, String) -> String) -> String {
            labelPrefix + format(start, labelFormat)
        }
    }
}
