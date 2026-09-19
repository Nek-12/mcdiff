import AppKit

let output = URL(fileURLWithPath: CommandLine.arguments[1])
let source = URL(fileURLWithPath: CommandLine.arguments[2])
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
guard let symbol = NSImage(contentsOf: source) else { fatalError("Missing Lucide app icon source") }
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = points * scale
        let size = NSSize(width: pixels, height: pixels)
        let image = NSImage(size: size, flipped: false) { rect in
            let inset = rect.width * 0.055
            let tile = NSBezierPath(roundedRect: rect.insetBy(dx: inset, dy: inset), xRadius: rect.width * 0.22, yRadius: rect.height * 0.22)
            NSGradient(starting: NSColor(calibratedWhite: 0.23, alpha: 1), ending: NSColor(calibratedWhite: 0.09, alpha: 1))!.draw(in: tile, angle: -90)
            NSColor(calibratedWhite: 0.6, alpha: 0.45).setStroke()
            tile.lineWidth = max(1, rect.width * 0.002)
            tile.stroke()
            let glyph = NSImage(size: size, flipped: false) { box in
                symbol.draw(in: box.insetBy(dx: box.width * 0.25, dy: box.height * 0.25))
                NSColor(calibratedWhite: 0.94, alpha: 1).setFill()
                box.fill(using: .sourceAtop)
                return true
            }
            glyph.draw(in: rect)
            return true
        }
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        image.draw(in: NSRect(origin: .zero, size: size))
        NSGraphicsContext.restoreGraphicsState()
        let name = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
        try bitmap.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent(name))
    }
}
