import AppKit

let output = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? ".build/MarketBar.iconset")
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let size = points * scale
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let context = NSGraphicsContext(bitmapImageRep: bitmap)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        let transform = NSAffineTransform()
        transform.scale(by: CGFloat(size) / 1024)
        transform.concat()
        NSColor(srgbRed: 16/255, green: 44/255, blue: 48/255, alpha: 1).setFill()
        NSBezierPath(roundedRect: NSRect(x: 80, y: 80, width: 864, height: 864),
                     xRadius: 208, yRadius: 208).fill()
        NSColor(srgbRed: 115/255, green: 217/255, blue: 195/255, alpha: 1).setFill()
        for (x, height) in [(288, 250), (464, 416), (640, 326)] {
            NSBezierPath(roundedRect: NSRect(x: x, y: 304, width: 96, height: height),
                         xRadius: 32, yRadius: 32).fill()
        }
        NSGraphicsContext.restoreGraphicsState()
        let suffix = scale == 2 ? "@2x" : ""
        try bitmap.representation(using: .png, properties: [:])!
            .write(to: output.appendingPathComponent("icon_\(points)x\(points)\(suffix).png"))
    }
}
