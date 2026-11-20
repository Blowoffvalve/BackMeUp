// Draws the app icon from Sources/BackMeUp/Logo.swift into an .iconset folder.
// build-app.sh compiles this together with Logo.swift and turns the folder into AppIcon.icns.
// Usage: make-icon OUTPUT.iconset
import AppKit

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write("usage: make-icon OUTPUT.iconset\n".data(using: .utf8)!)
    exit(2)
}
let folder = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

func render(pixels: Int) -> Data {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let size = CGFloat(pixels)
    // macOS icon grid: the tile is 824/1024 of the canvas, centred, with a 185/1024 corner radius.
    let tile = NSRect(x: 0, y: 0, width: size, height: size).insetBy(dx: size * 100 / 1024, dy: size * 100 / 1024)
    let radius = size * 185 / 1024
    let shape = NSBezierPath(roundedRect: tile, xRadius: radius, yRadius: radius)

    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
    shadow.shadowOffset = NSSize(width: 0, height: -size * 10 / 1024)
    shadow.shadowBlurRadius = size * 20 / 1024
    shadow.set()
    NSColor.black.setFill()
    shape.fill()
    NSGraphicsContext.restoreGraphicsState()

    // Warm orange to deep red-orange, nothing like Time Machine's teal clock.
    NSGradient(
        starting: NSColor(srgbRed: 1.00, green: 0.66, blue: 0.20, alpha: 1),
        ending: NSColor(srgbRed: 0.91, green: 0.33, blue: 0.13, alpha: 1)
    )!.draw(in: shape, angle: -90)

    NSColor.white.set()
    let mark = tile.insetBy(dx: tile.width * 0.2, dy: tile.width * 0.2)
    Logo.draw(in: mark, problem: false, lineWidth: pixels <= 32 ? 0.12 : 0.09)
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for points in [16, 32, 128, 256, 512] {
    try render(pixels: points).write(to: folder.appendingPathComponent("icon_\(points)x\(points).png"))
    try render(pixels: points * 2).write(to: folder.appendingPathComponent("icon_\(points)x\(points)@2x.png"))
}
