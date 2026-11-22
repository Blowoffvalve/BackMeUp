import Foundation

/// The strip of dots in the menu, between the status line and the next-backup line: one slot per
/// recent day, newest on the right, each saying whether it was backed up. The scheduler works it
/// out; the menu only draws it.
public struct BackupStrip: Equatable, Sendable {
    public struct Slot: Equatable, Sendable {
        /// What the slot's dot shows. Each kind has its own shape, so colour is never needed.
        public enum Kind: Equatable, Sendable {
            /// ● A backup was made in the slot.
            case backedUp
            /// ○ A backup was due in the slot but none was made.
            case skipped
            /// · No backup was made, and none was due: the last one was recent enough throughout.
            case nothingDue
            /// The current slot, with no backup yet but one still due later in it. Not missed yet.
            case nothingYet
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
    /// Today's interval. Every slot is judged by it, even ones from before it was changed.
    var interval: BackupInterval
    /// When each backup Time Machine still has on the chosen disk was made (its `SnapshotDates`).
    var timeMachineBackups: [Date]
    /// Whether there's anything worth showing yet; see `BackupStrip.hidden`.
    var isShown: Bool
    var now: Date
    var calendar: Calendar

    var strip: BackupStrip {
        guard isShown else { return .hidden }
        let unit = SlotUnit.days
        let successes = self.successes
        let current = calendar.dateInterval(of: unit.component, for: now)?.start ?? now
        let slots = (0..<unit.count).reversed().map { back -> BackupStrip.Slot in
            let start = calendar.date(byAdding: unit.component, value: -back, to: current) ?? current
            let end = calendar.date(byAdding: unit.component, value: 1, to: start) ?? start
            let latest = successes.last { $0 >= start && $0 < end }
            let label = format(start, unit.captionFormat)
            if let latest {
                return .init(start: start, kind: .backedUp, isCurrent: back == 0,
                             caption: "\(label): backed up \(format(latest, "HH:mm"))")
            }
            // With no success in the slot, the last success before any point in it is the last
            // one before it began, so a backup was due in the slot if that one's interval ran out
            // before the slot ended. With no success at all, one was due all along.
            let due = successes.last { $0 < start }.map { interval.date(after: $0, in: calendar) } ?? .distantPast
            guard due < end else {
                return .init(start: start, kind: .nothingDue, isCurrent: back == 0, caption: "\(label): nothing due")
            }
            if back == 0 {
                return .init(start: start, kind: .nothingYet, isCurrent: true, caption: "\(label): nothing yet")
            }
            return .init(start: start, kind: .skipped, isCurrent: false, caption: "\(label): missed")
        }
        let backedUp = slots.filter { $0.kind == .backedUp }.count
        return BackupStrip(
            isShown: true,
            summary: "Backed up \(backedUp) of the last \(unit.count) \(unit.plural)",
            slots: slots
        )
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

    /// How long each slot is, how many the strip has, and how they're worded.
    private struct SlotUnit {
        var component: Calendar.Component
        var count: Int
        var plural: String
        var captionFormat: String

        static let days = SlotUnit(component: .day, count: 14, plural: "days", captionFormat: "EEE d MMM")
    }
}
