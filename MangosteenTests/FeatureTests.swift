import AppKit
import PDFKit
import XCTest

/// Background removal, text recognition and the operation history.
final class FeatureTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("features-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    /// Black text on white, as a scan would look.
    private func textImage(_ lines: [String]) throws -> CGImage {
        let size = NSSize(width: 1400, height: 160 * CGFloat(lines.count) + 80)
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor.white.setFill()
        NSRect(origin: .zero, size: size).fill()
        for (index, line) in lines.enumerated() {
            (line as NSString).draw(at: NSPoint(x: 60, y: size.height - 140 - CGFloat(index) * 160), withAttributes: [
                .font: NSFont.systemFont(ofSize: 72, weight: .medium), .foregroundColor: NSColor.black,
            ])
        }
        image.unlockFocus()
        return try XCTUnwrap(image.cgImage(forProposedRect: nil, context: nil, hints: nil))
    }

    // MARK: Text recognition

    func testRecognizesRussianAndEnglishText() throws {
        let text = try TextRecognizer.recognize(textImage(["Мангостин сочный", "Mangosteen converter"]))
        XCTAssertTrue(text.contains("Мангостин"), text)
        XCTAssertTrue(text.contains("Mangosteen"), text)
    }

    func testScannedPDFBecomesTextFile() throws {
        let document = PDFDocument()
        for (index, words) in [["Page one text"], ["Вторая страница"]].enumerated() {
            let image = NSImage(cgImage: try textImage(words), size: .zero)
            document.insert(try XCTUnwrap(PDFPage(image: image)), at: index)
        }
        let pdf = directory.appendingPathComponent("scan.pdf")
        XCTAssertTrue(document.write(to: pdf))
        let output = try TextRecognizer.recognizeFile(pdf)
        XCTAssertEqual(output.lastPathComponent, String(localized: "scan (текст)") + ".txt")
        let text = try String(contentsOf: output, encoding: .utf8)
        let words = text.lowercased().components(separatedBy: .whitespacesAndNewlines)
        XCTAssertTrue(words.contains("page") && words.contains("one"), text)
        XCTAssertTrue(text.contains("страница"), text)
        XCTAssertTrue(text.contains("\u{0C}"), "pages are separated by a page break")
    }

    func testRecognitionStopsAtTimeLimit() throws {
        let image = try textImage(["Mangosteen converter"])
        XCTAssertThrowsError(try TextRecognizer.recognize(image, timeLimit: 0)) { error in
            guard case TextRecognizer.Failure.timedOut = error else { return XCTFail("\(error)") }
        }
    }

    func testRecognitionStopsWhenCancelled() throws {
        let token = CancellationToken()
        token.cancel()
        XCTAssertThrowsError(try TextRecognizer.recognize(textImage(["Mangosteen converter"]), cancellation: token)) { error in
            XCTAssertTrue(error is CancellationError, "\(error)")
        }
    }

    func testBlankImageHasNoText() throws {
        let url = directory.appendingPathComponent("blank.png")
        try ImageConverter.write(textImage([""]), as: .png, to: url, options: ConversionOptions(), metadata: nil)
        XCTAssertThrowsError(try TextRecognizer.recognizeFile(url)) { error in
            guard case TextRecognizer.Failure.noText = error else { return XCTFail("\(error)") }
        }
    }

    // MARK: Background removal

    private var photo: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("promo/public/icons/photo-thumb.png")
    }

    private func alphaRange(_ image: CGImage) -> (transparent: Int, opaque: Int) {
        let width = image.width, height = image.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let context = CGContext(data: &bytes, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        var transparent = 0, opaque = 0
        for index in stride(from: 3, to: bytes.count, by: 4) {
            if bytes[index] < 10 { transparent += 1 } else if bytes[index] > 245 { opaque += 1 }
        }
        return (transparent, opaque)
    }

    func testRemovesBackgroundFromPhoto() throws {
        let source = try ImageConverter.load(photo).image
        let cutout = try BackgroundRemover.cutout(source, cropToSubject: false)
        XCTAssertEqual(cutout.width, source.width)
        let alpha = alphaRange(cutout)
        XCTAssertGreaterThan(alpha.transparent, source.width * source.height / 10, "background became transparent")
        XCTAssertGreaterThan(alpha.opaque, source.width * source.height / 20, "the subject stayed")

        let filled = try BackgroundRemover.compose(cutout, fill: RGBAColor(red: 1, green: 1, blue: 1))
        XCTAssertEqual(alphaRange(filled).transparent, 0)

        let copy = directory.appendingPathComponent("fruit.png")
        try FileManager.default.copyItem(at: photo, to: copy)
        let output = try BackgroundRemover.removeFile(copy, options: .init(), conversion: ConversionOptions())
        XCTAssertEqual(output.lastPathComponent, String(localized: "fruit (без фона)") + ".png")
    }

    // MARK: Archive of a selection

    func testArchiveHoldsOnlyTheSelectedItems() throws {
        let photo = directory.appendingPathComponent("photo.jpg")
        let notes = directory.appendingPathComponent("notes.txt")
        let other = directory.appendingPathComponent("other.txt")
        for url in [photo, notes, other] { try Data(url.lastPathComponent.utf8).write(to: url) }

        let archive = try ArchiveConverter.archiveSelection([photo, notes])
        XCTAssertEqual(archive.deletingLastPathComponent().standardizedFileURL, directory.standardizedFileURL)
        XCTAssertEqual(archive.lastPathComponent, directory.lastPathComponent + ".zip")

        let listing = Process()
        let pipe = Pipe()
        listing.executableURL = URL(fileURLWithPath: "/usr/bin/zipinfo")
        listing.arguments = ["-1", archive.path]
        listing.standardOutput = pipe
        try listing.run()
        listing.waitUntilExit()
        let names = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .split(separator: "\n").map(String.init).filter { !$0.hasPrefix("__MACOSX/") }
        XCTAssertEqual(Set(names), ["photo.jpg", "notes.txt"])
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { $0.hasPrefix(".mangosteen") }
        XCTAssertTrue(leftovers.isEmpty, "the staging folder is removed")
    }

    // MARK: Updates

    func testVersionComparison() {
        XCTAssertTrue(AppVersion.isNewer("v0.10.2", than: "0.10.1"))
        XCTAssertTrue(AppVersion.isNewer("0.10.0", than: "0.9.9"), "numeric, not alphabetical")
        XCTAssertTrue(AppVersion.isNewer("1.0", than: "0.12.4"))
        XCTAssertFalse(AppVersion.isNewer("0.10.1", than: "0.10.1"))
        XCTAssertFalse(AppVersion.isNewer("1.0", than: "1.0.0"))
        XCTAssertFalse(AppVersion.isNewer("v0.9.9", than: "0.10.0"))
    }

    // MARK: PDF compression

    /// A one-page PDF holding a 300 dpi photo-like scan (no text), or a page of text.
    private func makePDF(_ name: String, scan: Bool) throws -> URL {
        let url = directory.appendingPathComponent(name)
        var media = CGRect(x: 0, y: 0, width: 595, height: 842)
        let context = try XCTUnwrap(CGContext(url as CFURL, mediaBox: &media, nil))
        context.beginPage(mediaBox: &media)
        if scan {
            let width = 2480, height = 3508
            let bitmap = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                                 space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                                 bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
            var generator = SystemRandomNumberGenerator()
            for _ in 0..<4000 {
                bitmap.setFillColor(CGColor(red: .random(in: 0...1, using: &generator), green: .random(in: 0...1, using: &generator),
                                            blue: .random(in: 0...1, using: &generator), alpha: 1))
                bitmap.fillEllipse(in: CGRect(x: .random(in: 0...2480), y: .random(in: 0...3508), width: 160, height: 160))
            }
            context.draw(try XCTUnwrap(bitmap.makeImage()), in: media)
        } else {
            let line = NSAttributedString(string: "Mangosteen contract text", attributes: [.font: NSFont.systemFont(ofSize: 18)])
            let frame = CTFramesetterCreateFrame(CTFramesetterCreateWithAttributedString(line), CFRange(),
                                                 CGPath(rect: CGRect(x: 40, y: 700, width: 500, height: 100), transform: nil), nil)
            CTFrameDraw(frame, context)
        }
        context.endPage()
        context.closePDF()
        return url
    }

    func testScannedPDFPagesBecomeJPEG() throws {
        let scan = try makePDF("scan.pdf", scan: true)
        let output = try ImageCompression.compressFile(scan, settings: CompressionSettings())
        XCTAssertLessThan(ImageCompression.fileSize(output), ImageCompression.fileSize(scan) / 2)
        let document = try XCTUnwrap(PDFDocument(url: output))
        XCTAssertEqual(document.pageCount, 1)
        XCTAssertEqual(document.page(at: 0)?.bounds(for: .mediaBox).size, CGSize(width: 595, height: 842))
        let raw = try Data(contentsOf: output)
        XCTAssertNotNil(raw.range(of: Data("/DCTDecode".utf8)), "the page image is stored as JPEG")
    }

    /// A page with a text line and a lossless screenshot, like exports from Google Docs: it has a text layer, so
    /// it is not a scan, and PDFKit alone leaves the image as it is.
    func testImagesOnTextPagesAreReencodedAndTextStays() throws {
        let url = directory.appendingPathComponent("mixed.pdf")
        var media = CGRect(x: 0, y: 0, width: 595, height: 842)
        let context = try XCTUnwrap(CGContext(url as CFURL, mediaBox: &media, nil))
        context.beginPage(mediaBox: &media)
        let line = NSAttributedString(string: "Mangosteen contract text", attributes: [.font: NSFont.systemFont(ofSize: 18)])
        let frame = CTFramesetterCreateFrame(CTFramesetterCreateWithAttributedString(line), CFRange(),
                                             CGPath(rect: CGRect(x: 40, y: 780, width: 500, height: 40), transform: nil), nil)
        CTFrameDraw(frame, context)
        let bitmap = try XCTUnwrap(CGContext(data: nil, width: 1200, height: 900, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                             bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        var generator = SystemRandomNumberGenerator()
        for _ in 0..<1500 {
            bitmap.setFillColor(CGColor(red: .random(in: 0...1, using: &generator), green: .random(in: 0...1, using: &generator),
                                        blue: .random(in: 0...1, using: &generator), alpha: 1))
            bitmap.fillEllipse(in: CGRect(x: .random(in: 0...1200), y: .random(in: 0...900), width: 60, height: 60))
        }
        context.draw(try XCTUnwrap(bitmap.makeImage()), in: CGRect(x: 40, y: 100, width: 500, height: 375))
        context.endPage()
        context.closePDF()
        XCTAssertFalse(ImageCompression.isScan(try XCTUnwrap(PDFDocument(url: url)?.page(at: 0))))

        let output = try ImageCompression.compressFile(url, settings: CompressionSettings())
        XCTAssertLessThan(ImageCompression.fileSize(output), ImageCompression.fileSize(url) * 9 / 10)
        let document = try XCTUnwrap(PDFDocument(url: output))
        XCTAssertEqual(document.pageCount, 1)
        XCTAssertTrue(document.string?.contains("Mangosteen contract text") ?? false, "the text layer stays")
        XCTAssertNotNil(try Data(contentsOf: output).range(of: Data("/DCTDecode".utf8)), "the image is stored as JPEG")
    }

    func testTextPagesAreNotRasterised() throws {
        let page = try XCTUnwrap(PDFDocument(url: try makePDF("text.pdf", scan: false))?.page(at: 0))
        XCTAssertFalse(ImageCompression.isScan(page))
    }

    // MARK: History

    func testHistoryKeepsRecentExistingResults() throws {
        let suite = "dev.mangosteen.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let history = OperationHistory(defaults: defaults)
        let kept = directory.appendingPathComponent("kept.txt")
        let gone = directory.appendingPathComponent("gone.txt")
        try Data("a".utf8).write(to: kept)
        history.record("Convert", outputs: [kept, gone])
        history.record("Nothing", outputs: [])
        for index in 0..<25 { history.record("Op \(index)", outputs: [gone]) }
        XCTAssertEqual(history.entries.count, OperationHistory.limit)

        history.record("Convert", outputs: [kept, gone])
        let current = history.current()
        XCTAssertEqual(current.count, 1, "entries without files disappear")
        XCTAssertEqual(current.first?.outputs, [kept])
        XCTAssertEqual(OperationHistory(defaults: defaults).entries.first?.title, "Convert", "saved across launches")

        history.clear()
        XCTAssertTrue(history.current().isEmpty)
    }
}
