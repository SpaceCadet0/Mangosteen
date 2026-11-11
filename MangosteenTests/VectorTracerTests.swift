import AppKit
import XCTest

/// Tracing pictures into SVG: shapes keep their place, holes stay holes, colours come out right, and the SVG opens.
final class VectorTracerTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("trace-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    /// 400×300, white; a black square (60…180, y down 60…180) with a white hole (100…140); a red disc at (290, 150) r 50.
    private func picture() -> CGImage {
        let context = CGContext(data: nil, width: 400, height: 300, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.translateBy(x: 0, y: 300)
        context.scaleBy(x: 1, y: -1)
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 400, height: 300))
        context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 60, y: 60, width: 120, height: 120))
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 100, y: 100, width: 40, height: 40))
        context.setFillColor(CGColor(red: 0.9, green: 0.1, blue: 0.1, alpha: 1))
        context.fillEllipse(in: CGRect(x: 240, y: 100, width: 100, height: 100))
        return context.makeImage()!
    }

    /// The colour at (x, y down) in a rendering of the traced result.
    private func color(_ image: CGImage, _ x: Int, _ y: Int) -> (r: Double, g: Double, b: Double, a: Double) {
        let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let bytes = context.data!.assumingMemoryBound(to: UInt8.self)
        let offset = (y * image.width + x) * 4
        return (Double(bytes[offset]) / 255, Double(bytes[offset + 1]) / 255, Double(bytes[offset + 2]) / 255, Double(bytes[offset + 3]) / 255)
    }

    func testBlackAndWhiteKeepsShapesAndHoles() throws {
        let result = try VectorTracer.trace(picture(), options: VectorTracer.Options(colors: 1, detail: 0.8, dropBackground: true))
        XCTAssertEqual(result.layers.count, 1)
        XCTAssertEqual(result.layers[0].color.hex, "#000000")
        let image = try XCTUnwrap(VectorTracer.render(result, maxSide: 400))
        XCTAssertGreaterThan(color(image, 80, 80).a, 0.9, "inside the square")
        XCTAssertLessThan(color(image, 120, 120).a, 0.1, "the hole stays open")
        XCTAssertLessThan(color(image, 20, 20).a, 0.1, "the paper is not drawn")
        // The red disc is darker than the paper, so it is ink too.
        XCTAssertGreaterThan(color(image, 290, 150).a, 0.9)

        // With the background kept, the paper is white under the ink.
        let paper = try VectorTracer.trace(picture(), options: VectorTracer.Options(colors: 1, detail: 0.8))
        XCTAssertEqual(paper.layers.map(\.color.hex), ["#ffffff", "#000000"])
        let withPaper = try XCTUnwrap(VectorTracer.render(paper, maxSide: 400))
        XCTAssertEqual(color(withPaper, 20, 20).a, 1, accuracy: 0.01)
        XCTAssertGreaterThan(color(withPaper, 120, 120).r, 0.95, "the hole shows the paper")
    }

    /// A logo saved with no background: a thin frame with bends and lettering, dark on transparent.
    private func logo() -> CGImage {
        let width = 1200, height = 1200
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        let frame = CGMutablePath()
        frame.addLines(between: [CGPoint(x: 380, y: 520), CGPoint(x: 490, y: 455), CGPoint(x: 605, y: 520),
                                 CGPoint(x: 715, y: 455), CGPoint(x: 830, y: 520), CGPoint(x: 830, y: 712),
                                 CGPoint(x: 608, y: 712), CGPoint(x: 608, y: 752), CGPoint(x: 380, y: 712)])
        frame.closeSubpath()
        context.setStrokeColor(CGColor(red: 0.11, green: 0.11, blue: 0.1, alpha: 1))
        context.setLineWidth(13)
        context.setLineJoin(.round)
        context.addPath(frame)
        context.strokePath()
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        let font = NSFont.systemFont(ofSize: 64, weight: .heavy)
        for (line, y) in [("МЕТАЛЛ", 555.0), ("ПРОФИЛЬ", 615.0)] {
            NSAttributedString(string: line, attributes: [.font: font, .foregroundColor: NSColor(white: 0.11, alpha: 1)])
                .draw(at: CGPoint(x: 432, y: y))
        }
        NSGraphicsContext.restoreGraphicsState()
        return context.makeImage()!
    }

    /// How much of the ink the trace covers, as intersection over union of the dark pixels.
    private func inkOverlap(_ original: CGImage, _ traced: CGImage) -> Double {
        func ink(_ image: CGImage) -> [Bool] {
            let context = CGContext(data: nil, width: 600, height: 600, bitsPerComponent: 8, bytesPerRow: 600 * 4,
                                    space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 600, height: 600))
            context.draw(image, in: CGRect(x: 0, y: 0, width: 600, height: 600))
            let bytes = context.data!.assumingMemoryBound(to: UInt8.self)
            return (0..<600 * 600).map { bytes[$0 * 4] < 128 }
        }
        let a = ink(original), b = ink(traced)
        let both = zip(a, b).filter { $0 && $1 }.count, either = zip(a, b).filter { $0 || $1 }.count
        return Double(both) / Double(max(either, 1))
    }

    func testALogoOnTransparencyKeepsItsLettersAndThinFrame() throws {
        let source = logo()
        for detail in [0.0, 0.6, 1.0] {
            let result = try VectorTracer.trace(source, options: VectorTracer.Options(colors: 1, detail: detail, dropBackground: true))
            XCTAssertEqual(result.layers.count, 1, "detail \(detail)")
            let rendered = try XCTUnwrap(VectorTracer.render(result, maxSide: 1200))
            XCTAssertGreaterThan(inkOverlap(source, rendered), detail == 0 ? 0.8 : 0.88, "detail \(detail)")
        }
        // Two colours of a one-colour logo are one colour; the transparent background stays transparent.
        let colours = try VectorTracer.trace(source, options: VectorTracer.Options(colors: 2))
        XCTAssertEqual(colours.layers.count, 1)
    }

    func testColoursAreFoundAndStackedWithoutGaps() throws {
        let result = try VectorTracer.trace(picture(), options: VectorTracer.Options(colors: 3, detail: 0.8))
        XCTAssertEqual(result.layers.count, 3)
        let image = try XCTUnwrap(VectorTracer.render(result, maxSide: 400))
        let red = color(image, 290, 150), original = color(picture(), 290, 150)
        XCTAssertEqual(red.r, original.r, accuracy: 0.03)
        XCTAssertEqual(red.g, original.g, accuracy: 0.03)
        XCTAssertEqual(red.b, original.b, accuracy: 0.03)
        let black = color(image, 80, 80)
        XCTAssertLessThan(black.r + black.g + black.b, 0.2)
        let hole = color(image, 120, 120)
        XCTAssertGreaterThan(hole.r + hole.g + hole.b, 2.8)
        // Every point is covered: the largest colour lies under the rest.
        XCTAssertEqual(color(image, 239, 150).a, 1, accuracy: 0.01)

        let noBackground = try VectorTracer.trace(picture(), options: VectorTracer.Options(colors: 3, detail: 0.8, dropBackground: true))
        XCTAssertEqual(noBackground.layers.count, 2)
        XCTAssertFalse(noBackground.layers.contains { $0.color.hex == "#ffffff" })
    }

    func testTheSVGFileOpensAndMatches() throws {
        let source = folder.appendingPathComponent("logo.png")
        let destination = CGImageDestinationCreateWithURL(source as CFURL, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, picture(), nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))

        let svg = try VectorTracer.traceFile(source, options: VectorTracer.Options(colors: 1))
        XCTAssertEqual(svg.lastPathComponent, "logo.svg")
        let text = try String(contentsOf: svg, encoding: .utf8)
        XCTAssertTrue(text.contains(#"viewBox="0 0 400 300""#))
        XCTAssertTrue(text.contains(#"fill-rule="evenodd""#))
        let image = try XCTUnwrap(NSImage(contentsOf: svg))
        XCTAssertEqual(image.size, NSSize(width: 400, height: 300))
        let rendered = try XCTUnwrap(image.cgImage(forProposedRect: nil, context: nil, hints: nil))
        let scale = rendered.width / 400
        XCTAssertGreaterThan(color(rendered, 80 * scale, 80 * scale).a, 0.9)
        let hole = color(rendered, 120 * scale, 120 * scale)
        XCTAssertGreaterThan(hole.r + hole.g + hole.b, 2.8, "the hole shows the white paper")
    }

    func testPathDataIsCompact() {
        let path = CGMutablePath()
        path.move(to: CGPoint(x: 1, y: 2.25))
        path.addLine(to: CGPoint(x: 3.04, y: 4))
        path.closeSubpath()
        XCTAssertEqual(VectorTracer.pathData(path), "M1 2.3L3 4Z")
    }
}
