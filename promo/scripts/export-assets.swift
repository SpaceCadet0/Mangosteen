// Exports the pictures the promo videos use: SF Symbols in white, Finder file-type icons, and a photo thumbnail.
// Run from the promo folder:  swift scripts/export-assets.swift <photo.jpg>
import AppKit
import UniformTypeIdentifiers

let output = URL(fileURLWithPath: "public/icons", isDirectory: true)
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

func savePNG(_ image: NSImage, pixels: CGSize, to name: String) throws {
    guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(pixels.width), pixelsHigh: Int(pixels.height),
                                        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return }
    bitmap.size = pixels
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    image.draw(in: NSRect(origin: .zero, size: pixels))
    NSGraphicsContext.restoreGraphicsState()
    try bitmap.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent("\(name).png"))
}

// Wheel symbols, white, sized by height.
let symbols = [
    "photo", "doc.richtext", "timeline.selection", "scissors", "gauge.with.dots.needle.67percent", "speaker.wave.3",
    "waveform.badge.minus", "headphones", "waveform.circle", "arrow.down.right.and.arrow.up.left",
    "eye.slash", "crop", "photo.on.rectangle",
    "dot.radiowaves.left.and.right", "tray.and.arrow.down", "doc.on.clipboard", "folder", "link", "terminal",
]
for name in symbols {
    let configuration = NSImage.SymbolConfiguration(pointSize: 72, weight: .medium)
        .applying(.init(paletteColors: [.white]))
    guard let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(configuration) else {
        print("missing symbol \(name)")
        continue
    }
    try savePNG(symbol, pixels: CGSize(width: symbol.size.width * 2, height: symbol.size.height * 2),
                to: "sf-" + name.replacingOccurrences(of: ".", with: "-"))
}

// Finder icons for the file types in the scenes.
for (name, type) in [("heic", UTType.heic), ("jpg", UTType.jpeg), ("mp3", UTType.mp3), ("pdf", UTType.pdf)] {
    let icon = NSWorkspace.shared.icon(for: type)
    try savePNG(icon, pixels: CGSize(width: 512, height: 512), to: "finder-\(name)")
}

// The photo, as a thumbnail with a white border like Finder's preview icons.
if CommandLine.arguments.count > 1, let photo = NSImage(contentsOfFile: CommandLine.arguments[1]) {
    let side: CGFloat = 512
    let thumbnail = NSImage(size: NSSize(width: side, height: side), flipped: false) { _ in
        let aspect = photo.size.width / photo.size.height
        let width = side * 0.86
        let height = width / aspect
        let frame = NSRect(x: (side - width) / 2, y: (side - height) / 2, width: width, height: height)
        NSColor.white.setFill()
        NSBezierPath(roundedRect: frame.insetBy(dx: -12, dy: -12), xRadius: 16, yRadius: 16).fill()
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(roundedRect: frame, xRadius: 6, yRadius: 6).addClip()
        photo.draw(in: frame)
        NSGraphicsContext.restoreGraphicsState()
        return true
    }
    try savePNG(thumbnail, pixels: CGSize(width: side, height: side), to: CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "photo-thumb")
}
print("exported to \(output.path)")
