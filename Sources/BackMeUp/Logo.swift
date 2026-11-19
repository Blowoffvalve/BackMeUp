import AppKit

/// BackMeUp's own mark: a house outline with an arrow going into it ("backed up at home").
/// The menu bar icon and the app icon (`scripts/make-icon`) are both drawn from here, so they
/// always match. It's deliberately unlike Time Machine's clock with a circular arrow.
enum Logo {
    /// The mark's strokes in a unit square (0...1, y up), to be stroked with round caps and joins.
    /// With `problem`, an exclamation mark replaces the arrow; `problemDot` is its dot, to be filled.
    static func strokes(problem: Bool) -> NSBezierPath {
        let path = NSBezierPath()
        // Roof.
        path.move(to: NSPoint(x: 0.06, y: 0.50))
        path.line(to: NSPoint(x: 0.50, y: 0.92))
        path.line(to: NSPoint(x: 0.94, y: 0.50))
        // Walls and floor.
        path.move(to: NSPoint(x: 0.19, y: 0.58))
        path.line(to: NSPoint(x: 0.19, y: 0.08))
        path.line(to: NSPoint(x: 0.81, y: 0.08))
        path.line(to: NSPoint(x: 0.81, y: 0.58))
        if problem {
            path.move(to: NSPoint(x: 0.50, y: 0.62))
            path.line(to: NSPoint(x: 0.50, y: 0.38))
        } else {
            // Arrow pointing down into the house.
            path.move(to: NSPoint(x: 0.50, y: 0.64))
            path.line(to: NSPoint(x: 0.50, y: 0.22))
            path.move(to: NSPoint(x: 0.35, y: 0.36))
            path.line(to: NSPoint(x: 0.50, y: 0.21))
            path.line(to: NSPoint(x: 0.65, y: 0.36))
        }
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        return path
    }

    static let problemDot = NSRect(x: 0.445, y: 0.165, width: 0.11, height: 0.11)

    /// Draws the mark into `rect` in the current colour, with strokes `lineWidth` units thick.
    static func draw(in rect: NSRect, problem: Bool, lineWidth: CGFloat) {
        var transform = AffineTransform(translationByX: rect.minX, byY: rect.minY)
        transform.scale(x: rect.width, y: rect.height)
        let path = strokes(problem: problem)
        path.transform(using: transform)
        path.lineWidth = lineWidth * rect.width
        path.stroke()
        if problem {
            let dot = NSBezierPath(ovalIn: problemDot)
            dot.transform(using: transform)
            dot.fill()
        }
    }

    /// The menu bar icon: a template image, so macOS tints it for light and dark menu bars.
    static func menuBarImage(problem: Bool) -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { bounds in
            NSColor.black.set()
            Logo.draw(in: bounds.insetBy(dx: 1, dy: 1), problem: problem, lineWidth: 0.1)
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = problem ? "BackMeUp: backups need attention" : "BackMeUp"
        return image
    }
}
