import ImageIO
import PDFKit
import XCTest

final class ImageConverterTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("convert-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    /// A 64×32 half-transparent PNG.
    private func makeSamplePNG(named name: String = "sample") throws -> URL {
        let width = 64, height = 32
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 0.9, green: 0.2, blue: 0.4, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width / 2, height: height))
        let url = directory.appendingPathComponent("\(name).png")
        let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return url
    }

    private func assertDecodes(_ url: URL, width: Int, height: Int, file: StaticString = #filePath, line: UInt = #line) {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            return XCTFail("\(url.lastPathComponent) does not decode", file: file, line: line)
        }
        XCTAssertEqual(image.width, width, file: file, line: line)
        XCTAssertEqual(image.height, height, file: file, line: line)
    }

    func testConvertsPNGToEveryImageIOFormat() throws {
        let input = try makeSamplePNG()
        for target in [FileFormat.jpg, .heic, .tiff, .avif, .bmp, .gif] {
            let output = try XCTUnwrap(Converter.convert(input, to: target, options: ConversionOptions()))
            XCTAssertEqual(output.lastPathComponent, "sample.\(target.fileExtension)")
            assertDecodes(output, width: 64, height: 32)
        }
    }

    func testConvertsPNGToPDF() throws {
        let input = try makeSamplePNG()
        let output = try XCTUnwrap(Converter.convert(input, to: .pdf, options: ConversionOptions()))
        XCTAssertEqual(PDFDocument(url: output)?.pageCount, 1)
    }

    func testConvertsPNGToWebPWhenCwebpIsInstalled() throws {
        try XCTSkipUnless(ExternalTool.isAvailable("cwebp"), "cwebp is not installed")
        let input = try makeSamplePNG()
        let output = try XCTUnwrap(Converter.convert(input, to: .webp, options: ConversionOptions()))
        assertDecodes(output, width: 64, height: 32)
    }

    func testSameFormatIsSkipped() throws {
        let input = try makeSamplePNG()
        XCTAssertNil(try Converter.convert(input, to: .png, options: ConversionOptions()))
    }

    func testOriginalIsNeverOverwritten() throws {
        let input = try makeSamplePNG()
        let first = try XCTUnwrap(Converter.convert(input, to: .jpg, options: ConversionOptions()))
        let second = try XCTUnwrap(Converter.convert(input, to: .jpg, options: ConversionOptions()))
        XCTAssertEqual(first.lastPathComponent, "sample.jpg")
        XCTAssertEqual(second.lastPathComponent, "sample 2.jpg")
    }

    func testCreatesAndMergesPDFs() throws {
        let images = [try makeSamplePNG(named: "a"), try makeSamplePNG(named: "b")]
        let combined = try PDFTools.createPDF(fromImages: images)
        XCTAssertEqual(PDFDocument(url: combined)?.pageCount, 2)

        let copy = directory.appendingPathComponent("copy.pdf")
        try FileManager.default.copyItem(at: combined, to: copy)
        let merged = try PDFTools.merge([combined, copy])
        XCTAssertEqual(PDFDocument(url: merged)?.pageCount, 4)
    }
}
