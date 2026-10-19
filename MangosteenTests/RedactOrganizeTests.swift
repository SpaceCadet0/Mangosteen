import AppKit
import PDFKit
import XCTest

final class RedactOrganizeTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("redact-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    /// White 800×300 image with large black text on the left half.
    private func makeTextImage() throws -> CGImage {
        let context = CGContext(data: nil, width: 800, height: 300, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(.white)
        context.fill(CGRect(x: 0, y: 0, width: 800, height: 300))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        NSAttributedString(string: "SECRET 4242", attributes: [
            .font: NSFont.boldSystemFont(ofSize: 56), .foregroundColor: NSColor.black,
        ]).draw(at: CGPoint(x: 20, y: 120))
        NSGraphicsContext.restoreGraphicsState()
        return context.makeImage()!
    }

    private func pixel(_ image: CGImage, x: Int, y: Int) -> (UInt8, UInt8, UInt8) {
        let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                                bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        // Bitmap rows start at the top.
        let bytes = context.data!.assumingMemoryBound(to: UInt8.self)
        let offset = (y * image.width + x) * 4
        return (bytes[offset], bytes[offset + 1], bytes[offset + 2])
    }

    func testDetectsTextOnDevice() throws {
        let boxes = try Redactor.detect(.text, in: makeTextImage())
        XCTAssertFalse(boxes.isEmpty)
        XCTAssertLessThan(try XCTUnwrap(boxes.first).minX, 0.3)
    }

    func testSolidRedactionCoversRegionOnly() throws {
        let image = try makeTextImage()
        let red = RGBAColor(red: 1, green: 0, blue: 0)
        let result = try Redactor.apply([CGRect(x: 0, y: 0, width: 0.5, height: 0.5)], style: .solid, color: red, to: image)
        XCTAssertEqual(pixel(result, x: 10, y: 10).0, 255)
        XCTAssertEqual(pixel(result, x: 10, y: 10).1, 0)
        XCTAssertEqual(pixel(result, x: 790, y: 290).1, 255) // untouched white corner
    }

    func testBlurAndPixelateChangeTheRegion() throws {
        let image = try makeTextImage()
        let boxes = try Redactor.detect(.text, in: image)
        for style in [RedactionStyle.blur, .pixelate] {
            let result = try Redactor.apply(boxes, style: style, color: .white, to: image)
            XCTAssertEqual(result.width, 800)
            XCTAssertTrue(try Redactor.detect(.text, in: result).isEmpty, "\(style) left readable text")
        }
    }

    // MARK: PDF pages

    private func makePDF(pages: Int, named name: String) throws -> URL {
        let document = PDFDocument()
        for index in 0..<pages {
            let image = NSImage(size: NSSize(width: 200, height: 100 + index * 10))
            image.lockFocus()
            NSColor.white.setFill()
            NSRect(origin: .zero, size: image.size).fill()
            image.unlockFocus()
            document.insert(PDFPage(image: image)!, at: index)
        }
        let url = directory.appendingPathComponent(name)
        XCTAssertTrue(document.write(to: url))
        return url
    }

    func testOrganizeReordersRotatesDuplicatesAndDeletes() throws {
        let first = try makePDF(pages: 3, named: "a.pdf")
        let second = try makePDF(pages: 2, named: "b.pdf")
        let documents = [try XCTUnwrap(PDFDocument(url: first)), try XCTUnwrap(PDFDocument(url: second))]
        var items = PDFOrganizer.items(for: documents)
        XCTAssertEqual(items.count, 5)

        items.remove(at: 1)                       // delete a.pdf page 2
        items.swapAt(0, 1)                        // a3, a1, b1, b2
        items[0].rotation = 90
        items.append(PDFPageItem(document: 1, page: 1, rotation: 270))
        let output = try PDFOrganizer.save(items, from: documents, nextTo: first)
        XCTAssertEqual(output.lastPathComponent, "a (страницы).pdf")

        let result = try XCTUnwrap(PDFDocument(url: output))
        XCTAssertEqual(result.pageCount, 5)
        XCTAssertEqual(result.page(at: 0)?.rotation, 90)
        XCTAssertEqual(result.page(at: 0)?.bounds(for: .mediaBox).height, 120) // a.pdf page 3
        XCTAssertEqual(result.page(at: 4)?.rotation, 270)
    }
}
