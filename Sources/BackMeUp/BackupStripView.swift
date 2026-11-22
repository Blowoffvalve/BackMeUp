import AppKit
import BackMeUpCore

/// The menu's strip of dots and its caption line. Draws only what the scheduler publishes:
/// hovering a dot shows its caption, and otherwise the line shows the summary. No tooltips; they're
/// unreliable inside menus.
@MainActor
final class BackupStripView: NSView {
    private static let inset: CGFloat = 14
    private static let slotWidth: CGFloat = 16
    private static let dotSize: CGFloat = 8
    private static let dotsHeight: CGFloat = 20
    private static let font = NSFont.menuFont(ofSize: NSFont.smallSystemFontSize)

    var strip = BackupStrip.hidden {
        didSet {
            guard strip != oldValue else { return }
            if let hovered, hovered >= strip.slots.count { self.hovered = nil }
            needsDisplay = true
        }
    }

    /// The slot under the mouse, if any.
    private var hovered: Int? {
        didSet { if hovered != oldValue { needsDisplay = true } }
    }

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 300, height: Self.dotsHeight + 22))
        autoresizingMask = .width
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }

    /// Forgets the hovered dot, for when the menu closes without the mouse leaving the view.
    func clearHover() {
        hovered = nil
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.activeAlways, .mouseEnteredAndExited, .mouseMoved, .inVisibleRect],
            owner: self
        ))
    }

    override func mouseMoved(with event: NSEvent) {
        hovered = slot(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseEntered(with event: NSEvent) {
        mouseMoved(with: event)
    }

    override func mouseExited(with event: NSEvent) {
        hovered = nil
    }

    private func slot(at point: NSPoint) -> Int? {
        guard point.y < Self.dotsHeight else { return nil }
        let index = Int(((point.x - Self.inset) / Self.slotWidth).rounded(.down))
        return strip.slots.indices.contains(index) ? index : nil
    }

    override func draw(_ dirtyRect: NSRect) {
        let color = NSColor.labelColor
        color.set()
        for (index, slot) in strip.slots.enumerated() {
            let center = NSPoint(x: Self.inset + Self.slotWidth * (CGFloat(index) + 0.5), y: Self.dotsHeight / 2)
            let dot = NSRect(x: center.x - Self.dotSize / 2, y: center.y - Self.dotSize / 2, width: Self.dotSize, height: Self.dotSize)
            switch slot.kind {
            case .backedUp:
                NSBezierPath(ovalIn: dot).fill()
            case .skipped:
                let path = NSBezierPath(ovalIn: dot.insetBy(dx: 0.75, dy: 0.75))
                path.lineWidth = 1.5
                path.stroke()
            }
            if slot.isCurrent {
                let ring = NSBezierPath(ovalIn: dot.insetBy(dx: -3.5, dy: -3.5))
                ring.lineWidth = 1
                ring.stroke()
            }
        }
        let caption = hovered.map { strip.slots[$0].caption } ?? strip.summary
        (caption as NSString).draw(
            at: NSPoint(x: Self.inset, y: Self.dotsHeight + 2),
            withAttributes: [.font: Self.font, .foregroundColor: color]
        )
    }
}
