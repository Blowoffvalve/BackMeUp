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
            /// ✕ (red) A backup was due in the slot, and one BackMeUp started in it failed.
            case failed
            /// ○ A backup was due in the slot but none was made, and none failed: BackMeUp skipped
            /// it, the first backup paused, or nothing was recorded. The caption says which.
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
        /// What VoiceOver reads for the slot's dot: the caption with its date written out in full,
        /// e.g. "Wednesday 19 November: backed up 09:14".
        public var accessibilityLabel: String

        public init(start: Date, kind: Kind, isCurrent: Bool, caption: String, accessibilityLabel: String) {
            self.start = start
            self.kind = kind
            self.isCurrent = isCurrent
            self.caption = caption
            self.accessibilityLabel = accessibilityLabel
        }
    }

    /// Whether the menu shows the strip at all.
    public var isShown: Bool
    /// What the caption line says with nothing hovered, e.g. "Backed up 12 of the last 14 days".
    public var summary: String
    /// Oldest first, ending with the current slot.
    public var slots: [Slot]

    /// What VoiceOver reads for the strip as a whole: the summary.
    public var accessibilityLabel: String { summary }

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
    /// How many week slots the strip has: as far back as it ever goes. `BackupHistory` keeps
    /// attempts this long so every slot can say why it was missed.
    static let weekCount = 12

    var history: BackupHistory
    /// Today's interval. Every slot is judged by it, even ones from before it was changed. Its unit
    /// sets the slots' size and number.
    var interval: BackupInterval
    /// When each backup Time Machine still has on the chosen disk was made (its `SnapshotDates`).
    var timeMachineBackups: [Date]
    /// Whether there's anything worth showing yet; see `BackupStrip.hidden`.
    var isShown: Bool
    /// Whether a backup to the chosen disk is running, and how far it's got if Time Machine says.
    var isBackingUp: Bool
    var progress: BackupProgress?
    var now: Date
    var calendar: Calendar

    var strip: BackupStrip {
        guard isShown else { return .hidden }
        let unit = SlotUnit(interval.unit)
        let successes = self.successes
        let slotIntervals = slotIntervals(unit)
        var slots = slotIntervals.enumerated().map { index, slotInterval -> BackupStrip.Slot in
            let isCurrent = index == slotIntervals.count - 1
            func slot(_ kind: BackupStrip.Slot.Kind, _ what: (Formats) -> String) -> BackupStrip.Slot {
                self.slot(slotInterval, unit, kind, isCurrent: isCurrent, what)
            }
            if let latest = successes.last(where: { $0 >= slotInterval.start && $0 < slotInterval.end }) {
                return slot(.backedUp) { "backed up \(format(latest, $0.backupTime))" }
            }
            // With no success in the slot, the last success before any point in it is the last
            // one before it began, so a backup was due in the slot if that one's interval ran out
            // before the slot ended. With no success at all, one was due all along.
            let due = successes.last { $0 < slotInterval.start }.map { interval.date(after: $0, in: calendar) }
                ?? .distantPast
            guard due < slotInterval.end else { return slot(.nothingDue) { _ in "nothing due" } }
            let (kind, why) = missed(in: slotInterval)
            // The current slot shows a failure straight away, but isn't missed while a backup is
            // still due later in it.
            if isCurrent, kind != .failed { return slot(.nothingYet) { _ in "nothing yet" } }
            return slot(kind) { _ in why }
        }
        if isBackingUp, let current = slotIntervals.last, let kind = slots.last?.kind {
            // The same figure as the status line, after the slot's date like every caption.
            let what = progress.map { "backing up: \($0.percentText)" } ?? "backing up"
            slots[slots.count - 1] = slot(current, unit, kind, isCurrent: true) { _ in what }
        }
        let backedUp = slots.filter { $0.kind == .backedUp }.count
        return BackupStrip(
            isShown: true,
            summary: "Backed up \(backedUp) of the last \(unit.count) \(unit.plural)",
            slots: slots
        )
    }

    /// Why a slot with a backup due and none made was missed, from BackMeUp's attempts in it: the
    /// latest failure if any failed, else the most common skip reason (a paused first backup
    /// counting as one), else no record. Never names a network, server or disk.
    private func missed(in slot: DateInterval) -> (BackupStrip.Slot.Kind, String) {
        let attempts = history.attempts.filter { $0.started >= slot.start && $0.started < slot.end }
            .sorted { $0.started < $1.started }
        var latestFailure: FailureReason?
        var skips: [SkipTally] = []
        for attempt in attempts {
            let why: String
            switch attempt.outcome {
            case .succeeded: continue
            case let .failed(reason): latestFailure = reason; continue
            case let .skipped(reason): why = "skipped, \(reason.description)"
            case .paused: why = "first backup paused, carries on next time"
            }
            if let index = skips.firstIndex(where: { $0.why == why }) {
                skips[index].count += 1
                skips[index].latest = attempt.started
            } else {
                skips.append(SkipTally(why: why, count: 1, latest: attempt.started))
            }
        }
        if let latestFailure {
            return (.failed, "failed, \(latestFailure.description)")
        }
        // Most common; between equally common ones, the latest.
        if let skip = skips.max(by: { ($0.count, $0.latest) < ($1.count, $1.latest) }) {
            return (.skipped, skip.why)
        }
        if let monitoringSince = history.monitoringSince, slot.end <= monitoringSince {
            return (.skipped, "before BackMeUp was set up")
        }
        return (.skipped, "missed: no record (Mac asleep, off, or BackMeUp not running)")
    }

    /// How often one kind of skip came up in a slot, and when it last did.
    private struct SkipTally {
        var why: String
        var count: Int
        var latest: Date
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

    /// A slot saying `what` happened in it, after its date. The caption and VoiceOver's label are
    /// the same text, worded with the unit's short and full formats.
    private func slot(
        _ slot: DateInterval, _ unit: SlotUnit, _ kind: BackupStrip.Slot.Kind, isCurrent: Bool,
        _ what: (Formats) -> String
    ) -> BackupStrip.Slot {
        func text(_ formats: Formats) -> String {
            "\(unit.labelPrefix)\(format(slot.start, formats.label)): \(what(formats))"
        }
        return .init(
            start: slot.start, kind: kind, isCurrent: isCurrent,
            caption: text(unit.short), accessibilityLabel: text(unit.full)
        )
    }

    private func format(_ date: Date, _ format: String) -> String {
        Self.formatters.formatter(format, calendar: calendar).string(from: date)
    }

    /// Making a `DateFormatter` is slow, and the strip is worked out on every tick, so each one is
    /// made once per format, calendar and time zone and kept.
    private static let formatters = FormatterCache()

    private final class FormatterCache: @unchecked Sendable {
        private let lock = NSLock()
        private var formatters: [String: DateFormatter] = [:]

        func formatter(_ format: String, calendar: Calendar) -> DateFormatter {
            let key = "\(format)|\(calendar.identifier)|\(calendar.timeZone.identifier)"
            lock.lock()
            defer { lock.unlock() }
            if let formatter = formatters[key] { return formatter }
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.calendar = calendar
            formatter.timeZone = calendar.timeZone
            formatter.dateFormat = format
            formatters[key] = formatter
            return formatter
        }
    }

    /// How a slot's dates are written: short in the caption, full for VoiceOver.
    private struct Formats {
        /// The slot's start: "Tue 18 Nov 14:00", "Tue 18 Nov" or "18 Nov" (after "week of "); in
        /// full, "Tuesday 18 November 14:00", "Tuesday 18 November" or "18 November".
        var label: String
        /// A backup's time in a backed-up slot.
        var backupTime: String
    }

    /// How long each slot is, how many the strip has, and how they're worded. Follows the
    /// interval's unit, whatever its count: "every 6 hours" still gives hour slots.
    private struct SlotUnit {
        var component: Calendar.Component
        var count: Int
        var plural: String
        var labelPrefix = ""
        var short: Formats
        var full: Formats

        init(_ unit: BackupInterval.Unit) {
            switch unit {
            case .hours:
                component = .hour; count = 24; plural = "hours"
                short = Formats(label: "EEE d MMM HH:mm", backupTime: "HH:mm")
                full = Formats(label: "EEEE d MMMM HH:mm", backupTime: "HH:mm")
            case .days:
                component = .day; count = 14; plural = "days"
                short = Formats(label: "EEE d MMM", backupTime: "HH:mm")
                full = Formats(label: "EEEE d MMMM", backupTime: "HH:mm")
            case .weeks:
                component = .weekOfYear; count = BackupStripText.weekCount; plural = "weeks"
                labelPrefix = "week of "
                short = Formats(label: "d MMM", backupTime: "EEE d MMM HH:mm")
                full = Formats(label: "d MMMM", backupTime: "EEEE d MMMM HH:mm")
            }
        }
    }
}
